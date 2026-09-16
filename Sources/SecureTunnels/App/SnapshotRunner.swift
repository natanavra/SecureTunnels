import AppKit
import SwiftUI
import SecureTunnelsCore

/// Developer aid: `SecureTunnels --snapshot <dir> [--demo] [--dark]` renders the main views to PNG files and quits.
/// It draws through the app's own windows, so it needs no screen recording permission. `--demo` swaps in sample
/// tunnels so screenshots never show real servers; `--dark` renders in dark mode.
@MainActor
enum SnapshotRunner {
  static func runIfRequested() -> Bool {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return false }
    let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let manager = TunnelManager.shared
    let settings = AppSettings.shared
    if arguments.contains("--demo") {
      manager.loadDemoData()
    }
    if arguments.contains("--dark") {
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    let firstTunnel = manager.tunnels.first?.id

    let pages: [(name: String, view: AnyView, size: NSSize)] = [
      ("menubar", AnyView(MenuBarView().environment(manager).environment(settings)
        .background(Color(nsColor: .windowBackgroundColor))), NSSize(width: 320, height: 0)),
      ("tunnels", AnyView(TunnelsWindow(initialSelection: firstTunnel).environment(manager).environment(settings)), NSSize(width: 860, height: 600)),
      ("settings", AnyView(SettingsView().environment(manager).environment(settings)), NSSize(width: 520, height: 0)),
    ]

    var windows: [(String, NSWindow)] = []
    for page in pages {
      let hosting = NSHostingView(rootView: page.view)
      let isPopover = page.name == "menubar"
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: page.size),
        styleMask: isPopover ? [.borderless] : [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.contentView = hosting
      window.toolbarStyle = .unified
      window.title = "Tunnels"
      if isPopover {
        window.isOpaque = false
        window.backgroundColor = .clear
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 11
        hosting.layer?.masksToBounds = true
      }
      if page.size.height == 0 {
        window.setContentSize(hosting.fittingSize)
      }
      window.orderFrontRegardless()
      windows.append((page.name, window))
    }

    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      for (name, window) in windows {
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))
        guard let image = capture(window) else { continue }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
      }
      exit(0)
    }
    return true
  }

  /// Captures one of our own windows, including translucent materials, which offscreen view caching draws black.
  private static func capture(_ window: NSWindow) -> CGImage? {
    let windowID = CGWindowID(window.windowNumber)
    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) {
      return image
    }
    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
  }
}
