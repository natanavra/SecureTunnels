import SwiftUI
import SecureTunnelsCore

struct MenuBarView: View {
  @Environment(TunnelManager.self) private var manager
  /// Opens the main window, optionally in a given sidebar mode. The status item controller closes the popover.
  var openMain: (SidebarMode?) -> Void = { _ in }
  @AppStorage("menuShowsAllTunnels") private var showAll = false
  /// The compact order is decided when the popover opens and kept until it closes, so rows do not jump
  /// around while the user is switching tunnels on and off.
  @State private var compactOrder: [UUID] = []

  /// How many rows the compact list shows before "Show all".
  static let compactLimit = 5
  /// Rows and group headers have fixed heights so the list height is known without measuring. A ScrollView only
  /// appears past the cap, with an explicit height, because an unsized ScrollView collapses to nothing here.
  static let rowHeight: CGFloat = 44
  static let groupHeaderHeight: CGFloat = 26
  static let maxListHeight: CGFloat = 460

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if manager.tunnels.isEmpty {
        emptyState
      } else if showAll || manager.tunnels.count <= Self.compactLimit {
        sizedList(rows: manager.tunnels.count, headers: showsGroupHeaders ? manager.groups.count : 0) {
          ForEach(manager.groups, id: \.self) { group in
            if showsGroupHeaders {
              GroupHeader(group: group)
            }
            ForEach(manager.tunnels(inGroup: group)) { tunnel in
              TunnelMenuRow(tunnel: tunnel, showDetails: { showDetails(tunnel.id) })
            }
          }
        }
      } else {
        sizedList(rows: compactTunnels.count, headers: 0) {
          ForEach(compactTunnels) { tunnel in
            TunnelMenuRow(tunnel: tunnel, showDetails: { showDetails(tunnel.id) })
          }
        }
      }
      if manager.tunnels.count > Self.compactLimit {
        Divider()
        MenuRowButton(
          title: showAll ? "Show fewer" : "Show all \(manager.tunnels.count) tunnels",
          systemImage: showAll ? "chevron.up" : "chevron.down",
          help: showAll ? "Back to the short list: active tunnels first, then \(Self.compactLimit) at most" : "List every tunnel by group"
        ) {
          showAll.toggle()
        }
        .padding(6)
      }
      Divider()
      footer
    }
    .frame(width: 320)
    .onAppear { compactOrder = rankedTunnelIDs() }
  }

  private var showsGroupHeaders: Bool {
    manager.groups.count > 1 || manager.groups.first?.isEmpty == false
  }

  static func listHeight(rows: Int, headers: Int) -> CGFloat {
    let items = rows + headers
    let spacing = CGFloat(max(items - 1, 0))
    return CGFloat(rows) * rowHeight + CGFloat(headers) * groupHeaderHeight + spacing + 12
  }

  @ViewBuilder
  private func sizedList<Content: View>(rows: Int, headers: Int, @ViewBuilder content: () -> Content) -> some View {
    let list = VStack(spacing: 1) { content() }.padding(6)
    let height = Self.listHeight(rows: rows, headers: headers)
    if height > Self.maxListHeight {
      ScrollView { list }.frame(height: Self.maxListHeight)
    } else {
      list.frame(height: height, alignment: .top)
    }
  }

  /// The rows in the order frozen at open time. Tunnels added since then go last; removed ones drop out.
  private var compactTunnels: [Tunnel] {
    var ids = compactOrder.filter { manager.tunnel($0) != nil }
    if ids.isEmpty { ids = rankedTunnelIDs() }
    for id in rankedTunnelIDs() where !ids.contains(id) { ids.append(id) }
    return ids.prefix(Self.compactLimit).compactMap(manager.tunnel)
  }

  /// Active tunnels first (connected, then connecting or retrying), then failed, then idle, in sidebar order.
  private func rankedTunnelIDs() -> [UUID] {
    let ordered = manager.groups.flatMap { manager.tunnels(inGroup: $0) }
    let ranked = ordered.enumerated().sorted { lhs, rhs in
      let l = rank(lhs.element), r = rank(rhs.element)
      return l != r ? l < r : lhs.offset < rhs.offset
    }
    return ranked.map(\.element.id)
  }

  private func rank(_ tunnel: Tunnel) -> Int {
    switch manager.status(of: tunnel.id) {
    case .connected: return 0
    case .connecting, .reconnecting, .waitingForNetwork: return 1
    case .failed: return 2
    case .disconnected: return 3
    }
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
    if !manager.networkAvailable { return "No network" }
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
      Button { openMain(.tunnels) } label: { Label("Manage Tunnels", systemImage: "slider.horizontal.3") }
        .buttonStyle(PillButtonStyle(prominent: true))
        .help("Add your first tunnel")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity)
  }

  private var footer: some View {
    VStack(spacing: 1) {
      if manager.activeCount > 0 {
        MenuRowButton(title: "Disconnect All", systemImage: "stop.circle", help: "Close every open tunnel") { manager.disconnectAll() }
      }
      MenuRowButton(title: "Manage Tunnels…", systemImage: "slider.horizontal.3", help: "Add, edit and remove tunnels and profiles") {
        openMain(.tunnels)
      }
      .keyboardShortcut(",", modifiers: [.command, .shift])
      MenuRowButton(title: "Settings…", systemImage: "gearshape", help: "Launch at login, import and storage") {
        openMain(.settings)
      }
      .keyboardShortcut(",")
      MenuRowButton(title: "Quit SecureTunnels", systemImage: "power", help: "Quit and close every tunnel") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .padding(6)
  }

  private func showDetails(_ id: UUID) {
    manager.pendingSelection = id
    openMain(nil)
  }
}

