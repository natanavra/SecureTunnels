import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
  static let shared = AppSettings()

  private let defaults = UserDefaults.standard

  var reconnectAfterWake: Bool {
    didSet { defaults.set(reconnectAfterWake, forKey: "reconnectAfterWake") }
  }

  var didImportSecurePipes: Bool {
    didSet { defaults.set(didImportSecurePipes, forKey: "didImportSecurePipes") }
  }

  private(set) var launchAtLoginError: String?

  var launchAtLogin: Bool {
    get {
      access(keyPath: \.launchAtLogin)
      return LaunchAtLogin.isEnabled
    }
    set {
      withMutation(keyPath: \.launchAtLogin) {
        do {
          try LaunchAtLogin.set(newValue)
          launchAtLoginError = nil
        } catch {
          launchAtLoginError = error.localizedDescription
        }
      }
    }
  }

  var launchAtLoginNeedsApproval: Bool {
    LaunchAtLogin.status == .requiresApproval
  }

  private init() {
    defaults.register(defaults: ["reconnectAfterWake": true])
    reconnectAfterWake = defaults.bool(forKey: "reconnectAfterWake")
    didImportSecurePipes = defaults.bool(forKey: "didImportSecurePipes")
  }
}
