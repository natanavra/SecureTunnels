import AppKit
import SwiftUI
import SecureTunnelsCore

struct TunnelEditorView: View {
  @Environment(TunnelManager.self) private var manager
  @Binding var tunnel: Tunnel

  @State private var passphrase = ""
  @State private var password = ""
  @State private var secretError: String?
  @State private var loadedSecrets = false

  private var status: TunnelStatus { manager.status(of: tunnel.id) }

  var body: some View {
    Form {
      Section("Connection") {
        TextField("Name", text: $tunnel.name)
        Picker("Type", selection: $tunnel.type) {
          ForEach(TunnelType.allCases) { type in
            Text(type.title).tag(type)
          }
        }
      }

      Section("SSH Server") {
        TextField("Host", text: $tunnel.host, prompt: Text("example.com or 203.0.113.10"))
        TextField("Port", value: $tunnel.port, format: .number.grouping(.never))
        TextField("Username", text: $tunnel.username, prompt: Text("ec2-user"))
        HStack {
          TextField("Identity file", text: $tunnel.identityFile, prompt: Text("Leave empty to use ~/.ssh keys or the agent"))
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

      Section(forwardTitle) {
        switch tunnel.type {
        case .local:
          TextField("Local address", text: $tunnel.bindAddress, prompt: Text("localhost"))
          TextField("Local port", value: $tunnel.bindPort, format: .number.grouping(.never))
          TextField("Remote host", text: $tunnel.targetHost, prompt: Text("Host as seen from the server"))
          TextField("Remote port", value: $tunnel.targetPort, format: .number.grouping(.never))
        case .remote:
          TextField("Remote bind address", text: $tunnel.bindAddress, prompt: Text("localhost"))
          TextField("Remote port", value: $tunnel.bindPort, format: .number.grouping(.never))
          TextField("Local host", text: $tunnel.targetHost, prompt: Text("localhost"))
          TextField("Local port", value: $tunnel.targetPort, format: .number.grouping(.never))
        case .dynamic:
          TextField("Local address", text: $tunnel.bindAddress, prompt: Text("localhost"))
          TextField("Local port", value: $tunnel.bindPort, format: .number.grouping(.never))
        }
      }

      Section("Behavior") {
        Toggle("Connect automatically when SecureTunnels starts", isOn: $tunnel.autoConnect)
        Toggle("Reconnect automatically if the connection drops", isOn: $tunnel.autoReconnect)
        if tunnel.autoReconnect {
          Stepper("Reconnect after \(tunnel.reconnectInterval) seconds", value: $tunnel.reconnectInterval, in: 5...600, step: 5)
        }
        Stepper("Keep-alive every \(tunnel.serverAliveInterval) seconds", value: $tunnel.serverAliveInterval, in: 5...300, step: 5)
        Stepper("Give up after \(tunnel.serverAliveCountMax) missed keep-alives", value: $tunnel.serverAliveCountMax, in: 1...20)
        Toggle("Compress data", isOn: $tunnel.compression)
        Toggle("Strict host key checking", isOn: $tunnel.strictHostKeyChecking)
        Text(tunnel.strictHostKeyChecking
          ? "Only servers already listed in the app's known_hosts file are accepted."
          : "New servers are trusted on first connect. A changed host key is always rejected.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Status") {
        LabeledContent("Status") {
          HStack(spacing: 6) {
            StatusDot(status: status, size: 8)
            Text(status.label)
          }
        }
        if let error = manager.lastError[tunnel.id] {
          LabeledContent("Last error") {
            Text(error)
              .foregroundStyle(.red)
              .textSelection(.enabled)
              .multilineTextAlignment(.trailing)
          }
        }
        LabeledContent("Command") {
          Text(commandPreview)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.secondary)
        }
        HStack {
          Button(status.isActive ? "Disconnect" : "Connect") { manager.toggle(tunnel.id) }
          Button("Show Log") { showLog() }
            .disabled(!FileManager.default.fileExists(atPath: AppPaths.logFile(for: tunnel.id).path))
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: loadSecrets)
  }

  private var forwardTitle: String {
    switch tunnel.type {
    case .local: return "Local Forward"
    case .remote: return "Remote Forward"
    case .dynamic: return "SOCKS Proxy"
    }
  }

  private var commandPreview: String {
    let args = SSHCommand.arguments(for: tunnel, knownHostsFile: "known_hosts", hasPassword: !password.isEmpty)
    return (["ssh"] + args.filter { !$0.hasPrefix("-o") }).joined(separator: " ")
  }

  private func loadSecrets() {
    guard !loadedSecrets else { return }
    passphrase = manager.secret(.passphrase, for: tunnel.id)
    password = manager.secret(.password, for: tunnel.id)
    loadedSecrets = true
  }

  private func store(_ value: String, _ kind: SecretKind) {
    guard loadedSecrets else { return }
    do {
      try manager.setSecret(value, kind, for: tunnel.id)
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
    panel.message = "Choose the private key for this tunnel"
    panel.directoryURL = tunnel.identityFile.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
      : URL(fileURLWithPath: tunnel.expandedIdentityFile).deletingLastPathComponent()
    if panel.runModal() == .OK, let url = panel.url {
      tunnel.identityFile = url.path
    }
  }

  private func showLog() {
    NSWorkspace.shared.open(AppPaths.logFile(for: tunnel.id))
  }
}