private struct GroupHeader: View {
  @Environment(TunnelManager.self) private var manager
  let group: String
  @State private var hovering = false

  private var tunnels: [Tunnel] { manager.tunnels(inGroup: group) }
  private var anyActive: Bool { tunnels.contains { manager.status(of: $0.id).isActive } }
  private var allActive: Bool { tunnels.allSatisfy { manager.status(of: $0.id).isActive } }

  var body: some View {
    HStack(spacing: 6) {
      Text(group.isEmpty ? "Other" : group)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
      if hovering {
        if !allActive {
          Button { manager.connectAll(inGroup: group) } label: {
            Label("All", systemImage: "play.fill")
          }
          .help("Connect all in \(group.isEmpty ? "Other" : group)")
        }
        if anyActive {
          Button { manager.disconnectAll(inGroup: group) } label: {
            Label("All", systemImage: "stop.fill")
          }
          .help("Disconnect all in \(group.isEmpty ? "Other" : group)")
        }
      }
    }
    .buttonStyle(PillButtonStyle(prominent: false))
    .padding(.horizontal, 8)
    .padding(.top, 6)
    .frame(height: MenuBarView.groupHeaderHeight)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
  }
}

private struct TunnelMenuRow: View {
  @Environment(TunnelManager.self) private var manager
  let tunnel: Tunnel
  let showDetails: () -> Void
  @State private var hovering = false

  private var status: TunnelStatus { manager.status(of: tunnel.id) }
  private var isFailed: Bool {
    if case .failed = status { return true }
    return false
  }

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
      if let url = manager.publicURL[tunnel.id], status == .connected, let link = URL(string: url) {
        Button { NSWorkspace.shared.open(link) } label: {
          Image(systemName: "safari").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open \(url)")
      }
      if isFailed || manager.lastError[tunnel.id] != nil {
        Button(action: showDetails) {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(isFailed ? Color.red : Color.orange)
        }
        .buttonStyle(.plain)
        .help("Show why the connection failed")
      }
      TunnelSwitch(isOn: status.isActive, label: tunnel.name) { manager.toggle(tunnel.id) }
        .help(status.isActive ? "Disconnect \(tunnel.name)" : "Connect \(tunnel.name)")
    }
    .padding(.horizontal, 8)
    .frame(height: MenuBarView.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { manager.toggle(tunnel.id) }
    .help(helpText)
    .contextMenu {
      Button(status.isActive ? "Disconnect" : "Connect") { manager.toggle(tunnel.id) }
      Button("Edit…", action: showDetails)
    }
  }

  private var subtitle: String {
    switch status {
    case .failed(let message): return message
    case .reconnecting, .waitingForNetwork:
      if let error = manager.lastError[tunnel.id] { return "\(status.label): \(error)" }
      return status.label
    case .connected:
      if let url = manager.publicURL[tunnel.id] { return url }
      return tunnel.forwardDescription
    default: return tunnel.forwardDescription
    }
  }

  private var subtitleColor: Color {
    switch status {
    case .failed: return .red
    case .reconnecting: return .orange
    default: return .secondary
    }
  }

  private var helpText: String {
    let resolved = manager.resolved(tunnel)
    var lines = [resolved.destination, tunnel.forwardDescription, status.label]
    if let error = manager.lastError[tunnel.id] { lines.append(error) }
    return lines.joined(separator: "\n")
  }
}

struct MenuRowButton: View {
  let title: String
  let systemImage: String
  var help: String = ""
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
    .help(help)
  }
}

/// A small on/off switch drawn in SwiftUI. The popover avoids system control styles so it only renders plain shapes.
struct TunnelSwitch: View {
  let isOn: Bool
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Capsule(style: .continuous)
        .fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
        .frame(width: 28, height: 16)
        .overlay(alignment: isOn ? .trailing : .leading) {
          Circle()
            .fill(Color.white)
            .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            .padding(2)
        }
        .animation(.easeOut(duration: 0.12), value: isOn)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityValue(isOn ? "On" : "Off")
  }
}

/// A compact capsule button drawn with plain shapes, used in the popover instead of the bordered system style.
struct PillButtonStyle: ButtonStyle {
  let prominent: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(prominent ? .callout : .caption2)
      .padding(.horizontal, prominent ? 12 : 7)
      .padding(.vertical, prominent ? 5 : 2)
      .background(
        Capsule(style: .continuous)
          .fill(prominent ? Color.accentColor : Color.primary.opacity(0.1))
          .opacity(configuration.isPressed ? 0.7 : 1)
      )
      .foregroundStyle(prominent ? Color.white : Color.primary)
      .contentShape(Capsule())
  }
}
