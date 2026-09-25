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
    if arguments.contains("--popover-sizes") {
      printPopoverSizes()
      exit(0)
    }
    if let index = arguments.firstIndex(of: "--stress") {
      let cycles = index + 1 < arguments.count ? Int(arguments[index + 1]) ?? 200 : 200
      TunnelManager.shared.loadDemoData()
      Task { @MainActor in
        await StatusItemController.shared.stressTest(cycles: cycles)
        exit(0)
      }
      return true
    }
    if arguments.contains("--selftest") {
      if arguments.contains("--demo") { TunnelManager.shared.loadDemoData() }
      Task { @MainActor in
        await StatusItemController.shared.selfTest()
        MainWindowController.shared.show(mode: .tunnels)
        try? await Task.sleep(for: .seconds(2))
        if let index = arguments.firstIndex(of: "--capture"), index + 1 < arguments.count,
          let window = MainWindowController.shared.window, let image = capture(window) {
          let rep = NSBitmapImageRep(cgImage: image)
          try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[index + 1]))
          print("main window captured \(image.width)x\(image.height) toolbar=\(window.toolbar != nil) items=\(window.toolbar?.items.count ?? 0)")
        }
        exit(0)
      }
      return true
    }
    guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return false }
    let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let manager = TunnelManager.shared
    let settings = AppSettings.shared
    if arguments.contains("--demo") {
      manager.loadDemoData()
      if let index = arguments.firstIndex(of: "--demo-count"), index + 1 < arguments.count, let count = Int(arguments[index + 1]) {
        manager.trimDemoData(to: count)
      }
    }
    if arguments.contains("--dark") {
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    let firstTunnel = manager.tunnels.first?.id

    let pages: [(name: String, view: AnyView, size: NSSize)] = [
      ("menubar", AnyView(MenuBarView().environment(manager).environment(settings)
        .background(Color(nsColor: .windowBackgroundColor))), NSSize(width: 320, height: 0)),
      ("tunnels", AnyView(TunnelsWindow(initialSelection: firstTunnel).environment(manager).environment(settings)), NSSize(width: 940, height: 640)),
      ("settings", AnyView(SettingsView().environment(manager).environment(settings)
        .frame(width: 520).fixedSize(horizontal: false, vertical: true)), NSSize(width: 520, height: 0)),
    ]

    writeMenuBarGlyphs(to: directory)
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
      window.title = "SecureTunnels"
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

  /// Prints how tall the popover would be for 0 to 8 demo tunnels, hosted the same way StatusItemController does.
  /// A list that collapses shows up as a height equal to the header plus footer.
  private static func printPopoverSizes() {
    let manager = TunnelManager.shared
    for count in 0...8 {
      manager.loadDemoData()
      manager.trimDemoData(to: count)
      let host = NSHostingController(rootView: MenuBarView().environment(manager).environment(AppSettings.shared))
      host.sizingOptions = [.preferredContentSize]
      let ideal = host.sizeThatFits(in: NSSize(width: CGFloat.nan, height: CGFloat.nan))
      host.view.layoutSubtreeIfNeeded()
      print("tunnels=\(count) ideal=\(Int(ideal.width))x\(Int(ideal.height)) preferred=\(Int(host.preferredContentSize.width))x\(Int(host.preferredContentSize.height))")
    }
  }

  /// Renders the status item glyphs at 8x, on light and dark backgrounds, for a quick visual check.
  private static func writeMenuBarGlyphs(to directory: URL) {
    let scale: CGFloat = 8
    let cell = NSSize(width: 18 * scale, height: 18 * scale)
    let image = NSImage(size: NSSize(width: cell.width * 2, height: cell.height * 2))
    image.lockFocus()
    for (column, glyph) in [MenuBarIcon.idle, MenuBarIcon.connected].enumerated() {
      for (row, dark) in [false, true].enumerated() {
        let rect = NSRect(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height, width: cell.width, height: cell.height)
        (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        rect.fill()
        let tinted = glyph.copy() as! NSImage
        tinted.isTemplate = false
        tinted.lockFocus()
        (dark ? NSColor.white : NSColor.black).set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: rect.insetBy(dx: cell.width * 0.2, dy: cell.height * 0.2))
      }
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menubar-glyph.png"))
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
