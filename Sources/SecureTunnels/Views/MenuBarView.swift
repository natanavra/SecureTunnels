import SwiftUI
import SecureTunnelsCore

struct MenuBarView: View {
  @Environment(TunnelManager.self) private var manager
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if manager.tunnels.isEmpty {
        emptyState
      } else {
        ScrollView {
          VStack(spacing: 1) {
            ForEach(manager.tunnels) { tunnel in
              TunnelMenuRow(tunnel: tunnel)
            }
          }
          .padding(6)
        }
        .frame(maxHeight: 420)
      }
      Divider()
      footer
    }
    .frame(width: 320)
  }

  private var header: some View {
    HStack {
      Image(systemName: "lock.shield.fill")
        .foregroundStyle(manager.connectedCount > 0 ? Color.green : Color.secondary)
      Text("SecureTunnels")
        .font(.headline)
      Spacer()
      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  private var summary: String {
    guard !manager.tunnels.isEmpty else { return "" }
    return "\(manager.connectedCount) of \(manager.tunnels.count) connected"
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Text("No tunnels yet")
        .font(.subheadline)
      Text("Add a forward or import your Secure Pipes connections.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Manage Tunnels…") { open(WindowID.tunnels) }
        .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity)
  }

  private var footer: some View {
    VStack(spacing: 1) {
      if manager.activeCount > 0 {
        MenuRowButton(title: "Disconnect All", systemImage: "stop.circle") { manager.disconnectAll() }
      }
      MenuRowButton(title: "Manage Tunnels…", systemImage: "slider.horizontal.3") { open(WindowID.tunnels) }
        .keyboardShortcut(",", modifiers: [.command, .shift])
      MenuRowButton(title: "Settings…", systemImage: "gearshape") { open(WindowID.settings) }
        .keyboardShortcut(",")
      MenuRowButton(title: "Quit SecureTunnels", systemImage: "power") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .padding(6)
  }

  private func open(_ id: String) {
    AppDelegate.bringToFront()
    openWindow(id: id)
  }
}

private struct TunnelMenuRow: View {
  @Environment(TunnelManager.self) private var manager
  let tunnel: Tunnel
  @State private var hovering = false

  private var status: TunnelStatus { manager.status(of: tunnel.id) }

  var body: some View {
    HStack(spacing: 10) {
      StatusDot(status: status)
      VStack(alignment: .leading, spacing: 1) {
        Text(tunnel.name)
          .font(.body)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(subtitleColor)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Toggle("", isOn: Binding(get: { status.isActive }, set: { _ in manager.toggle(tunnel.id) }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { manager.toggle(tunnel.id) }
    .help(helpText)
  }

  private var subtitle: String {
    switch status {
    case .failed(let message): return message
    case .reconnecting, .waitingForNetwork: return status.label
    default: return tunnel.forwardDescription
    }
  }

  private var subtitleColor: Color {
    if case .failed = status { return .red }
    return .secondary
  }

  private var helpText: String {
    "\(tunnel.destination)\n\(tunnel.forwardDescription)\n\(status.label)"
  }
}

struct MenuRowButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .frame(width: 16)
          .foregroundStyle(.secondary)
        Text(title)
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(hovering ? Color.accentColor.opacity(0.85) : Color.clear)
      )
      .foregroundStyle(hovering ? Color.white : Color.primary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
