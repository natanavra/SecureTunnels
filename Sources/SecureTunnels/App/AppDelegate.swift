import AppKit
import SecureTunnelsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowObservers: [NSObjectProtocol] = []
  private var signalSources: [DispatchSourceSignal] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    if SnapshotRunner.runIfRequested() { return }
    TunnelManager.shared.start()
    observeWindows()
    observeSignals()
  }

  /// `pkill` and `kill` send SIGTERM, which would skip applicationWillTerminate and leave ssh running.
  private func observeSignals() {
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler {
        NSApp.terminate(nil)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    TunnelManager.shared.shutdown()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// The app lives in the menu bar. It only becomes a regular app, with a Dock icon and a main menu (needed for
  /// copy and paste in text fields), while its window is open, and drops back to accessory when it closes.
  private func observeWindows() {
    let center = NotificationCenter.default
    for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
      NSWindow.didBecomeKeyNotification, NSApplication.didResignActiveNotification] {
      windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250))
          AppDelegate.updateActivationPolicy()
        }
      })
    }
  }

  static func updateActivationPolicy() {
    let wanted: NSApplication.ActivationPolicy = hasVisibleAppWindow ? .regular : .accessory
    if NSApp.activationPolicy() != wanted {
      NSApp.setActivationPolicy(wanted)
    }
  }

  /// Our own document-style windows only: the menu bar popover is a panel at a higher level and does not count.
  static var hasVisibleAppWindow: Bool {
    NSApp.windows.contains { window in
      guard window.isVisible, !window.isMiniaturized, !(window is NSPanel) else { return false }
      if let identifier = window.identifier?.rawValue, identifier.contains(WindowID.main) { return true }
      return window.styleMask.contains(.titled) && window.level == .normal
    }
  }

  static func bringToFront() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
