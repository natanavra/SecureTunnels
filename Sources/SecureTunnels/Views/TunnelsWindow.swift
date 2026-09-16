import SwiftUI
import SecureTunnelsCore

struct TunnelsWindow: View {
  @Environment(TunnelManager.self) private var manager
  @State private var selection: UUID?
  @State private var confirmDelete = false
  @State private var importMessage: String?

  init(initialSelection: UUID? = nil) {
    _selection = State(initialValue: initialSelection)
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if let id = selection, manager.tunnel(id) != nil {
          Button {
            manager.toggle(id)
          } label: {
            Label(
              manager.status(of: id).isActive ? "Disconnect" : "Connect",
              systemImage: manager.status(of: id).isActive ? "stop.fill" : "play.fill"
            )
          }
          .help(manager.status(of: id).isActive ? "Disconnect this tunnel" : "Connect this tunnel")
        }
        Button {
          importFromSecurePipes()
        } label: {
          Label("Import from Secure Pipes", systemImage: "square.and.arrow.down")
        }
        .help("Import connections from Secure Pipes")
        .disabled(!SecurePipesImporter.isAvailable())
      }
    }
    .alert("Secure Pipes Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
      Button("OK") { importMessage = nil }
    } message: {
      Text(importMessage ?? "")
    }
    .frame(minWidth: 780, minHeight: 520)
  }

  private var sidebar: some View {
    List(selection: $selection) {
      ForEach(manager.tunnels) { tunnel in
        HStack(spacing: 10) {
          StatusDot(status: manager.status(of: tunnel.id), size: 8)
          VStack(alignment: .leading, spacing: 1) {
            Text(tunnel.name).lineLimit(1)
            Text(tunnel.forwardDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(.vertical, 2)
        .tag(tunnel.id)
      }
      .onMove { manager.move(from: $0, to: $1) }
    }
    .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack(spacing: 0) {
        Button { selection = manager.add().id } label: { Image(systemName: "plus") }
          .help("Add a tunnel")
        Divider().frame(height: 16)
        Button { confirmDelete = true } label: { Image(systemName: "minus") }
          .disabled(selection == nil)
          .help("Remove the selected tunnel")
        Divider().frame(height: 16)
        Button {
          if let id = selection, let copy = manager.duplicate(id) { selection = copy.id }
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .disabled(selection == nil)
        .help("Duplicate the selected tunnel")
        Spacer()
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
    .confirmationDialog(
      "Remove “\(selection.flatMap(manager.tunnel)?.name ?? "")”?",
      isPresented: $confirmDelete,
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        if let id = selection {
          manager.remove(id)
          selection = nil
        }
      }
    } message: {
      Text("The tunnel is disconnected and its saved passphrase and password are deleted from your keychain.")
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let id = selection, manager.tunnel(id) != nil {
      TunnelEditorView(tunnel: Binding(
        get: { manager.tunnel(id) ?? Tunnel(id: id) },
        set: { manager.update($0) }
      ))
      .id(id)
    } else {
      ContentUnavailableView {
        Label("No Tunnel Selected", systemImage: "point.3.connected.trianglepath.dotted")
      } description: {
        Text(manager.tunnels.isEmpty
          ? "Add a tunnel with the + button, or import your Secure Pipes connections."
          : "Select a tunnel to edit it.")
      } actions: {
        if manager.tunnels.isEmpty && SecurePipesImporter.isAvailable() {
          Button("Import from Secure Pipes") { importFromSecurePipes() }
        }
      }
    }
  }

  private func importFromSecurePipes() {
    do {
      let summary = try manager.importFromSecurePipes()
      importMessage = "Imported \(summary.added) new and updated \(summary.updated) existing connections. "
        + "Key passphrases and passwords are not carried over, so enter them in each tunnel."
    } catch {
      importMessage = "Import failed: \(error.localizedDescription)"
    }
  }
}
