import AppKit
import Foundation
import Network
import Observation
import SecureTunnelsCore

enum TunnelStatus: Equatable {
  case disconnected
  case connecting
  case connected
  case reconnecting(at: Date)
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
    case .reconnecting(let date):
      let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
      return "Reconnecting in \(seconds)s"
    case .waitingForNetwork: return "Waiting for network"
    case .failed: return "Failed"
    }
  }
}

struct ImportSummary {
  var added = 0
  var updated = 0
}

@MainActor
@Observable
final class TunnelManager {
  static let shared = TunnelManager()

  private(set) var tunnels: [Tunnel] = []
  private(set) var status: [UUID: TunnelStatus] = [:]
  private(set) var lastError: [UUID: String] = [:]
  private(set) var loadError: String?
  private(set) var networkAvailable = true

  @ObservationIgnored private var processes: [UUID: Process] = [:]
  @ObservationIgnored private var stderrBuffers: [UUID: String] = [:]
  @ObservationIgnored private var wantsRunning: Set<UUID> = []
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

  private init() {
    do {
      tunnels = try TunnelStorage.load()
    } catch {
      loadError = "Could not read tunnels.json: \(error.localizedDescription)"
    }
  }

  // MARK: Lifecycle

  func start() {
    try? AppPaths.ensureDirectories()
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

  /// ssh sessions rarely survive sleep. Kill them cleanly and remember which ones to bring back.
  private func suspendForSleep() {
    guard AppSettings.shared.reconnectAfterWake else { return }
    suspendedForSleep = wantsRunning
    for id in wantsRunning {
      reconnectTasks[id]?.cancel()
      reconnectTasks[id] = nil
      terminateProcess(for: id)
      status[id] = .reconnecting(at: Date().addingTimeInterval(3))
    }
  }

  private func observeNetwork() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { path in
      let satisfied = path.status == .satisfied
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
      for id in ids where processes[id] == nil {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        launch(id)
      }
      return
    }
    for id in ids {
      reconnectTasks[id]?.cancel()
      reconnectTasks[id] = nil
      terminateProcess(for: id)
      status[id] = .waitingForNetwork
    }
  }

