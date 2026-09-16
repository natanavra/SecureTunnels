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
  @State private var portUsage: PortUsage?
  @State private var probeTask: Task<Void, Never>?

  private var status: TunnelStatus { manager.status(of: tunnel.id) }
  private var profile: Profile? { manager.profile(for: tunnel) }

  var body: some View {
    Form {
      Section("Connection") {
        TextField("Name", text: $tunnel.name)
        HStack {
          TextField("Group", text: $tunnel.group, prompt: Text("Optional, for example Production"))
          if !existingGroups.isEmpty {
            Menu {
              ForEach(existingGroups, id: \.self) { group in
                Button(group) { tunnel.group = group }
              }
            } label: {
              Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
          }
        }
        Picker("Type", selection: $tunnel.type) {
          ForEach(TunnelType.allCases) { type in
            Text(type.title).tag(type)
          }
        }
      }

      Section("SSH Server") {
        Picker("Server", selection: $tunnel.profileID) {
          Text("Custom settings").tag(UUID?.none)
          if !manager.profiles.isEmpty {
            Divider()
            ForEach(manager.profiles) { profile in
              Text(profile.name).tag(UUID?.some(profile.id))
            }
          }
        }
        if let profile {
          LabeledContent("Host", value: profile.host.isEmpty ? "Not set" : profile.summary)
          LabeledContent("Identity file", value: profile.identityFile.isEmpty ? "ssh defaults or agent" : profile.identityFile)
          HStack {
            Text("Passphrase and password are stored on the profile.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Edit Profile…") { manager.pendingProfileSelection = profile.id }
              .controlSize(.small)
          }
        } else {
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
          HStack {
            Text("Save these settings as a profile to share them with other tunnels.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Save as Profile…") {
              if let created = manager.createProfile(fromTunnel: tunnel.id) {
                manager.pendingProfileSelection = created.id
              }
            }
            .controlSize(.small)
            .disabled(tunnel.host.isEmpty)
          }
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
        if let portUsage, tunnel.listensLocally, status != .connected {
          Label("Local \(portUsage.description). Connecting will fail until it is free.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      Section("Behavior") {
        Toggle("Connect automatically when SecureTunnels starts", isOn: $tunnel.autoConnect)
        Toggle("Reconnect automatically if the connection drops", isOn: $tunnel.autoReconnect)
        if tunnel.autoReconnect {
          Stepper("First retry after \(tunnel.reconnectInterval) seconds", value: $tunnel.reconnectInterval, in: 5...600, step: 5)
          Text("Each further retry waits twice as long, up to five minutes, and never gives up. A network change retries at once.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
        if let output = manager.lastOutput[tunnel.id], !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("ssh output from the last attempt")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
              }
              .controlSize(.small)
            }
            ScrollView {
              Text(output.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 96)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
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
    .onAppear {
      loadSecrets()
      probePort()
    }
    .onChange(of: tunnel.bindPort) { probePort() }
    .onChange(of: tunnel.type) { probePort() }
    .onChange(of: status) { probePort() }
  }

  private var existingGroups: [String] {
    manager.groups.filter { !$0.isEmpty && $0 != tunnel.group }
  }

  private var forwardTitle: String {
    switch tunnel.type {
    case .local: return "Local Forward"
    case .remote: return "Remote Forward"
    case .dynamic: return "SOCKS Proxy"
    }
  }

  private var commandPreview: String {
    let resolved = manager.resolved(tunnel)
    let args = SSHCommand.arguments(for: resolved, knownHostsFile: "known_hosts", hasPassword: !password.isEmpty)
    return (["ssh"] + args.filter { !$0.hasPrefix("-o") }).joined(separator: " ")
  }

  /// Checks who holds the local port so the warning shows before the user presses Connect.
  private func probePort() {
    probeTask?.cancel()
    guard tunnel.listensLocally else {
      portUsage = nil
      return
    }
    let port = tunnel.bindPort
    probeTask = Task {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      let usage = await Task.detached { PortProbe.listener(on: port) }.value
      guard !Task.isCancelled else { return }
      // Our own ssh holding the port is not a conflict.
      portUsage = (usage?.processName == "ssh" && status == .connected) ? nil : usage
    }
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
