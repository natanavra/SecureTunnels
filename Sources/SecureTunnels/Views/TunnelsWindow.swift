import SwiftUI
import SecureTunnelsCore

enum SidebarMode: String, CaseIterable, Identifiable {
  case tunnels = "Tunnels"
  case profiles = "Profiles"
  var id: String { rawValue }
}

struct TunnelsWindow: View {
  @Environment(TunnelManager.self) private var manager
  @State private var mode: SidebarMode = .tunnels
  @State private var selection: UUID?
  @State private var profileSelection: UUID?
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
        if mode == .tunnels, let id = selection, manager.tunnel(id) != nil {
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
    .onAppear(perform: consumePendingSelection)
    .onChange(of: manager.pendingSelection) { consumePendingSelection() }
    .onChange(of: manager.pendingProfileSelection) { consumePendingSelection() }
    .frame(minWidth: 800, minHeight: 560)
  }

  /// The popover and the editor ask for a specific tunnel or profile through the manager.
  private func consumePendingSelection() {
    if let id = manager.pendingSelection {
      mode = .tunnels
      selection = id
      manager.pendingSelection = nil
    }
    if let id = manager.pendingProfileSelection {
      mode = .profiles
      profileSelection = id
      manager.pendingProfileSelection = nil
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      Picker("", selection: $mode) {
        ForEach(SidebarMode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      switch mode {
      case .tunnels: tunnelList
      case .profiles: profileList
      }
    }
    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Remove", role: .destructive, action: deleteSelected)
    } message: {
      Text(deleteMessage)
    }
  }

  private var tunnelList: some View {
    List(selection: $selection) {
      ForEach(manager.groups, id: \.self) { group in
        Section(group.isEmpty ? (manager.groups.count > 1 ? "Other" : "") : group) {
          ForEach(manager.tunnels(inGroup: group)) { tunnel in
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
        }
      }
    }
  }

  private var profileList: some View {
    List(selection: $profileSelection) {
      ForEach(manager.profiles) { profile in
        VStack(alignment: .leading, spacing: 1) {
          Text(profile.name).lineLimit(1)
          Text(profile.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .tag(profile.id)
      }
      if manager.profiles.isEmpty {
        Text("Profiles bundle a server's host, user, key and secrets so several tunnels can share them.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var bottomBar: some View {
    HStack(spacing: 0) {
      Button(action: addItem) { Image(systemName: "plus") }
        .help(mode == .tunnels ? "Add a tunnel" : "Add a profile")
      Divider().frame(height: 16)
      Button { confirmDelete = true } label: { Image(systemName: "minus") }
        .disabled(currentSelection == nil)
        .help(mode == .tunnels ? "Remove the selected tunnel" : "Remove the selected profile")
      if mode == .tunnels {
        Divider().frame(height: 16)
        Button {
          if let id = selection, let copy = manager.duplicate(id) { selection = copy.id }
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .disabled(selection == nil)
        .help("Duplicate the selected tunnel")
      }
      Spacer()
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }

  private var currentSelection: UUID? {
    mode == .tunnels ? selection : profileSelection
  }

  private func addItem() {
    switch mode {
    case .tunnels: selection = manager.add().id
    case .profiles: profileSelection = manager.addProfile().id
    }
  }

  private var deleteTitle: String {
    switch mode {
    case .tunnels: return "Remove “\(selection.flatMap(manager.tunnel)?.name ?? "")”?"
    case .profiles: return "Remove profile “\(profileSelection.flatMap(manager.profile)?.name ?? "")”?"
    }
  }

  private var deleteMessage: String {
    switch mode {
    case .tunnels:
      return "The tunnel is disconnected and its saved passphrase and password are deleted from your keychain."
    case .profiles:
      let count = profileSelection.map { manager.tunnels(using: $0).count } ?? 0
      return count == 0
        ? "No tunnel uses this profile."
        : "\(count) tunnel(s) use this profile. They keep a copy of its settings and secrets."
    }
  }

  private func deleteSelected() {
    switch mode {
    case .tunnels:
      if let id = selection {
        manager.remove(id)
        selection = nil
      }
    case .profiles:
      if let id = profileSelection {
        manager.removeProfile(id)
        profileSelection = nil
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch mode {
    case .tunnels:
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
    case .profiles:
      if let id = profileSelection, manager.profile(id) != nil {
        ProfileEditorView(profile: Binding(
          get: { manager.profile(id) ?? Profile(id: id) },
          set: { manager.updateProfile($0) }
        ))
        .id(id)
      } else {
        ContentUnavailableView {
          Label("No Profile Selected", systemImage: "person.badge.key")
        } description: {
          Text("A profile is a server plus its credentials. Tunnels that use it share the host, user, key and secrets.")
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
