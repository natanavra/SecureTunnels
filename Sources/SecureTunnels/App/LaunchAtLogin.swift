import Foundation
import ServiceManagement

/// Login item registration through SMAppService. Also exposed as `SecureTunnels --launch-at-login on|off|status`
/// so it can be scripted and verified without the UI.
enum LaunchAtLogin {
  static var status: SMAppService.Status { SMAppService.mainApp.status }
  static var isEnabled: Bool { status == .enabled }

  static func set(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  static func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: return "enabled"
    case .requiresApproval: return "requires approval in System Settings > General > Login Items"
    case .notRegistered: return "not registered"
    case .notFound: return "not found"
    @unknown default: return "unknown"
    }
  }

  /// Handles the command line form and exits. Returns when the arguments do not ask for it.
  static func runCommandIfRequested() {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--launch-at-login") else { return }
    let mode = index + 1 < arguments.count ? arguments[index + 1] : "status"
    do {
      switch mode {
      case "on": try set(true)
      case "off": try set(false)
      case "status": break
      default:
        FileHandle.standardError.write(Data("usage: SecureTunnels --launch-at-login on|off|status\n".utf8))
        exit(2)
      }
      print("launch at login: \(describe(status))")
      exit(isEnabled || mode == "off" ? 0 : 1)
    } catch {
      FileHandle.standardError.write(Data("launch at login failed: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
