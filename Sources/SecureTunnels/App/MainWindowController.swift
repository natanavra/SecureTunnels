import AppKit
import SwiftUI
import SecureTunnelsCore

enum WindowID {
  static let main = "main"
}

/// Owns the single main window. Its SwiftUI content is built when the window opens and released when it closes.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
  static let shared = MainWindowController()

  private(set) var window: NSWindow?

  var isVisible: Bool {
    guard let window else { return false }
    return window.isVisible && !window.isMiniaturized
  }

  func show(mode: SidebarMode? = nil) {
    if let mode {
      TunnelManager.shared.pendingMode = mode
    }
    let window = self.window ?? makeWindow()
    if window.contentViewController == nil {
      window.contentViewController = makeContent()
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.identifier = NSUserInterfaceItemIdentifier(WindowID.main)
    window.title = "SecureTunnels"
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 880, height: 600)
    window.delegate = self
    window.contentViewController = makeContent()
    if !window.setFrameUsingName("SecureTunnelsMain") {
      window.setContentSize(NSSize(width: 940, height: 640))
      window.center()
    }
    window.setFrameAutosaveName("SecureTunnelsMain")
    self.window = window
    return window
  }

  private func makeContent() -> NSViewController {
    let root = TunnelsWindow()
      .environment(TunnelManager.shared)
      .environment(AppSettings.shared)
    let host = NSHostingController(rootView: root)
    host.sceneBridgingOptions = [.toolbars, .title]
    return host
  }

  func windowWillClose(_ notification: Notification) {
    TunnelManager.shared.clearEditorSession()
    // Release the SwiftUI content so its controls stop rendering while the window is closed.
    window?.contentViewController = nil
    Task { @MainActor in AppDelegate.updateActivationPolicy() }
  }
}
