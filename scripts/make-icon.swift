import AppKit

// Renders the app icon into an .icns file. Usage: swift make-icon.swift out.icns [source.png]
// With a source PNG (full-bleed square artwork) it is masked into the macOS rounded tile with the standard
// margins. Without one, a shield on a dark blue tile is drawn instead.
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let sourcePath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/icon-source.png"
let source = FileManager.default.fileExists(atPath: sourcePath) ? opaqueImage(atPath: sourcePath) : nil

/// Generated artwork often carries a noisy alpha channel that turns into blotches when composited. Keep the straight
/// colour channels and force every pixel opaque.
func opaqueImage(atPath path: String) -> NSImage? {
  guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
    let data = cg.dataProvider?.data as Data?
  else { return nil }
  guard cg.bitsPerPixel == 32 else { return NSImage(cgImage: cg, size: .zero) }
  var pixels = [UInt8](data)
  for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
  guard let context = CGContext(
    data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.bytesPerRow,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
  ), let opaque = context.makeImage() else { return nil }
  return NSImage(cgImage: opaque, size: NSSize(width: cg.width, height: cg.height))
}
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("SecureTunnels-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let scale = CGFloat(size) / 1024
  let tile = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
  let path = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)
  if let source {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    image.unlockFocus()
    return image
  }
  NSGradient(
    starting: NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.55, alpha: 1),
    ending: NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.24, alpha: 1)
  )!.draw(in: path, angle: -90)

  let config = NSImage.SymbolConfiguration(pointSize: 520 * scale, weight: .medium)
  if let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor(calibratedRed: 0.62, green: 0.90, blue: 0.72, alpha: 1).set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let origin = NSPoint(x: tile.midX - tinted.size.width / 2, y: tile.midY - tinted.size.height / 2)
    tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
  }
  image.unlockFocus()
  return image
}

func writePNG(_ image: NSImage, pixels: Int, name: String) throws {
  guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
  rep.size = NSSize(width: pixels, height: pixels)
  guard let png = rep.representation(using: .png, properties: [:]) else { return }
  try png.write(to: iconset.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
  try writePNG(render(size: base), pixels: base, name: "icon_\(base)x\(base).png")
  try writePNG(render(size: base * 2), pixels: base * 2, name: "icon_\(base)x\(base)@2x.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Wrote \(output)")
