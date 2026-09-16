import AppKit
import Foundation
import Network
import Observation
import SecureTunnelsCore

enum TunnelStatus: Equatable {
  case disconnected
  case connecting
  case connected
  case reconnecting(at: Date, attempt: Int)
  case waitingForNetwork
  case failed(String)

  var isActive: Bool {
    switch self {
    case .connecting, .connected, .reconnecting, .waitingForNetwork: return true
    case .disconnected, .failed: return false
    }
  }

  var label: String {
    switch self {
    case .disconnected: return "Disconnected"
    case .connecting: return "Connecting…"
    case .connected: return "Connected"
    case .reconnecting(let date, let attempt):
      let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
      return attempt > 1 ? "Retry \(attempt) in \(seconds)s" : "Reconnecting in \(seconds)s"
    case .waitingForNetwork: return "Waiting for network"
    case .failed: return "Failed"
    }
  }
}

struct ImportSummary {
  var added = 0
  var updated = 0
  var skipped = 0
}

/// What an import would do, shown to the user before anything changes.
struct ImportPreview {
  var new: [Tunnel]
  var existing: [Tunnel]
}

@MainActor
@Observable
final class TunnelManager {
  static let shared = TunnelManager()

  /// Longest pause between reconnect attempts. Retries never stop while the tunnel is wanted.
  static let maxReconnectDelay = 300

  private(set) var tunnels: [Tunnel] = []
  private(set) var profiles: [Profile] = []
  private(set) var status: [UUID: TunnelStatus] = [:]
  private(set) var lastError: [UUID: String] = [:]
  /// Tail of ssh's output from the most recent attempt, for the error details view.
  private(set) var lastOutput: [UUID: String] = [:]
  /// Public address of a connected Cloudflare tunnel (quick tunnels only know it once cloudflared prints it).
  private(set) var publicURL: [UUID: String] = [:]
  private(set) var loadError: String?
  private(set) var networkAvailable = true
  /// Set by the popover to ask the main window to show a tunnel, a profile or a sidebar mode. The window clears it.
  var pendingSelection: UUID?
  var pendingProfileSelection: UUID?
  var pendingMode: SidebarMode?

  /// The open editor reports unsaved changes here so the window can ask before switching away.
  var editorHasChanges = false
  @ObservationIgnored var editorSave: (() -> Void)?
  @ObservationIgnored var editorDiscard: (() -> Void)?

  func clearEditorSession() {
    editorHasChanges = false
    editorSave = nil
    editorDiscard = nil
  }

  @ObservationIgnored private var processes: [UUID: Process] = [:]
  @ObservationIgnored private var launching: Set<UUID> = []
  @ObservationIgnored private var stderrBuffers: [UUID: String] = [:]
  @ObservationIgnored private var stdoutBuffers: [UUID: String] = [:]
  @ObservationIgnored private var wantsRunning: Set<UUID> = []
  @ObservationIgnored private var attempts: [UUID: Int] = [:]
  @ObservationIgnored private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var suspendedForSleep: Set<UUID> = []
  @ObservationIgnored private var pathMonitor: NWPathMonitor?
  @ObservationIgnored private var persistenceDisabled = false

  var connectedCount: Int {
    tunnels.filter { status[$0.id] == .connected }.count
  }

  var activeCount: Int {
    tunnels.filter { status[$0.id]?.isActive == true }.count
  }

