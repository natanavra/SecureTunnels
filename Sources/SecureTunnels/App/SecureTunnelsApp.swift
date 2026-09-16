import SwiftUI
import SecureTunnelsCore

struct SecureTunnelsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  private var manager: TunnelManager { TunnelManager.shared }
  private var settings: AppSettings { AppSettings.shared }

  var body: some Scene {
    MenuBarExtra {
      MenuBarView()
        .environment(manager)
        .environment(settings)
    } label: {
      Image(systemName: manager.connectedCount > 0 ? "lock.shield.fill" : "lock.shield")
    }
    .menuBarExtraStyle(.window)

    Window("Tunnels", id: WindowID.tunnels) {
      TunnelsWindow()
        .environment(manager)
        .environment(settings)
    }
    .defaultSize(width: 860, height: 600)

    Window("SecureTunnels Settings", id: WindowID.settings) {
      SettingsView()
        .environment(manager)
        .environment(settings)
    }
    .windowResizability(.contentSize)
  }
}

enum WindowID {
  static let tunnels = "tunnels"
  static let settings = "settings"
}
