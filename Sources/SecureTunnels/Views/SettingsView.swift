import AppKit
import SwiftUI
import SecureTunnelsCore

struct SettingsView: View {
  @Environment(TunnelManager.self) private var manager
  @Environment(AppSettings.self) private var settings
  @State private var importMessage: String?

  var body: some View {
    @Bindable var settings = settings
    Form {
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

      Section("Secure Pipes") {
        if SecurePipesImporter.isAvailable() {
          Text("Secure Pipes connections were found at \(SecurePipesImporter.plistURL.path).")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button("Import Connections") { importFromSecurePipes() }
              .help("Read the Secure Pipes connection list and add or update tunnels")
            Text("Existing tunnels with the same Secure Pipes ID are updated, not duplicated.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let importMessage {
            Text(importMessage).font(.caption)
          }
        } else {
          Text("No Secure Pipes configuration was found on this Mac.")
            .foregroundStyle(.secondary)
        }
      }

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

      Section("About") {
        LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        LabeledContent("ssh", value: SSHCommand.executable)
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
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

  private func importFromSecurePipes() {
    do {
      let summary = try manager.importFromSecurePipes()
      importMessage = "Imported \(summary.added) new, updated \(summary.updated). Enter each tunnel's passphrase or password in Manage Tunnels."
    } catch {
      importMessage = "Import failed: \(error.localizedDescription)"
    }
  }
}