  private func resumeAfterWake() async {
    guard !suspendedForSleep.isEmpty else { return }
    let ids = suspendedForSleep
    suspendedForSleep.removeAll()
    try? await Task.sleep(for: .seconds(3))
    for id in ids where wantsRunning.contains(id) {
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
    for kind in SecretKind.allCases {
      if let secret = Keychain.read(kind, tunnelID: id) {
        try? Keychain.write(secret, kind, tunnelID: copy.id)
      }
    }
    return add(copy)
  }

  func remove(_ id: UUID) {
    disconnect(id)
    tunnels.removeAll { $0.id == id }
    status[id] = nil
    lastError[id] = nil
    Keychain.deleteAll(tunnelID: id)
    try? FileManager.default.removeItem(at: AppPaths.logFile(for: id))
    scheduleSave()
  }

  func move(from source: IndexSet, to destination: Int) {
    tunnels.move(fromOffsets: source, toOffset: destination)
    scheduleSave()
  }

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
      try TunnelStorage.save(tunnels)
      loadError = nil
    } catch {
      loadError = "Could not save tunnels.json: \(error.localizedDescription)"
    }
  }

  // MARK: Demo data

  /// Replaces the in-memory state with sample tunnels for screenshots. Nothing is written to disk afterwards.
  func loadDemoData() {
    persistenceDisabled = true
    let mongo = Tunnel(name: "Production Mongo", host: "db-bastion.example.com", username: "ec2-user",
      identityFile: "~/.ssh/prod-bastion.pem", bindAddress: "localhost", bindPort: 27018, targetHost: "localhost",
      targetPort: 27017, autoConnect: true)
    let redis = Tunnel(name: "Staging Redis", host: "staging.example.com", username: "ubuntu",
      identityFile: "~/.ssh/staging.pem", bindPort: 6380, targetHost: "10.0.4.12", targetPort: 6379, autoConnect: true)
    let postgres = Tunnel(name: "Analytics Postgres", host: "analytics.example.com", port: 2222, username: "deploy",
      bindPort: 5433, targetHost: "localhost", targetPort: 5432)
    let socks = Tunnel(name: "Office SOCKS Proxy", type: .dynamic, host: "gw.example.com", username: "natan",
      bindPort: 1080, targetHost: "", targetPort: 0)
    let expose = Tunnel(name: "Expose Dev Server", type: .remote, host: "demo.example.com", username: "deploy",
      bindAddress: "0.0.0.0", bindPort: 9000, targetHost: "localhost", targetPort: 3000)
    tunnels = [mongo, redis, postgres, socks, expose]
    status = [
      mongo.id: .connected,
      redis.id: .connected,
      postgres.id: .disconnected,
      socks.id: .failed("Local port 1080 is already in use."),
      expose.id: .disconnected,
    ]
    lastError = [socks.id: "Local port 1080 is already in use."]
  }

  // MARK: Secrets

  func secret(_ kind: SecretKind, for id: UUID) -> String {
    Keychain.read(kind, tunnelID: id) ?? ""
  }

  func setSecret(_ value: String, _ kind: SecretKind, for id: UUID) throws {
    try Keychain.write(value, kind, tunnelID: id)
  }

  // MARK: Import

  @discardableResult
  func importFromSecurePipes() throws -> ImportSummary {
    let imported = try SecurePipesImporter.load()
    var summary = ImportSummary()
    for tunnel in imported {
      if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
        tunnels[index] = tunnel
        summary.updated += 1
      } else {
        tunnels.append(tunnel)
        summary.added += 1
      }
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
    reconnectTasks[id]?.cancel()
    reconnectTasks[id] = nil
    if processes[id]?.isRunning == true { return }
    launch(id)
  }

  func disconnect(_ id: UUID) {
    wantsRunning.remove(id)
    suspendedForSleep.remove(id)
    reconnectTasks[id]?.cancel()
    reconnectTasks[id] = nil
    terminateProcess(for: id)
    status[id] = .disconnected
  }

  func toggle(_ id: UUID) {
    if status(of: id).isActive {
      disconnect(id)
    } else {
      connect(id)
    }
  }

  func disconnectAll() {
    for tunnel in tunnels {
      disconnect(tunnel.id)
    }
  }

  private func launch(_ id: UUID) {
    guard let tunnel = tunnel(id) else { return }
    guard networkAvailable else {
      status[id] = .waitingForNetwork
      return
    }
    lastError[id] = nil
    status[id] = .connecting
    stderrBuffers[id] = ""

    let payload = AskPassPayload(
      passphrase: Keychain.read(.passphrase, tunnelID: id),
      password: Keychain.read(.password, tunnelID: id)
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: SSHCommand.executable)
    process.arguments = SSHCommand.arguments(
      for: tunnel,
      knownHostsFile: AppPaths.knownHostsFile.path,
      hasPassword: !(payload.password ?? "").isEmpty
    )

    var environment = ProcessInfo.processInfo.environment
    environment["SSH_ASKPASS"] = Self.askPassURL.path
    environment["SSH_ASKPASS_REQUIRE"] = "force"
    if environment["DISPLAY"] == nil {
      environment["DISPLAY"] = "SecureTunnels:0"
    }
    process.environment = environment

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let log = openLog(for: id, tunnel: tunnel, arguments: process.arguments ?? [])

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
      status[id] = .failed(error.localizedDescription)
      lastError[id] = error.localizedDescription
      return
    }
    processes[id] = process

    // Hand the secrets to the askpass helper through ssh's inherited stdin, then close so the helper sees EOF.
    if let data = try? JSONEncoder().encode(payload) {
      stdin.fileHandleForWriting.write(data)
    }
    try? stdin.fileHandleForWriting.close()
  }

  private func handleOutput(_ id: UUID, data: Data, isError: Bool, log: FileHandle?) {
    guard let text = String(data: data, encoding: .utf8) else { return }
    log?.write(Data(text.utf8))
    if isError {
      stderrBuffers[id, default: ""] += text
    } else if text.contains(SSHCommand.connectedMarker), status[id] == .connecting {
      status[id] = .connected
    }
  }

  private func handleExit(_ id: UUID, process: Process, log: FileHandle?) {
    guard processes[id] === process else { return }
    processes[id] = nil
    let stderr = stderrBuffers[id] ?? ""
    let message = SSHCommand.friendlyError(from: stderr, exitStatus: process.terminationStatus)
    log?.write(Data("[SecureTunnels] ssh exited with status \(process.terminationStatus)\n".utf8))
    try? log?.close()

    guard wantsRunning.contains(id), !suspendedForSleep.contains(id) else {
      status[id] = .disconnected
      return
    }

    lastError[id] = message
    guard let tunnel = tunnel(id), tunnel.autoReconnect else {
      wantsRunning.remove(id)
      status[id] = .failed(message)
      return
    }

    let delay = max(5, tunnel.reconnectInterval)
    status[id] = .reconnecting(at: Date().addingTimeInterval(TimeInterval(delay)))
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
