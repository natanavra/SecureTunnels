import AppKit
import SecureTunnelsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowObservers: [NSObjectProtocol] = []
  private var signalSources: [DispatchSourceSignal] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    if SnapshotRunner.runIfRequested() { return }
    if Installer.offerInstallIfNeeded() { return }
    NSApp.mainMenu = MainMenu.build(target: self)
    TunnelManager.shared.start()
    StatusItemController.shared.install()
    observeWindows()
    observeSignals()
  }

  @objc func showSettings(_ sender: Any?) {
    MainWindowController.shared.show(mode: .settings)
  }

  /// Clicking the app in Finder or Spotlight while it runs opens the main window.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    MainWindowController.shared.show()
    return false
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

  /// Only the main window counts; the popover and alerts do not give the app a Dock icon.
  static var hasVisibleAppWindow: Bool {
    MainWindowController.shared.isVisible
  }
}
