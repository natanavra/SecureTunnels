import AppKit
import Observation
import SwiftUI
import SecureTunnelsCore

/// The menu bar icon and its popover, driven by AppKit instead of SwiftUI's MenuBarExtra.
///
/// MenuBarExtra sizes its window from the content's ideal size (a ScrollView reports almost none, which left the
/// list empty), animates every resize, and keeps the SwiftUI tree rendering while closed. Here the popover content
/// exists only while the popover is open, resizes without animation, and the icon is a plain image.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
  static let shared = StatusItemController()

  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var lastConnected: Bool?

  func install() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.target = self
    item.button?.action = #selector(togglePopover(_:))
    item.button?.toolTip = "SecureTunnels"
    item.button?.setAccessibilityLabel("SecureTunnels")
    statusItem = item

    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self

    trackIcon()
  }

  /// Re-reads the connected count whenever it changes and swaps the icon only when it actually flips.
  private func trackIcon() {
    let connected = withObservationTracking {
      TunnelManager.shared.connectedCount > 0
    } onChange: {
      Task { @MainActor in StatusItemController.shared.trackIcon() }
    }
    guard connected != lastConnected else { return }
    lastConnected = connected
    statusItem?.button?.image = connected ? MenuBarIcon.connected : MenuBarIcon.idle
  }

  @objc private func togglePopover(_ sender: Any?) {
    if popover.isShown {
      popover.performClose(sender)
    } else {
      showPopover()
    }
  }

  private func showPopover() {
    guard let button = statusItem?.button else { return }
    let root = MenuBarView(openMain: { [weak self] mode in
      self?.popover.performClose(nil)
      MainWindowController.shared.show(mode: mode)
    })
    .environment(TunnelManager.shared)
    .environment(AppSettings.shared)
    let host = NSHostingController(rootView: root)
    host.sizingOptions = [.preferredContentSize]
    popover.contentViewController = host
    NSApp.activate(ignoringOtherApps: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  /// Developer self-test: installs the real status item, opens the real popover, and prints what AppKit reports.
  func selfTest() async {
    install()
    try? await Task.sleep(for: .milliseconds(500))
    let button = statusItem?.button
    print("status item visible=\(statusItem?.isVisible ?? false) image=\(button?.image != nil) buttonWindow=\(button?.window != nil) frame=\(button?.window?.frame ?? .zero) tunnels=\(TunnelManager.shared.tunnels.count)")
    showPopover()
    try? await Task.sleep(for: .seconds(1))
    let size = popover.contentViewController?.view.frame.size ?? .zero
    print("popover shown=\(popover.isShown) content=\(Int(size.width))x\(Int(size.height)) preferred=\(Int(popover.contentViewController?.preferredContentSize.height ?? 0))")
    closePopover()
    try? await Task.sleep(for: .milliseconds(300))
    print("popover closed=\(!popover.isShown) contentReleased=\(popover.contentViewController == nil)")
  }

  /// Developer stress test: opens and closes the popover repeatedly while every tunnel changes status.
  func stressTest(cycles: Int) async {
    install()
    try? await Task.sleep(for: .seconds(1))
    let manager = TunnelManager.shared
    var shownCount = 0
    for cycle in 0..<cycles {
      showPopover()
      if popover.isShown { shownCount += 1 }
      for step in 0..<10 {
        manager.cycleDemoStatuses(step: cycle * 10 + step)
        try? await Task.sleep(for: .milliseconds(15))
      }
      closePopover()
      manager.cycleDemoStatuses(step: cycle)
      try? await Task.sleep(for: .milliseconds(15))
    }
    print("stress: cycles=\(cycles) shown=\(shownCount) statusChanges=\(cycles * 11) finished without crashing")
  }

  func closePopover() {
    if popover.isShown { popover.performClose(nil) }
  }

  /// Tear the SwiftUI content down so nothing in the popover renders while it is closed.
  func popoverDidClose(_ notification: Notification) {
    popover.contentViewController = nil
  }
}
