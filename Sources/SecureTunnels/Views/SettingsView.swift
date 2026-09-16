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
        LabeledContent("Connected via") {
          HStack(spacing: 8) {
            Text(CloudflareSettings.shared.backend.label)
            if CloudflareSettings.shared.backend == .cli, let cert = CloudflareSettings.shared.cliCertificate {
              Text("account \(cert.accountID.prefix(8))…, zone \(cert.zoneID.prefix(8))…")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        cliLoginRow
        SecureField("API token", text: $cloudflareToken, prompt: Text("Optional when signed in with cloudflared"))
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
        Text("A token covers every zone and is used when present. Without one, the cloudflared sign-in works for the zone chosen in the browser: tunnels are created and routed with the CLI and run with their local credentials file. Temporary trycloudflare.com tunnels need neither. The tunnels in the account are listed under Cloudflare in the sidebar.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
  private var cliLoginRow: some View {
    let cf = CloudflareSettings.shared
    LabeledContent("cloudflared login") {
      HStack(spacing: 8) {
        if cf.cliLoggedIn {
          Text("Signed in (~/.cloudflared/cert.pem)")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Not signed in").foregroundStyle(.secondary)
        }
        Button {
          Task { await cf.loginWithCLI() }
        } label: {
          Label(cf.isLoggingIn ? "Waiting for browser…" : (cf.cliLoggedIn ? "Sign in again" : "Sign in with cloudflared"), systemImage: "person.crop.circle.badge.checkmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(cf.isLoggingIn || cf.cloudflaredURL == nil)
        .help("Runs cloudflared tunnel login, which opens the Cloudflare dashboard in the browser to pick a zone")
      }
    }
    if let error = cf.loginError {
      Text(error).font(.caption).foregroundStyle(.red)
    }
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

