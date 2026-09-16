import SwiftUI

struct StatusDot: View {
  let status: TunnelStatus
  var size: CGFloat = 9

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 2).padding(-2))
      .opacity(pulsing ? 0.55 : 1)
      .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulsing)
  }

  private var pulsing: Bool {
    switch status {
    case .connecting, .reconnecting, .waitingForNetwork: return true
    default: return false
    }
  }

  private var color: Color {
    switch status {
    case .connected: return .green
    case .connecting, .reconnecting, .waitingForNetwork: return .orange
    case .failed: return .red
    case .disconnected: return Color.secondary.opacity(0.5)
    }
  }
}
