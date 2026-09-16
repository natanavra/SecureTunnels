import AppKit
import SwiftUI
import SecureTunnelsCore

enum SettingsSection: String, CaseIterable, Identifiable {
  case startup = "Startup"
  case securePipes = "Secure Pipes"
  case cloudflare = "Cloudflare"
  case storage = "Storage"
  case about = "About"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .startup: return "power"
    case .securePipes: return "square.and.arrow.down"
    case .cloudflare: return "cloud"
    case .storage: return "internaldrive"
    case .about: return "info.circle"
    }
  }
}

/// The settings form. With a section it shows only that part, which is how the main window's sidebar uses it.
struct SettingsView: View {
  @Environment(TunnelManager.self) private var manager
  @Environment(AppSettings.self) private var settings
  var section: SettingsSection?
  @State private var importFlow = SecurePipesImportFlow()
  @State private var cloudflareToken = ""
  @State private var loadedCloudflareToken = false

  private func shows(_ candidate: SettingsSection) -> Bool {
    section == nil || section == candidate
  }

  var body: some View {
    @Bindable var settings = settings
    Form {
      if shows(.startup) {
      Section("Startup") {
        Toggle("Launch SecureTunnels at login", isOn: $settings.launchAtLogin)
        if let error = settings.launchAtLoginError {
          Text(error).font(.caption).foregroundStyle(.red)
        } else if settings.launchAtLoginNeedsApproval {
          Text("Approve SecureTunnels under System Settings › General › Login Items.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("Tunnels marked “Connect automatically” are started right after launch.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("Reconnect active tunnels after the Mac wakes from sleep", isOn: $settings.reconnectAfterWake)
      }
      }

      if shows(.securePipes) {
      Section("Secure Pipes") {
        if SecurePipesImporter.isAvailable() {
          Text("Secure Pipes connections were found at \(SecurePipesImporter.plistURL.path).")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button { importFlow.begin(manager: manager) } label: {
              Label("Import Connections", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .help("Read the Secure Pipes connection list and choose what to add")
            Text("Adds connections you do not have yet. Nothing is removed, and overwriting existing ones is a separate choice you confirm.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          Text("No Secure Pipes configuration was found on this Mac.")
            .foregroundStyle(.secondary)
        }
      }
      }

      if shows(.cloudflare) {
      Section("Cloudflare") {
        cloudflaredRow
        SecureField("API token", text: $cloudflareToken, prompt: Text("Cloudflare API token"))
          .onAppear {
            guard !loadedCloudflareToken else { return }
            cloudflareToken = CloudflareSettings.shared.token
            loadedCloudflareToken = true
          }
        HStack {
          Button {
            Task { await CloudflareSettings.shared.saveAndVerify(token: cloudflareToken) }
          } label: {
            Label(CloudflareSettings.shared.isVerifying ? "Checking…" : "Save and Verify", systemImage: "checkmark.shield")
          }
          .buttonStyle(.borderedProminent)
          .disabled(CloudflareSettings.shared.isVerifying)
          .help("Store the token in the keychain and list the accounts and zones it can manage")
          Link("Create a token", destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
            .help("Opens the Cloudflare dashboard. The token needs Account > Cloudflare Tunnel > Edit and Zone > DNS > Edit.")
        }
        if CloudflareSettings.shared.accounts.count > 1 {
          Picker("Account", selection: Binding(
            get: { CloudflareSettings.shared.accountID },
            set: { id in
              if let account = CloudflareSettings.shared.accounts.first(where: { $0.id == id }) {
                CloudflareSettings.shared.selectAccount(account)
              }
            }
          )) {
            ForEach(CloudflareSettings.shared.accounts) { account in
              Text(account.name).tag(account.id)
            }
          }
        } else if !CloudflareSettings.shared.accountName.isEmpty {
          LabeledContent("Account", value: CloudflareSettings.shared.accountName)
        }
        if let verification = CloudflareSettings.shared.verification {
          Text(verification).font(.caption).foregroundStyle(verification.hasPrefix("Token works") ? Color.secondary : Color.red)
        }
        Text("The token needs Account > Cloudflare Tunnel > Edit and Zone > DNS > Edit. Temporary trycloudflare.com tunnels work without a token.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if CloudflareSettings.shared.hasToken && !CloudflareSettings.shared.accountID.isEmpty {
        Section("Tunnels in \(CloudflareSettings.shared.accountName)") {
          RemoteTunnelsList()
        }
      }
      }

      if shows(.storage) {
      Section("Storage") {
        LabeledContent("Tunnels") { pathLink(AppPaths.tunnelsFile) }
        LabeledContent("Known hosts") { pathLink(AppPaths.knownHostsFile) }
        LabeledContent("Logs") { pathLink(AppPaths.logsDirectory) }
        Text("Passphrases and passwords are stored in your login keychain, never in these files.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let loadError = manager.loadError {
          Text(loadError).font(.caption).foregroundStyle(.red)
        }
      }
      }

      if shows(.about) {
      Section("About") {
        LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        LabeledContent("ssh", value: SSHCommand.executable)
        LabeledContent("Source") {
          Link("github.com/natanavra/SecureTunnels", destination: URL(string: "https://github.com/natanavra/SecureTunnels")!)
        }
      }
      }
    }
    .formStyle(.grouped)
    .modifier(SecurePipesImportDialogs(flow: importFlow))
  }

  @ViewBuilder
  private var cloudflaredRow: some View {
    let cf = CloudflareSettings.shared
    LabeledContent("cloudflared") {
      HStack(spacing: 8) {
        if let url = cf.cloudflaredURL {
          Text("\(cf.cloudflaredVersion ?? "installed") at \(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
          Text("Not installed").foregroundStyle(.secondary)
          Button {
            Task { await cf.installCloudflared() }
          } label: {
            Label(cf.isInstalling ? "Installing…" : "Install", systemImage: "arrow.down.circle")
          }
          .buttonStyle(.bordered)
          .disabled(cf.isInstalling)
          .help("Download the official cloudflared release from GitHub into the app's support folder")
        }
      }
    }
    if let error = cf.installError {
      Text(error).font(.caption).foregroundStyle(.red)
    }
  }

  private func pathLink(_ url: URL) -> some View {
    Button {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } label: {
      Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .buttonStyle(.link)
    .help("Reveal in Finder")
  }
}

/// The tunnels that exist in the Cloudflare account, with adopt and delete actions.
private struct RemoteTunnelsList: View {
  @Environment(TunnelManager.self) private var manager
  @State private var pendingDelete: RemoteTunnelInfo?
  @State private var deleteError: String?

  private var cf: CloudflareSettings { CloudflareSettings.shared }

  var body: some View {
    HStack {
      Text(cf.isLoadingTunnels ? "Loading…" : "\(cf.remoteTunnels.count) tunnel(s) in the account.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        Task { await cf.refreshRemoteTunnels() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(cf.isLoadingTunnels)
      .help("Reload the tunnel list from Cloudflare")
    }
    .onAppear {
      if cf.remoteTunnels.isEmpty { Task { await cf.refreshRemoteTunnels() } }
    }
    if let error = cf.tunnelsError {
      Text(error).font(.caption).foregroundStyle(.red)
    }
    ForEach(cf.remoteTunnels) { info in
      let local = manager.localTunnel(forRemoteID: info.tunnel.id)
      HStack(alignment: .top, spacing: 10) {
        Circle()
          .fill(statusColor(info))
          .frame(width: 8, height: 8)
          .padding(.top, 6)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(info.tunnel.name)
            Text(info.statusLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
            if let local {
              Text("in SecureTunnels as “\(local.name)”")
                .font(.caption)
                .foregroundStyle(.blue)
            }
          }
          Text(info.routesLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer()
        if let local {
          Button {
            manager.pendingSelection = local.id
          } label: { Label("Open", systemImage: "arrow.up.right.square") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open the local tunnel that runs this Cloudflare tunnel")
        } else {
          Button {
            if let tunnel = manager.adoptCloudflareTunnel(info) { manager.pendingSelection = tunnel.id }
          } label: { Label("Add", systemImage: "plus") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(info.ingress.isEmpty)
            .help(info.ingress.isEmpty
              ? "This tunnel has no ingress in the dashboard, so the app cannot run it"
              : "Add this tunnel to SecureTunnels and run it from here. Its ingress and DNS stay as they are.")
        }
        Button(role: .destructive) {
          pendingDelete = info
        } label: { Image(systemName: "trash") }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Delete this tunnel from Cloudflare, including the DNS records that point to it")
      }
      .padding(.vertical, 2)
    }
    if let deleteError {
      Text(deleteError).font(.caption).foregroundStyle(.red)
    }
    EmptyView()
      .confirmationDialog(
        "Delete “\(pendingDelete?.tunnel.name ?? "")” from Cloudflare?",
        isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete Tunnel", role: .destructive) {
          guard let info = pendingDelete else { return }
          pendingDelete = nil
          Task {
            do {
              try await cf.deleteRemoteTunnel(info)
              manager.unlinkCloudflareTunnel(remoteID: info.tunnel.id)
              deleteError = nil
            } catch {
              deleteError = "Delete failed: \(error.localizedDescription)"
            }
          }
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: {
        Text(deleteMessage)
      }
  }

  private var deleteMessage: String {
    guard let info = pendingDelete else { return "" }
    var text = "The tunnel and its connections are removed from the Cloudflare account. This cannot be undone."
    if !info.hostnames.isEmpty {
      text += " DNS records for \(info.hostnames.joined(separator: ", ")) that point to it are deleted too."
    }
    if manager.localTunnel(forRemoteID: info.tunnel.id) != nil {
      text += " The SecureTunnels entry stays and will create a new tunnel on its next connect."
    }
    return text
  }

  private func statusColor(_ info: RemoteTunnelInfo) -> Color {
    switch info.tunnel.status {
    case "healthy": return .green
    case "degraded": return .orange
    case "down": return .red
    default: return Color.secondary.opacity(0.5)
    }
  }
}
