import AppKit

// AppKit lifecycle: the status item, popover and main window are created by the delegate, not by SwiftUI scenes.
LaunchAtLogin.runCommandIfRequested()

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}
