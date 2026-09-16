import AppKit
import SwiftUI
import SecureTunnelsCore

enum SettingsSection: String, CaseIterable, Identifiable {
  case startup = "Startup"
  case securePipes = "Secure Pipes"
  case storage = "Storage"
  case about = "About"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .startup: return "power"
    case .securePipes: return "square.and.arrow.down"
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
