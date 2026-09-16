import AppKit
import SwiftUI
import SecureTunnelsCore

struct ProfileEditorView: View {
  @Environment(TunnelManager.self) private var manager
  @Binding var profile: Profile

  @State private var passphrase = ""
  @State private var password = ""
  @State private var secretError: String?
  @State private var loadedSecrets = false

  var body: some View {
    Form {
      Section("Profile") {
        TextField("Name", text: $profile.name)
        Text(usageText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("SSH Server") {
        TextField("Host", text: $profile.host, prompt: Text("bastion.example.com"))
        TextField("Port", value: $profile.port, format: .number.grouping(.never))
        TextField("Username", text: $profile.username, prompt: Text("ec2-user"))
        HStack {
          TextField("Identity file", text: $profile.identityFile, prompt: Text("Leave empty to use ~/.ssh keys or the agent"))
          Button("Choose…") { chooseIdentityFile() }
        }
        SecureField("Key passphrase", text: $passphrase, prompt: Text("Only if the key is encrypted"))
          .onChange(of: passphrase) { _, value in store(value, .passphrase) }
        SecureField("Password", text: $password, prompt: Text("Only for password authentication"))
          .onChange(of: password) { _, value in store(value, .password) }
        if let secretError {
          Text(secretError).font(.caption).foregroundStyle(.red)
        }
      }

      Section("Tunnels using this profile") {
        let tunnels = manager.tunnels(using: profile.id)
        if tunnels.isEmpty {
          Text("None yet. Pick this profile under “Server” in a tunnel.")
            .foregroundStyle(.secondary)
        }
        ForEach(tunnels) { tunnel in
          HStack {
            StatusDot(status: manager.status(of: tunnel.id), size: 8)
            Text(tunnel.name)
            Spacer()
            Text(tunnel.forwardDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
            Button("Open") { manager.pendingSelection = tunnel.id }
              .controlSize(.small)
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: loadSecrets)
  }

  private var usageText: String {
    let count = manager.tunnels(using: profile.id).count
    switch count {
    case 0: return "Reusable server settings and credentials for several tunnels."
    case 1: return "Used by 1 tunnel."
    default: return "Used by \(count) tunnels."
    }
  }

  private func loadSecrets() {
    guard !loadedSecrets else { return }
    passphrase = manager.secret(.passphrase, for: profile.id)
    password = manager.secret(.password, for: profile.id)
    loadedSecrets = true
  }

  private func store(_ value: String, _ kind: SecretKind) {
    guard loadedSecrets else { return }
    do {
      try manager.setSecret(value, kind, for: profile.id)
      secretError = nil
    } catch {
      secretError = "Could not save to keychain: \(error.localizedDescription)"
    }
  }

  private func chooseIdentityFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.message = "Choose the private key for this profile"
    panel.directoryURL = profile.identityFile.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
      : URL(fileURLWithPath: (profile.identityFile as NSString).expandingTildeInPath).deletingLastPathComponent()
    if panel.runModal() == .OK, let url = panel.url {
      profile.identityFile = url.path
    }
  }
}
