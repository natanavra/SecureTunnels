import AppKit
import SwiftUI
import SecureTunnelsCore

/// Sidebar list of the tunnels that exist in the Cloudflare account.
struct RemoteTunnelSidebar: View {
  @Environment(TunnelManager.self) private var manager
  @Binding var selection: String?

  private var cf: CloudflareSettings { CloudflareSettings.shared }

  var body: some View {
    List(selection: $selection) {
      if !cf.hasToken || cf.accountID.isEmpty {
        Text("Add a Cloudflare API token under Settings > Cloudflare to see the tunnels in your account.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if cf.remoteTunnels.isEmpty && !cf.isLoadingTunnels {
        Text(cf.tunnelsError ?? "No tunnels in \(cf.accountName) yet. Create one from the Tunnels list with type Cloudflare Tunnel.")
          .font(.caption)
          .foregroundStyle(cf.tunnelsError == nil ? Color.secondary : Color.red)
      }
      ForEach(cf.remoteTunnels) { info in
        HStack(spacing: 10) {
          Circle()
            .fill(info.statusColor)
            .frame(width: 8, height: 8)
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
              Text(info.tunnel.name).lineLimit(1)
              if manager.localTunnel(forRemoteID: info.tunnel.id) != nil {
                Image(systemName: "checkmark.circle.fill")
                  .font(.caption)
                  .foregroundStyle(.blue)
                  .help("Runs from SecureTunnels")
              }
            }
            Text(info.hostnames.isEmpty ? info.statusLabel : info.hostnames.joined(separator: ", "))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(.vertical, 2)
        .tag(info.id)
      }
    }
    .overlay(alignment: .bottom) {
      if cf.isLoadingTunnels {
        ProgressView().controlSize(.small).padding(8)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Text(cf.accountName.isEmpty ? "" : cf.accountName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button {
          Task { await cf.refreshRemoteTunnels() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(cf.isLoadingTunnels || !cf.hasToken)
        .help("Reload the tunnel list from Cloudflare")
      }
      .padding(10)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
    .onAppear {
      if cf.remoteTunnels.isEmpty { Task { await cf.refreshRemoteTunnels() } }
    }
  }
}

/// Detail for one tunnel in the account: status, routes, and the actions to run it from here or delete it.
struct RemoteTunnelDetail: View {
  @Environment(TunnelManager.self) private var manager
  @Binding var selection: String?
  @State private var confirmDelete = false
  @State private var deleteError: String?

  private var cf: CloudflareSettings { CloudflareSettings.shared }
  private var info: RemoteTunnelInfo? { cf.remoteTunnels.first { $0.id == selection } }

  var body: some View {
    if let info {
      let local = manager.localTunnel(forRemoteID: info.tunnel.id)
      Form {
        Section("Tunnel") {
          LabeledContent("Name", value: info.tunnel.name)
          LabeledContent("Status") {
            HStack(spacing: 6) {
              Circle().fill(info.statusColor).frame(width: 8, height: 8)
              Text(info.statusLabel)
            }
          }
          if let count = info.tunnel.connectionCount {
            LabeledContent("Edge connections", value: String(count))
          }
          if let created = info.createdLabel {
            LabeledContent("Created", value: created)
          }
          LabeledContent("Tunnel ID") {
            Text(info.tunnel.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
        }

        Section("Routes") {
          if info.ingress.isEmpty {
            Text("No ingress is configured in the dashboard. The tunnel uses a local config file, or has not been routed yet, so SecureTunnels cannot run it.")
              .foregroundStyle(.secondary)
          }
          ForEach(Array(info.ingress.enumerated()), id: \.offset) { _, rule in
            LabeledContent(rule.hostname ?? "Any hostname") {
              HStack(spacing: 8) {
                Text(rule.service).textSelection(.enabled)
                if let hostname = rule.hostname, let url = URL(string: "https://\(hostname)") {
                  Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open https://\(hostname)")
                }
              }
            }
          }
        }

        Section("SecureTunnels") {
          if let local {
            HStack {
              StatusDot(status: manager.status(of: local.id), size: 8)
              Text("Runs from here as “\(local.name)”, \(manager.status(of: local.id).label.lowercased()).")
              Spacer()
              Button { manager.pendingSelection = local.id } label: {
                Label("Open Tunnel", systemImage: "arrow.up.right.square")
              }
              .buttonStyle(.bordered)
              .help("Open the local tunnel entry")
            }
          } else {
            HStack {
              Text(info.ingress.isEmpty
                ? "Route the tunnel to a hostname in the Cloudflare dashboard first."
                : "Add it to run and stop it from the menu bar. Its routes stay as they are in the dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button {
                if let tunnel = manager.adoptCloudflareTunnel(info) { manager.pendingSelection = tunnel.id }
              } label: {
                Label("Add to SecureTunnels", systemImage: "plus")
              }
              .buttonStyle(.borderedProminent)
              .disabled(info.ingress.isEmpty)
              .help("Create a local entry that runs this tunnel")
            }
          }
        }

        Section("Danger zone") {
          HStack {
            Text("Deletes the tunnel from Cloudflare and the DNS records that point to it.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: {
              Label("Delete from Cloudflare", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .help("Remove this tunnel from the Cloudflare account")
          }
          if let deleteError {
            Text(deleteError).font(.caption).foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .confirmationDialog("Delete “\(info.tunnel.name)” from Cloudflare?", isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("Delete Tunnel", role: .destructive) { delete(info) }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(deleteMessage(info))
      }
    } else {
      ContentUnavailableView {
        Label("Cloudflare Tunnels", systemImage: "cloud")
      } description: {
        Text(cf.hasToken
          ? "Select a tunnel to see its routes, run it from SecureTunnels, or delete it."
          : "Add a Cloudflare API token under Settings > Cloudflare to manage the tunnels in your account.")
      } actions: {
        if !cf.hasToken {
          Button { manager.pendingMode = .settings } label: { Label("Open Settings", systemImage: "gearshape") }
            .buttonStyle(.borderedProminent)
        }
      }
    }
  }

  private func deleteMessage(_ info: RemoteTunnelInfo) -> String {
    var text = "The tunnel and its connections are removed from the Cloudflare account. This cannot be undone."
    if !info.hostnames.isEmpty {
      text += " DNS records for \(info.hostnames.joined(separator: ", ")) that point to it are deleted too."
    }
    if manager.localTunnel(forRemoteID: info.tunnel.id) != nil {
      text += " The SecureTunnels entry stays and will create a new tunnel on its next connect."
    }
    return text
  }

  private func delete(_ info: RemoteTunnelInfo) {
    Task {
      do {
        try await cf.deleteRemoteTunnel(info)
        manager.unlinkCloudflareTunnel(remoteID: info.tunnel.id)
        deleteError = nil
        selection = nil
      } catch {
        deleteError = "Delete failed: \(error.localizedDescription)"
      }
    }
  }
}

extension RemoteTunnelInfo {
  var statusColor: Color {
    switch tunnel.status {
    case "healthy": return .green
    case "degraded": return .orange
    case "down": return .red
    default: return Color.secondary.opacity(0.5)
    }
  }

  var createdLabel: String? {
    guard let raw = tunnel.createdAt, let date = ISO8601DateFormatter().date(from: raw) else { return nil }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
