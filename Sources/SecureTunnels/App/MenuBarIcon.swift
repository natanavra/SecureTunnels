import AppKit

/// The status item glyph: the same tunnel arch as the app icon, drawn as a template image so it follows the
/// menu bar's light and dark appearance. Connected shows a dot inside the opening.
enum MenuBarIcon {
  static let idle = make(connected: false)
  static let connected = make(connected: true)

  private static func make(connected: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
      let stroke: CGFloat = 3
      let inset: CGFloat = 2.5
      let left = inset + stroke / 2
      let right = rect.width - inset - stroke / 2
      let bottom: CGFloat = 2
      let radius = (right - left) / 2
      let center = NSPoint(x: rect.midX, y: rect.height - inset - stroke / 2 - radius)

      let arch = NSBezierPath()
      arch.move(to: NSPoint(x: left, y: bottom))
      arch.line(to: NSPoint(x: left, y: center.y))
      arch.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
      arch.line(to: NSPoint(x: right, y: bottom))
      arch.lineWidth = stroke
      arch.lineCapStyle = .butt
      arch.lineJoinStyle = .round
      NSColor.black.setStroke()
      arch.stroke()

      if connected {
        let dot = NSBezierPath(ovalIn: NSRect(x: rect.midX - 2, y: bottom + 2.5, width: 4, height: 4))
        NSColor.black.setFill()
        dot.fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