  /// Group names in display order: named groups alphabetically, ungrouped last.
  var groups: [String] {
    let names = Set(tunnels.map(\.group)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    return names.filter { !$0.isEmpty } + (names.contains("") ? [""] : [])
  }

  func tunnels(inGroup group: String) -> [Tunnel] {
    tunnels.filter { $0.group == group }
  }

  private init() {
    do {
      let stored = try TunnelStorage.load()
      tunnels = stored.tunnels
      profiles = stored.profiles
      if stored.version < 2, TunnelStorage.exists() {
        saveNow()
      }
    } catch {
      loadError = "Could not read tunnels.json: \(error.localizedDescription)"
    }
  }

  // MARK: Lifecycle

  func start() {
    try? AppPaths.ensureDirectories()
    SessionRegistry.killStaleSessions()
    importSecurePipesOnFirstRun()
    observeSleep()
    observeNetwork()
    connectAutoTunnels()
  }

  func shutdown() {
    for task in reconnectTasks.values { task.cancel() }
    reconnectTasks.removeAll()
    wantsRunning.removeAll()
    for process in processes.values where process.isRunning {
      process.terminate()
    }
    SessionRegistry.clear()
    saveNow()
  }

  private func importSecurePipesOnFirstRun() {
    guard !AppSettings.shared.didImportSecurePipes, !TunnelStorage.exists(), SecurePipesImporter.isAvailable() else {
      return
    }
    _ = try? importFromSecurePipes()
    AppSettings.shared.didImportSecurePipes = true
  }

  private func observeSleep() {
    let center = NSWorkspace.shared.notificationCenter
    sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
      Task { @MainActor in self.suspendForSleep() }
    })
    sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
      Task { @MainActor in await self.resumeAfterWake() }
    })
  }

  private func observeNetwork() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { path in
      // requiresConnection (on-demand VPN, dial-up style links) still allows connecting, so only a hard
      // "unsatisfied" counts as offline.
      let satisfied = path.status != .unsatisfied
      Task { @MainActor in self.handleNetworkChange(satisfied: satisfied) }
    }
    monitor.start(queue: DispatchQueue(label: "SecureTunnels.network"))
    pathMonitor = monitor
  }

  /// When the network drops, ssh sessions are dead even if ssh has not noticed yet. Drop them right away and
  /// relaunch as soon as a route is back instead of waiting for keep-alives and the reconnect timer.
  private func handleNetworkChange(satisfied: Bool) {
    guard satisfied != networkAvailable else { return }
    networkAvailable = satisfied
    let ids = wantsRunning.subtracting(suspendedForSleep)
    if satisfied {
      for id in ids where processes[id] == nil && !launching.contains(id) {
        cancelReconnect(id)
        attempts[id] = 0
        launch(id)
      }
      return
    }
    for id in ids {
      cancelReconnect(id)
      terminateProcess(for: id)
      status[id] = .waitingForNetwork
    }
  }

  /// ssh sessions rarely survive sleep. Kill them cleanly and remember which ones to bring back.
  private func suspendForSleep() {
    guard AppSettings.shared.reconnectAfterWake else { return }
    suspendedForSleep = wantsRunning
    for id in wantsRunning {
      cancelReconnect(id)
      terminateProcess(for: id)
      status[id] = .reconnecting(at: Date().addingTimeInterval(3), attempt: 1)
    }
  }

  private func resumeAfterWake() async {
    guard !suspendedForSleep.isEmpty else { return }
    let ids = suspendedForSleep
    suspendedForSleep.removeAll()
    try? await Task.sleep(for: .seconds(3))
    for id in ids where wantsRunning.contains(id) {
      attempts[id] = 0
      launch(id)
    }
  }

  // MARK: Tunnel CRUD

  func tunnel(_ id: UUID) -> Tunnel? {
    tunnels.first { $0.id == id }
  }

  @discardableResult
  func add(_ tunnel: Tunnel = Tunnel()) -> Tunnel {
    tunnels.append(tunnel)
    scheduleSave()
    return tunnel
  }

  func update(_ tunnel: Tunnel) {
    guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
    guard tunnels[index] != tunnel else { return }
    tunnels[index] = tunnel
    scheduleSave()
  }

  func duplicate(_ id: UUID) -> Tunnel? {
    guard var copy = tunnel(id) else { return nil }
    copy.id = UUID()
    copy.name += " copy"
    copy.autoConnect = false
    copy.importedFromSecurePipes = false
    if copy.profileID == nil {
      copySecrets(from: id, to: copy.id)
    }
    return add(copy)
  }

  func remove(_ id: UUID) {
    disconnect(id)
    if let tunnel = tunnel(id), tunnel.type == .cloudflare {
      deprovisionCloudflare(tunnel)
    }
    tunnels.removeAll { $0.id == id }
    publicURL[id] = nil
    status[id] = nil
    lastError[id] = nil
    lastOutput[id] = nil
    Keychain.deleteAll(ownerID: id)
    try? FileManager.default.removeItem(at: AppPaths.logFile(for: id))
    scheduleSave()
  }

  func move(from source: IndexSet, to destination: Int) {
    tunnels.move(fromOffsets: source, toOffset: destination)
    scheduleSave()
  }

  // MARK: Profiles

  func profile(_ id: UUID) -> Profile? {
    profiles.first { $0.id == id }
  }

  func profile(for tunnel: Tunnel) -> Profile? {
    tunnel.profileID.flatMap(profile)
  }

  /// The tunnel with its profile applied, which is what ssh actually runs.
  func resolved(_ tunnel: Tunnel) -> Tunnel {
    tunnel.applying(profile(for: tunnel))
  }

  /// Whose keychain items hold the passphrase and password for this tunnel.
  func secretOwner(for tunnel: Tunnel) -> UUID {
    profile(for: tunnel)?.id ?? tunnel.id
  }

  func tunnels(using profileID: UUID) -> [Tunnel] {
    tunnels.filter { $0.profileID == profileID }
  }

  @discardableResult
  func addProfile(_ profile: Profile = Profile()) -> Profile {
    profiles.append(profile)
    scheduleSave()
    return profile
  }

  func updateProfile(_ profile: Profile) {
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
    guard profiles[index] != profile else { return }
    profiles[index] = profile
    scheduleSave()
  }

  /// Removes a profile. Tunnels that used it keep working: they get a copy of its settings and secrets.
  func removeProfile(_ id: UUID) {
    guard let profile = profile(id) else { return }
    for index in tunnels.indices where tunnels[index].profileID == id {
      tunnels[index] = tunnels[index].applying(profile)
      tunnels[index].profileID = nil
      copySecrets(from: id, to: tunnels[index].id)
    }
    profiles.removeAll { $0.id == id }
    Keychain.deleteAll(ownerID: id)
    scheduleSave()
  }

  /// Turns a tunnel's own server settings into a profile and links the tunnel to it.
  @discardableResult
  func createProfile(fromTunnel id: UUID) -> Profile? {
    guard var tunnel = tunnel(id), tunnel.profileID == nil else { return nil }
    let profile = Profile(
      name: tunnel.username.isEmpty ? tunnel.host : "\(tunnel.username)@\(tunnel.host)",
      host: tunnel.host,
      port: tunnel.port,
      username: tunnel.username,
      identityFile: tunnel.identityFile
    )
    profiles.append(profile)
    copySecrets(from: id, to: profile.id)
    Keychain.deleteAll(ownerID: id)
    tunnel.profileID = profile.id
    update(tunnel)
    scheduleSave()
    return profile
  }

  private func copySecrets(from source: UUID, to destination: UUID) {
    for kind in SecretKind.allCases {
      if let secret = Keychain.read(kind, ownerID: source) {
        try? Keychain.write(secret, kind, ownerID: destination)
      }
    }
  }

  // MARK: Persistence

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      saveNow()
    }
  }

  private func saveNow() {
    saveTask?.cancel()
    saveTask = nil
    guard !persistenceDisabled else { return }
    do {
      try TunnelStorage.save(StoredData(tunnels: tunnels, profiles: profiles))
      loadError = nil
    } catch {
      loadError = "Could not save tunnels.json: \(error.localizedDescription)"
    }
  }

  // MARK: Demo data

  /// Replaces the in-memory state with sample tunnels for screenshots. Nothing is written to disk afterwards.
  func loadDemoData() {
    persistenceDisabled = true
    let bastion = Profile(name: "Production bastion", host: "bastion.example.com", username: "ec2-user",
      identityFile: "~/.ssh/prod-bastion.pem")
    let mongo = Tunnel(name: "Mongo primary", group: "Production", profileID: bastion.id,
      bindPort: 27018, targetHost: "mongo-1.internal", targetPort: 27017, autoConnect: true)
    let redis = Tunnel(name: "Redis", group: "Production", profileID: bastion.id,
      bindPort: 6380, targetHost: "10.0.4.12", targetPort: 6379, autoConnect: true)
    let rabbit = Tunnel(name: "RabbitMQ console", group: "Production", profileID: bastion.id,
      bindPort: 15672, targetHost: "10.0.4.20", targetPort: 15672)
    let postgres = Tunnel(name: "Analytics Postgres", group: "Staging", host: "staging.example.com", port: 2222,
      username: "deploy", identityFile: "~/.ssh/staging.pem", bindPort: 5433, targetHost: "localhost", targetPort: 5432)
    let socks = Tunnel(name: "Office SOCKS proxy", type: .dynamic, host: "gw.example.com", username: "deploy",
      bindPort: 1080, targetHost: "", targetPort: 0)
    let expose = Tunnel(name: "Expose dev server", type: .remote, host: "demo.example.com", username: "deploy",
      bindAddress: "0.0.0.0", bindPort: 9000, targetHost: "localhost", targetPort: 3000)
    let preview = Tunnel(name: "Preview site", type: .cloudflare, group: "Staging", bindPort: 3000,
      cloudflare: CloudflareConfig(hostname: "preview.example.com", tunnelID: "demo"))
    profiles = [bastion]
    tunnels = [mongo, redis, rabbit, postgres, preview, socks, expose]
    publicURL = [preview.id: "https://preview.example.com"]
    status = [
      mongo.id: .connected,
      redis.id: .connected,
      rabbit.id: .disconnected,
      preview.id: .connected,
      postgres.id: .reconnecting(at: Date().addingTimeInterval(40), attempt: 2),
      socks.id: .failed("Local port 1080 is already in use by Secure Pipes (pid 1914)."),
      expose.id: .disconnected,
    ]
    lastError = [
      socks.id: "Local port 1080 is already in use by Secure Pipes (pid 1914).",
      postgres.id: "Connection timed out.",
    ]
    lastOutput = [postgres.id: "ssh: connect to host staging.example.com port 2222: Operation timed out\n"]
  }

  // MARK: Secrets

  func secret(_ kind: SecretKind, for ownerID: UUID) -> String {
    Keychain.read(kind, ownerID: ownerID) ?? ""
  }

  func setSecret(_ value: String, _ kind: SecretKind, for ownerID: UUID) throws {
    try Keychain.write(value, kind, ownerID: ownerID)
  }

  // MARK: Import

  func previewSecurePipesImport() throws -> ImportPreview {
    let imported = try SecurePipesImporter.load()
    let known = Set(tunnels.map(\.id))
    return ImportPreview(new: imported.filter { !known.contains($0.id) }, existing: imported.filter { known.contains($0.id) })
  }

  /// Adds connections that are not here yet. Existing ones (same Secure Pipes ID) are left untouched unless
  /// `overwriteExisting` is set, and even then their group and profile link survive. Nothing is ever removed.
  @discardableResult
  func importFromSecurePipes(overwriteExisting: Bool = false) throws -> ImportSummary {
    let imported = try SecurePipesImporter.load()
    var summary = ImportSummary()
    for tunnel in imported {
      guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else {
        tunnels.append(tunnel)
        summary.added += 1
        continue
      }
      guard overwriteExisting else {
        summary.skipped += 1
        continue
      }
      var updated = tunnel
      updated.group = tunnels[index].group
      updated.profileID = tunnels[index].profileID
      tunnels[index] = updated
      summary.updated += 1
    }
    saveNow()
    return summary
  }

  // MARK: Connections

  func status(of id: UUID) -> TunnelStatus {
    status[id] ?? .disconnected
  }

  func connectAutoTunnels() {
    for tunnel in tunnels where tunnel.autoConnect {
      connect(tunnel.id)
    }
  }

  func connect(_ id: UUID) {
    guard tunnel(id) != nil else { return }
    wantsRunning.insert(id)
    cancelReconnect(id)
    attempts[id] = 0
    if processes[id]?.isRunning == true || launching.contains(id) { return }
    launch(id)
  }

  func disconnect(_ id: UUID) {
    wantsRunning.remove(id)
    suspendedForSleep.remove(id)
    cancelReconnect(id)
    terminateProcess(for: id)
    status[id] = .disconnected
    if tunnel(id)?.cloudflare.isQuick == true { publicURL[id] = nil }
  }

  /// Applies new settings to a live tunnel by tearing the session down and starting it again.
  func restart(_ id: UUID) {
    guard status(of: id).isActive else { return }
    disconnect(id)
    connect(id)
  }

  func restartTunnels(using profileID: UUID) {
    for tunnel in tunnels(using: profileID) {
      restart(tunnel.id)
    }
  }

  func toggle(_ id: UUID) {
    if status(of: id).isActive {
      disconnect(id)
    } else {
      connect(id)
    }
  }

  func connectAll(inGroup group: String) {
    for tunnel in tunnels(inGroup: group) { connect(tunnel.id) }
  }

  func disconnectAll(inGroup group: String) {
    for tunnel in tunnels(inGroup: group) { disconnect(tunnel.id) }
  }

  func disconnectAll() {
    for tunnel in tunnels {
      disconnect(tunnel.id)
    }
  }

  private func cancelReconnect(_ id: UUID) {
    reconnectTasks[id]?.cancel()
    reconnectTasks[id] = nil
  }

  /// Runs the local port check off the main thread, then starts ssh unless something already listens there.
  private func launch(_ id: UUID) {
    guard let tunnel = tunnel(id) else { return }
    guard networkAvailable else {
      status[id] = .waitingForNetwork
      return
    }
    lastError[id] = nil
    status[id] = .connecting
    launching.insert(id)
    if tunnel.type == .cloudflare {
      launchCloudflare(id)
      return
    }

    let listensLocally = tunnel.listensLocally
    let port = tunnel.bindPort
    let identity = resolved(tunnel).expandedIdentityFile
    Task { @MainActor in
      let usage = listensLocally ? await Task.detached { PortProbe.listener(on: port) }.value : nil
      launching.remove(id)
      guard wantsRunning.contains(id), processes[id] == nil else { return }
      if let usage {
        let message = "Local \(usage.description)."
        lastOutput[id] = message + "\n"
        scheduleRetryOrFail(id, message: message)
        return
      }
      if let problem = Self.identityProblem(path: identity) ?? Self.helperProblem() {
        lastOutput[id] = problem + "\n"
        scheduleRetryOrFail(id, message: problem)
        return
      }
      startProcess(for: id)
    }
  }

  /// Checks the key file the way ssh will: it must exist, be readable by this app (which also triggers the
  /// macOS folder-access prompt for Desktop, Documents, Downloads and cloud drives) and not be world readable.
  static func identityProblem(path: String) -> String? {
    guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    guard FileManager.default.fileExists(atPath: path) else {
      return "The identity file does not exist: \(path)"
    }
    guard let handle = FileHandle(forReadingAtPath: path) else {
      return "The identity file could not be read. Allow SecureTunnels to access its folder in System Settings > Privacy & Security > Files and Folders, or move the key to ~/.ssh."
    }
    try? handle.close()
    if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let permissions = attributes[.posixPermissions] as? Int, permissions & 0o077 != 0 {
      return "ssh refuses the identity file because its permissions are too open. Run: chmod 600 \"\(path)\""
    }
    return nil
  }

  /// ssh runs the askpass helper directly, so a quarantine flag left on it (zip download opened with right-click
  /// instead of xattr) makes Gatekeeper kill it. Clear the flag on our own helper when possible.
  static func helperProblem() -> String? {
    let path = askPassURL.path
    guard FileManager.default.isExecutableFile(atPath: path) else {
      return "The passphrase helper is missing from the app bundle: \(path)"
    }
    let attribute = "com.apple.quarantine"
    guard getxattr(path, attribute, nil, 0, 0, 0) >= 0 else { return nil }
    if removexattr(path, attribute, 0) == 0 { return nil }
    return "The passphrase helper is quarantined. Run: xattr -dr com.apple.quarantine \"\(Bundle.main.bundlePath)\""
  }

  // MARK: Cloudflare tunnels

  /// Provisions the hostname in the account when needed, then runs cloudflared with the tunnel token in its
  /// environment. Quick tunnels skip the account entirely.
  private func launchCloudflare(_ id: UUID) {
    guard let tunnel = tunnel(id) else { return }
    guard let binary = Cloudflared.locate() else {
      launching.remove(id)
      scheduleRetryOrFail(id, message: CloudflaredError.notInstalled.localizedDescription)
      return
    }
    if tunnel.cloudflare.isQuick {
      launching.remove(id)
      publicURL[id] = nil
      run(id: id, executable: binary, arguments: Cloudflared.quickTunnelArguments(serviceURL: tunnel.cloudflareServiceURL), environment: [:], stdin: nil)
      return
    }
    let settings = CloudflareSettings.shared
    guard let api = settings.api, !settings.accountID.isEmpty else {
      launching.remove(id)
      scheduleRetryOrFail(id, message: "Add a Cloudflare API token and pick an account in Settings > Cloudflare first.")
      return
    }
    let hostname = tunnel.cloudflare.hostname.trimmingCharacters(in: .whitespaces).lowercased()
    let serviceURL = tunnel.cloudflareServiceURL
    let existing = tunnel.cloudflare
    let accountID = settings.accountID
    if existing.adopted, let remoteID = existing.tunnelID {
      Task { @MainActor in
        do {
          let token = try await api.tunnelToken(accountID: accountID, tunnelID: remoteID)
          launching.remove(id)
          guard wantsRunning.contains(id), processes[id] == nil else { return }
          publicURL[id] = hostname.isEmpty ? nil : "https://\(hostname)"
          run(id: id, executable: binary, arguments: Cloudflared.namedTunnelArguments(), environment: ["TUNNEL_TOKEN": token], stdin: nil)
        } catch {
          launching.remove(id)
          lastOutput[id] = error.localizedDescription + "\n"
          scheduleRetryOrFail(id, message: "Cloudflare rejected the request: \(error.localizedDescription)")
        }
      }
      return
    }
    let tunnelName = "securetunnels-" + tunnel.name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      + "-" + String(tunnel.id.uuidString.prefix(8)).lowercased()
    Task { @MainActor in
      do {
        let provisioned = try await api.provision(accountID: accountID, hostname: hostname, serviceURL: serviceURL, tunnelName: tunnelName, existing: existing)
        launching.remove(id)
        guard wantsRunning.contains(id), processes[id] == nil, var current = self.tunnel(id) else { return }
        current.cloudflare.tunnelID = provisioned.tunnelID
        current.cloudflare.zoneID = provisioned.zoneID
        current.cloudflare.dnsRecordID = provisioned.dnsRecordID
        update(current)
        publicURL[id] = "https://\(hostname)"
        run(id: id, executable: binary, arguments: Cloudflared.namedTunnelArguments(), environment: ["TUNNEL_TOKEN": provisioned.token], stdin: nil)
      } catch {
        launching.remove(id)
        lastOutput[id] = error.localizedDescription + "\n"
        scheduleRetryOrFail(id, message: "Cloudflare setup failed: \(error.localizedDescription)")
      }
    }
  }

  /// Creates a local tunnel entry for a tunnel that already exists in the account. Its ingress and DNS are
  /// left to the dashboard; the app fetches the token and runs it.
  @discardableResult
  func adoptCloudflareTunnel(_ info: RemoteTunnelInfo) -> Tunnel? {
    guard let first = info.ingress.first else { return nil }
    let service = URL(string: first.service)
    let scheme = service?.scheme ?? "http"
    var tunnel = Tunnel(
      name: info.tunnel.name.replacingOccurrences(of: "securetunnels-", with: ""),
      type: .cloudflare,
      bindAddress: service?.host ?? "localhost",
      bindPort: service?.port ?? (scheme == "https" ? 443 : 80),
      targetHost: "",
      targetPort: 0,
      autoReconnect: true,
      cloudflare: CloudflareConfig(hostname: first.hostname ?? "", scheme: scheme, tunnelID: info.tunnel.id, adopted: true)
    )
    tunnel.name = tunnel.name.isEmpty ? (first.hostname ?? "Cloudflare tunnel") : tunnel.name
    return add(tunnel)
  }

  func localTunnel(forRemoteID remoteID: String) -> Tunnel? {
    tunnels.first { $0.type == .cloudflare && $0.cloudflare.tunnelID == remoteID }
  }

  /// After a remote tunnel is deleted in the dashboard section, unlink local entries so they re-create on connect.
  func unlinkCloudflareTunnel(remoteID: String) {
    for index in tunnels.indices where tunnels[index].cloudflare.tunnelID == remoteID {
      disconnect(tunnels[index].id)
      tunnels[index].cloudflare.tunnelID = nil
      tunnels[index].cloudflare.dnsRecordID = nil
      tunnels[index].cloudflare.zoneID = nil
      tunnels[index].cloudflare.adopted = false
    }
    scheduleSave()
  }

  /// Best effort removal of the DNS record and the tunnel when the user deletes an exposed tunnel. Adopted
  /// tunnels are left in the account because the app did not create them.
  private func deprovisionCloudflare(_ tunnel: Tunnel) {
    let config = tunnel.cloudflare
    guard !config.adopted, let tunnelID = config.tunnelID, let api = CloudflareSettings.shared.api else { return }
    let accountID = CloudflareSettings.shared.accountID
    Task.detached {
      if let zoneID = config.zoneID, let recordID = config.dnsRecordID {
        try? await api.deleteDNS(zoneID: zoneID, recordID: recordID)
      }
      try? await api.deleteTunnel(accountID: accountID, tunnelID: tunnelID)
    }
  }

  private func startProcess(for id: UUID) {
    guard let stored = tunnel(id) else { return }
    let tunnel = resolved(stored)
    let owner = secretOwner(for: stored)
    stderrBuffers[id] = ""
    stdoutBuffers[id] = ""

    let payload = AskPassPayload(
      passphrase: Keychain.read(.passphrase, ownerID: owner),
      password: Keychain.read(.password, ownerID: owner)
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: SSHCommand.executable)
    process.arguments = SSHCommand.arguments(
      for: tunnel,
      knownHostsFile: AppPaths.knownHostsFile.path,
      hasPassword: !(payload.password ?? "").isEmpty
    )
    var extra: [String: String] = ["SSH_ASKPASS": Self.askPassURL.path, "SSH_ASKPASS_REQUIRE": "force"]
    if ProcessInfo.processInfo.environment["DISPLAY"] == nil {
      extra["DISPLAY"] = "SecureTunnels:0"
    }
    // Hand the secrets to the askpass helper through ssh's inherited stdin.
    run(id: id, executable: process.executableURL!, arguments: process.arguments ?? [], environment: extra, stdin: try? JSONEncoder().encode(payload))
  }

  /// Starts a tunnel process (ssh or cloudflared), wires its output to the log and the status, and remembers it.
  private func run(id: UUID, executable: URL, arguments: [String], environment extra: [String: String], stdin payload: Data?) {
    guard let tunnel = tunnel(id) else { return }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in extra { environment[key] = value }
    process.environment = environment

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    stderrBuffers[id] = ""
    stdoutBuffers[id] = ""

    let log = openLog(for: id, tunnel: tunnel, arguments: [executable.lastPathComponent] + arguments)

    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      Task { @MainActor in self.handleOutput(id, data: data, isError: false, log: log) }
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      Task { @MainActor in self.handleOutput(id, data: data, isError: true, log: log) }
    }
    process.terminationHandler = { finished in
      Task { @MainActor in self.handleExit(id, process: finished, log: log) }
    }

    do {
      try process.run()
    } catch {
      scheduleRetryOrFail(id, message: error.localizedDescription)
      return
    }
    processes[id] = process
    SessionRegistry.register(pid: process.processIdentifier, tunnelID: id)

    if let payload {
      stdin.fileHandleForWriting.write(payload)
    }
    try? stdin.fileHandleForWriting.close()
  }

  private func handleOutput(_ id: UUID, data: Data, isError: Bool, log: FileHandle?) {
    guard let text = String(data: data, encoding: .utf8) else { return }
    log?.write(Data(text.utf8))
    if isError {
      stderrBuffers[id, default: ""] += text
      if let tunnel = tunnel(id), tunnel.type == .cloudflare {
        let buffer = stderrBuffers[id, default: ""]
        if publicURL[id] == nil, let url = Cloudflared.quickTunnelURL(in: buffer) {
          publicURL[id] = url
        }
        if status[id] == .connecting, Cloudflared.isConnected(buffer) {
          status[id] = .connected
          attempts[id] = 0
        }
      }
      return
    }
    // The marker can arrive split across reads, so match on the accumulated text.
    stdoutBuffers[id] = String((stdoutBuffers[id, default: ""] + text).suffix(512))
    if stdoutBuffers[id, default: ""].contains(SSHCommand.connectedMarker), status[id] == .connecting {
      status[id] = .connected
      attempts[id] = 0
    }
  }

  private func handleExit(_ id: UUID, process: Process, log: FileHandle?) {
    SessionRegistry.unregister(pid: process.processIdentifier)
    guard processes[id] === process else { return }
    processes[id] = nil
    let stderr = stderrBuffers[id] ?? ""
    let isCloudflare = tunnel(id)?.type == .cloudflare
    let message = isCloudflare
      ? Cloudflared.friendlyError(from: stderr, exitStatus: process.terminationStatus)
      : SSHCommand.friendlyError(from: stderr, exitStatus: process.terminationStatus)
    lastOutput[id] = String(stderr.suffix(4000))
    if isCloudflare, tunnel(id)?.cloudflare.isQuick == true { publicURL[id] = nil }
    log?.write(Data("[SecureTunnels] \(isCloudflare ? "cloudflared" : "ssh") exited with status \(process.terminationStatus)\n".utf8))
    try? log?.close()

    guard wantsRunning.contains(id), !suspendedForSleep.contains(id) else {
      status[id] = .disconnected
      return
    }
    scheduleRetryOrFail(id, message: message)
  }

  /// Retries forever with exponential backoff (interval, 2x, 4x ... capped at five minutes) while the tunnel is
  /// wanted and allowed to reconnect. Otherwise it stays failed until the user connects again.
  private func scheduleRetryOrFail(_ id: UUID, message: String) {
    lastError[id] = message
    guard let tunnel = tunnel(id), tunnel.autoReconnect, wantsRunning.contains(id) else {
      wantsRunning.remove(id)
      status[id] = .failed(message)
      return
    }
    let attempt = (attempts[id] ?? 0) + 1
    attempts[id] = attempt
    let base = max(5, tunnel.reconnectInterval)
    let delay = min(Self.maxReconnectDelay, base << min(attempt - 1, 10))
    status[id] = .reconnecting(at: Date().addingTimeInterval(TimeInterval(delay)), attempt: attempt)
    reconnectTasks[id] = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, self.wantsRunning.contains(id) else { return }
      self.launch(id)
    }
  }

  private func terminateProcess(for id: UUID) {
    guard let process = processes[id] else { return }
    processes[id] = nil
    guard process.isRunning else { return }
    process.terminate()
    Task.detached {
      try? await Task.sleep(for: .seconds(3))
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
  }

  private func openLog(for id: UUID, tunnel: Tunnel, arguments: [String]) -> FileHandle? {
    let url = AppPaths.logFile(for: id)
    let header = "[SecureTunnels] \(Date()) connecting \(tunnel.name)\n[SecureTunnels] ssh \(arguments.joined(separator: " "))\n"
    guard (try? Data(header.utf8).write(to: url)) != nil else { return nil }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    return handle
  }

  static var askPassURL: URL {
    Bundle.main.executableURL!
      .deletingLastPathComponent()
      .appendingPathComponent("SecureTunnelsAskPass")
  }
}
