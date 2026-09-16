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
      Image(nsImage: manager.connectedCount > 0 ? MenuBarIcon.connected : MenuBarIcon.idle)
    }
    .menuBarExtraStyle(.window)

    Window("SecureTunnels", id: WindowID.main) {
      TunnelsWindow()
        .environment(manager)
        .environment(settings)
    }
    .defaultSize(width: 940, height: 640)
  }
}

enum WindowID {
  static let main = "main"
}
