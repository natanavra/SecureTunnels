import Foundation
import Observation
import SecureTunnelsCore

/// The Cloudflare account link: API token in the keychain, chosen account in defaults, plus cloudflared's state.
@MainActor
@Observable
final class CloudflareSettings {
  static let shared = CloudflareSettings()
  /// Keychain owner for the API token.
  static let tokenOwner = UUID(uuidString: "5EC0DE00-0000-4000-8000-C10DF1A4E000")!

  private(set) var hasToken: Bool
  var accountID: String {
    didSet { UserDefaults.standard.set(accountID, forKey: "cloudflareAccountID") }
  }
  var accountName: String {
    didSet { UserDefaults.standard.set(accountName, forKey: "cloudflareAccountName") }
  }
  private(set) var accounts: [CloudflareAPI.Account] = []
  private(set) var remoteTunnels: [RemoteTunnelInfo] = []
  private(set) var isLoadingTunnels = false
  private(set) var tunnelsError: String?
  private(set) var zones: [CloudflareAPI.Zone] = []
  private(set) var verification: String?
  private(set) var isVerifying = false
  private(set) var cloudflaredURL: URL?
  private(set) var cloudflaredVersion: String?
  private(set) var isInstalling = false
  private(set) var installError: String?

  private init() {
    hasToken = Keychain.read(.apiToken, ownerID: Self.tokenOwner) != nil
    accountID = UserDefaults.standard.string(forKey: "cloudflareAccountID") ?? ""
    accountName = UserDefaults.standard.string(forKey: "cloudflareAccountName") ?? ""
    refreshCloudflared()
  }

  var token: String { Keychain.read(.apiToken, ownerID: Self.tokenOwner) ?? "" }

  var api: CloudflareAPI? {
    let token = token
    return token.isEmpty ? nil : CloudflareAPI(token: token)
  }

  /// Finds the binary now and asks it for its version off the main thread. Running a process here synchronously
  /// would spin the run loop inside the singleton's initializer and re-enter it from SwiftUI.
  func refreshCloudflared() {
    let url = Cloudflared.locate()
    cloudflaredURL = url
    cloudflaredVersion = nil
    guard let url else { return }
    Task.detached {
      let version = Cloudflared.version(at: url)
      await MainActor.run { CloudflareSettings.shared.cloudflaredVersion = version }
    }
  }

  func installCloudflared() async {
    isInstalling = true
    installError = nil
    defer { isInstalling = false }
    do {
      _ = try await Cloudflared.install()
      refreshCloudflared()
    } catch {
      installError = error.localizedDescription
    }
  }

  /// Stores the token and looks up the accounts and zones it can see.
  func saveAndVerify(token: String) async {
    isVerifying = true
    defer { isVerifying = false }
    do {
      try Keychain.write(token, .apiToken, ownerID: Self.tokenOwner)
      hasToken = !token.isEmpty
      guard let api else {
        accounts = []
        zones = []
        verification = nil
        return
      }
      _ = try await api.verifyToken()
      accounts = try await api.accounts()
      zones = try await api.zones()
      if accounts.count == 1 || !accounts.contains(where: { $0.id == accountID }) {
        accountID = accounts.first?.id ?? ""
        accountName = accounts.first?.name ?? ""
      }
      verification = "Token works. \(accounts.count) account(s), \(zones.count) zone(s): \(zones.map(\.name).joined(separator: ", "))"
      await refreshRemoteTunnels()
    } catch {
      verification = "Token check failed: \(error.localizedDescription)"
    }
  }

  func selectAccount(_ account: CloudflareAPI.Account) {
    accountID = account.id
    accountName = account.name
    Task { await refreshRemoteTunnels() }
  }

  /// Lists the account's tunnels with their ingress rules, so existing ones can be adopted or deleted.
  func refreshRemoteTunnels() async {
    guard let api, !accountID.isEmpty else {
      remoteTunnels = []
      return
    }
    isLoadingTunnels = true
    tunnelsError = nil
    defer { isLoadingTunnels = false }
    do {
      let tunnels = try await api.tunnels(accountID: accountID)
      let accountID = accountID
      var infos: [RemoteTunnelInfo] = []
      try await withThrowingTaskGroup(of: RemoteTunnelInfo.self) { group in
        for tunnel in tunnels {
          group.addTask {
            let ingress = (try? await api.ingress(accountID: accountID, tunnelID: tunnel.id)) ?? []
            return RemoteTunnelInfo(tunnel: tunnel, ingress: ingress)
          }
        }
        for try await info in group { infos.append(info) }
      }
      remoteTunnels = infos.sorted { $0.tunnel.name.localizedCaseInsensitiveCompare($1.tunnel.name) == .orderedAscending }
    } catch {
      tunnelsError = error.localizedDescription
    }
  }

  func deleteRemoteTunnel(_ info: RemoteTunnelInfo) async throws {
    guard let api else { return }
    try await api.deleteTunnelAndRoutes(accountID: accountID, tunnelID: info.tunnel.id, hostnames: info.hostnames)
    remoteTunnels.removeAll { $0.id == info.id }
  }
}

struct RemoteTunnelInfo: Identifiable, Equatable {
  var tunnel: CloudflareAPI.RemoteTunnel
  var ingress: [CloudflareAPI.Ingress]

  var id: String { tunnel.id }
  var hostnames: [String] { ingress.compactMap(\.hostname) }

  var statusLabel: String {
    switch tunnel.status {
    case "healthy": return "Healthy"
    case "degraded": return "Degraded"
    case "down": return "Down"
    case "inactive", nil: return "Inactive"
    case let other?: return other.capitalized
    }
  }

  var routesLabel: String {
    if ingress.isEmpty { return "No ingress in the dashboard (local config file or none)" }
    return ingress.map { ($0.hostname ?? "*") + " → " + $0.service }.joined(separator: ", ")
  }
}
