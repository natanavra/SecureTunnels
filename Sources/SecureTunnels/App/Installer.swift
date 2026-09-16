import AppKit
import Foundation

/// First-launch installer. When the app runs from a disk image or a download folder it offers to copy itself to
/// the Applications folder, clears the quarantine flag on the copy (ssh must be able to run the askpass helper),
/// relaunches from there, and then ejects and trashes the image or the downloaded bundle it came from.
@MainActor
enum Installer {
  private static let skipKey = "skipMoveToApplications"

  /// Returns true when the app is relaunching from Applications and the caller must not continue starting up.
  static func offerInstallIfNeeded() -> Bool {
    let arguments = CommandLine.arguments
    let forced = arguments.contains("--install")
    guard forced || shouldOffer() else { return false }

    if !forced {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = "Install SecureTunnels in your Applications folder?"
      alert.informativeText = "SecureTunnels is running from \(sourceDescription). It will be copied to the Applications folder "
        + "and opened from there, and \(sourceDescription) will be \(isOnDiskImage ? "ejected and " : "")moved to the Trash."
      alert.addButton(withTitle: "Install")
      alert.addButton(withTitle: "Not Now")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Don't ask again"
      let response = alert.runModal()
      if alert.suppressionButton?.state == .on {
        UserDefaults.standard.set(true, forKey: skipKey)
      }
      guard response == .alertFirstButtonReturn else {
        NSApp.setActivationPolicy(.accessory)
        return false
      }
    }

    do {
      let destination = try install()
      relaunchAndCleanUp(from: destination)
      return true
    } catch {
      if forced {
        FileHandle.standardError.write(Data("install failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
      let alert = NSAlert(error: error)
      alert.messageText = "SecureTunnels could not be installed"
      alert.runModal()
      NSApp.setActivationPolicy(.accessory)
      return false
    }
  }

  // MARK: Decision

  private static func shouldOffer() -> Bool {
    let path = Bundle.main.bundleURL.path
    if CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--launch-at-login") { return false }
    if ProcessInfo.processInfo.environment["SECURETUNNELS_NO_INSTALL"] != nil { return false }
    if UserDefaults.standard.bool(forKey: skipKey) { return false }
    if path.hasPrefix("/Applications/") || path.hasPrefix(userApplications.path + "/") { return false }
    // Developer builds run from the package's build folders.
    if path.contains("/.build/") || path.contains("/build/") { return false }
    return true
  }

  private static var userApplications: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
  }

  private static var isOnDiskImage: Bool {
    diskImage(containing: Bundle.main.bundleURL) != nil
  }

  private static var sourceDescription: String {
    isOnDiskImage ? "the disk image" : "the downloaded copy in \(Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent)"
  }

  // MARK: Install

  private static func install() throws -> URL {
    let source = Bundle.main.bundleURL
    let fm = FileManager.default
    var folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
    if !fm.isWritableFile(atPath: folder.path) {
      folder = userApplications
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let destination = folder.appendingPathComponent(source.lastPathComponent)

    // Stop an older copy that is already running from the destination.
    if let identifier = Bundle.main.bundleIdentifier {
      let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
      others.forEach { $0.terminate() }
      let deadline = Date().addingTimeInterval(5)
      while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      }
      others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    if fm.fileExists(atPath: destination.path) {
      do {
        try fm.trashItem(at: destination, resultingItemURL: nil)
      } catch {
        try fm.removeItem(at: destination)
      }
    }
    try fm.copyItem(at: source, to: destination)
    clearQuarantine(at: destination)
    return destination
  }

  /// Removes com.apple.quarantine from the bundle and everything inside it, so Gatekeeper lets ssh run the helper.
  private static func clearQuarantine(at root: URL) {
    let attribute = "com.apple.quarantine"
    var paths = [root.path]
    if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
      for case let url as URL in enumerator { paths.append(url.path) }
    }
    for path in paths {
      removexattr(path, attribute, XATTR_NOFOLLOW)
    }
  }

  // MARK: Relaunch and cleanup

  private static func relaunchAndCleanUp(from destination: URL) {
    let source = Bundle.main.bundleURL
    let cleanup = cleanupScript(for: source)

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
      Task { @MainActor in
        if let cleanup {
          let shell = Process()
          shell.executableURL = URL(fileURLWithPath: "/bin/sh")
          shell.arguments = ["-c", cleanup]
          try? shell.run()
        }
        NSApp.terminate(nil)
      }
    }
  }

  /// A shell snippet that runs after this process has exited: eject the image and trash it, or trash the
  /// downloaded bundle and its zip.
  private static func cleanupScript(for source: URL) -> String? {
    let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
    func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    if let image = diskImage(containing: source) {
      return "sleep 3; hdiutil detach \(quoted(image.mountPoint)) -force >/dev/null 2>&1; "
        + "mv -f \(quoted(image.imagePath)) \(quoted(trash))/ 2>/dev/null; exit 0"
    }
    let folder = source.deletingLastPathComponent().path
    let zips = "\(quoted(folder))/SecureTunnels*.zip"
    return "sleep 3; mv -f \(quoted(source.path)) \(quoted(trash))/ 2>/dev/null; "
      + "for z in \(zips); do [ -f \"$z\" ] && mv -f \"$z\" \(quoted(trash))/; done; exit 0"
  }

  private struct MountedImage {
    var imagePath: String
    var mountPoint: String
  }

  /// Asks hdiutil which disk image, if any, is mounted at a path containing `url`.
  private static func diskImage(containing url: URL) -> MountedImage? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["info", "-plist"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let images = plist["images"] as? [[String: Any]]
    else { return nil }
    for image in images {
      guard let imagePath = image["image-path"] as? String,
        let entities = image["system-entities"] as? [[String: Any]]
      else { continue }
      for entity in entities {
        if let mount = entity["mount-point"] as? String, url.path.hasPrefix(mount + "/") {
          return MountedImage(imagePath: imagePath, mountPoint: mount)
        }
      }
    }
    return nil
  }
}
