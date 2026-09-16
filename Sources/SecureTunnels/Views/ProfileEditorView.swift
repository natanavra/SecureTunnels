import AppKit
import SwiftUI
import SecureTunnelsCore

struct ProfileEditorView: View {
  @Environment(TunnelManager.self) private var manager
  let profile: Profile

  @State private var draft: Profile
  @State private var passphrase = ""
  @State private var password = ""
  @State private var savedPassphrase = ""
  @State private var savedPassword = ""
  @State private var secretError: String?

  init(profile: Profile) {
    self.profile = profile
    _draft = State(initialValue: profile)
  }

  private var stored: Profile { manager.profile(profile.id) ?? profile }

  private var isDirty: Bool {
    draft != stored || passphrase != savedPassphrase || password != savedPassword
  }

  var body: some View {
    Form {
      Section("Profile") {
        TextField("Name", text: $draft.name)
        Text(usageText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("SSH Server") {
        TextField("Host", text: $draft.host, prompt: Text("bastion.example.com"))
        TextField("Port", value: $draft.port, format: .number.grouping(.never))
        TextField("Username", text: $draft.username, prompt: Text("ec2-user"))
        HStack {
          TextField("Identity file", text: $draft.identityFile, prompt: Text("Leave empty to use ~/.ssh keys or the agent"))
          Button { chooseIdentityFile() } label: { Label("Choose", systemImage: "folder") }
            .buttonStyle(.bordered)
            .help("Pick the private key file for this profile")
        }
        SecureField("Key passphrase", text: $passphrase, prompt: Text("Only if the key is encrypted"))
        SecureField("Password", text: $password, prompt: Text("Only for password authentication"))
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
            Button { manager.pendingSelection = tunnel.id } label: {
              Label("Open", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Edit \(tunnel.name)")
          }
        }
      }
    }
    .formStyle(.grouped)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if isDirty {
        UnsavedChangesBar(revert: revert, save: save)
      }
    }
    .animation(.default, value: isDirty)
    .onAppear(perform: loadSecrets)
    .onChange(of: isDirty) { _, dirty in publish(dirty) }
    .onDisappear { manager.clearEditorSession() }
  }

  private var usageText: String {
    let count = manager.tunnels(using: profile.id).count
    switch count {
    case 0: return "Reusable server settings and credentials for several tunnels."
    case 1: return "Used by 1 tunnel."
    default: return "Used by \(count) tunnels."
    }
  }

  private func publish(_ dirty: Bool) {
    manager.editorHasChanges = dirty
    manager.editorSave = dirty ? save : nil
    manager.editorDiscard = dirty ? revert : nil
  }

  private func loadSecrets() {
    savedPassphrase = manager.secret(.passphrase, for: profile.id)
    savedPassword = manager.secret(.password, for: profile.id)
    passphrase = savedPassphrase
    password = savedPassword
  }

  private func save() {
    manager.updateProfile(draft)
    do {
      try manager.setSecret(passphrase, .passphrase, for: profile.id)
      try manager.setSecret(password, .password, for: profile.id)
      savedPassphrase = passphrase
      savedPassword = password
      secretError = nil
    } catch {
      secretError = "Could not save to keychain: \(error.localizedDescription)"
    }
  }

  private func revert() {
    draft = stored
    passphrase = savedPassphrase
    password = savedPassword
  }

  private func chooseIdentityFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.message = "Choose the private key for this profile"
    panel.directoryURL = draft.identityFile.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
      : URL(fileURLWithPath: (draft.identityFile as NSString).expandingTildeInPath).deletingLastPathComponent()
    if panel.runModal() == .OK, let url = panel.url {
      draft.identityFile = url.path
    }
  }
}
