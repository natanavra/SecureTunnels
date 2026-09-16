import AppKit
import SecureTunnelsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowObservers: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    if SnapshotRunner.runIfRequested() { return }
    TunnelManager.shared.start()
    observeWindows()
  }

  func applicationWillTerminate(_ notification: Notification) {
    TunnelManager.shared.shutdown()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// An accessory app has no main menu, which breaks copy and paste in text fields. Switch to a regular app while
  /// one of our windows is open and drop back to accessory once they are all closed.
  private func observeWindows() {
    let center = NotificationCenter.default
    windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(200))
        if !AppDelegate.hasVisibleAppWindow {
          NSApp.setActivationPolicy(.accessory)
        }
      }
    })
  }

  static var hasVisibleAppWindow: Bool {
    NSApp.windows.contains { window in
      guard window.isVisible, let identifier = window.identifier?.rawValue else { return false }
      return identifier.contains(WindowID.tunnels) || identifier.contains(WindowID.settings)
    }
  }

  static func bringToFront() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
