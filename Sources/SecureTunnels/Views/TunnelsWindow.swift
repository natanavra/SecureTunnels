import SwiftUI
import SecureTunnelsCore

enum SidebarMode: String, CaseIterable, Identifiable {
  case tunnels = "Tunnels"
  case profiles = "Profiles"
  case cloudflare = "Cloudflare"
  case settings = "Settings"
  var id: String { rawValue }
}

struct TunnelsWindow: View {
  @Environment(TunnelManager.self) private var manager
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var mode: SidebarMode = .tunnels
  @State private var selection: UUID?
  @State private var profileSelection: UUID?
  @State private var settingsSection: SettingsSection? = .startup
  @State private var remoteSelection: String?
  @State private var confirmDelete = false
  @State private var importFlow = SecurePipesImportFlow()
  @State private var pendingChange: (() -> Void)?
  @State private var showUnsavedDialog = false

  init(initialSelection: UUID? = nil) {
    _selection = State(initialValue: initialSelection)
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
    } detail: {
      detail
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if mode == .tunnels, let id = selection, manager.tunnel(id) != nil {
          Button {
            manager.editorSave?()
            manager.toggle(id)
          } label: {
            Label(
              manager.status(of: id).isActive ? "Disconnect" : "Connect",
              systemImage: manager.status(of: id).isActive ? "stop.fill" : "play.fill"
            )
          }
          .labelStyle(.titleAndIcon)
          .help(manager.status(of: id).isActive ? "Disconnect this tunnel" : "Save and connect this tunnel")
        }
        Button {
          requestChange { mode = .settings }
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .labelStyle(.titleAndIcon)
        .help("Launch at login, import and storage")
      }
    }
    .modifier(SecurePipesImportDialogs(flow: importFlow))
    .confirmationDialog("You have unsaved changes.", isPresented: $showUnsavedDialog, titleVisibility: .visible) {
      Button("Save Changes") {
        manager.editorSave?()
        applyPendingChange()
      }
      Button("Discard Changes", role: .destructive) {
        manager.editorDiscard?()
        applyPendingChange()
      }
      Button("Cancel", role: .cancel) { pendingChange = nil }
    } message: {
      Text("Save them before switching, or discard them.")
    }
    .onAppear(perform: consumePending)
    .onChange(of: manager.pendingSelection) { consumePending() }
    .onChange(of: manager.pendingProfileSelection) { consumePending() }
    .onChange(of: manager.pendingMode) { consumePending() }
    .frame(minWidth: 880, minHeight: 600)
  }

  /// Runs a navigation change now, or after the user decides what to do with unsaved edits.
  private func requestChange(_ change: @escaping () -> Void) {
    guard manager.editorHasChanges else {
      change()
      return
    }
    pendingChange = change
    showUnsavedDialog = true
  }

  private func applyPendingChange() {
    let change = pendingChange
    pendingChange = nil
    manager.clearEditorSession()
    change?()
  }

  private func guarded<T: Equatable>(_ value: Binding<T>) -> Binding<T> {
    Binding(get: { value.wrappedValue }, set: { new in
      guard new != value.wrappedValue else { return }
      requestChange { value.wrappedValue = new }
    })
  }

  /// The popover and the editors ask for a specific tunnel, profile or mode through the manager.
  private func consumePending() {
    if let id = manager.pendingSelection {
      manager.pendingSelection = nil
      requestChange {
        mode = .tunnels
        selection = id
      }
    }
    if let id = manager.pendingProfileSelection {
      manager.pendingProfileSelection = nil
      requestChange {
        mode = .profiles
        profileSelection = id
      }
    }
    if let wanted = manager.pendingMode {
      manager.pendingMode = nil
      requestChange { mode = wanted }
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      Picker("", selection: guarded($mode)) {
        ForEach(SidebarMode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      switch mode {
      case .tunnels: tunnelList
      case .profiles: profileList
      case .cloudflare: RemoteTunnelSidebar(selection: $remoteSelection)
      case .settings: settingsList
      }
    }
    .navigationSplitViewColumnWidth(min: 290, ideal: 310, max: 420)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if mode == .tunnels || mode == .profiles {
        bottomBar
      }
    }
    .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Remove", role: .destructive, action: deleteSelected)
    } message: {
      Text(deleteMessage)
    }
  }

  private var tunnelList: some View {
    List(selection: guarded($selection)) {
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
            .contextMenu {
              Button(manager.status(of: tunnel.id).isActive ? "Disconnect" : "Connect") { manager.toggle(tunnel.id) }
              Button("Duplicate") {
                if let copy = manager.duplicate(tunnel.id) { requestChange { selection = copy.id } }
              }
              Divider()
              Button("Remove…", role: .destructive) {
                requestChange {
                  selection = tunnel.id
                  confirmDelete = true
                }
              }
            }
          }
        }
      }
    }
  }

  private var profileList: some View {
    List(selection: guarded($profileSelection)) {
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
        .contextMenu {
          Button("Remove…", role: .destructive) {
            requestChange {
              profileSelection = profile.id
              confirmDelete = true
            }
          }
        }
      }
      if manager.profiles.isEmpty {
        Text("Profiles bundle a server's host, user, key and secrets so several tunnels can share them.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var settingsList: some View {
    List(selection: $settingsSection) {
      ForEach(SettingsSection.allCases) { section in
        Label(section.rawValue, systemImage: section.systemImage)
          .padding(.vertical, 2)
          .tag(section)
      }
    }
  }

  private var bottomBar: some View {
    HStack(spacing: 8) {
      Button(action: addItem) {
        Label(mode == .tunnels ? "New Tunnel" : "New Profile", systemImage: "plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .help(mode == .tunnels ? "Create a new tunnel" : "Create a new profile")
      if mode == .tunnels {
        SidebarIconButton(systemImage: "doc.on.doc", help: "Duplicate the selected tunnel", disabled: selection == nil) {
          if let id = selection, let copy = manager.duplicate(id) { requestChange { selection = copy.id } }
        }
      }
      SidebarIconButton(
        systemImage: "trash",
        help: mode == .tunnels ? "Remove the selected tunnel" : "Remove the selected profile",
        disabled: currentSelection == nil,
        destructive: true
      ) {
        confirmDelete = true
      }
    }
    .controlSize(.regular)
    .padding(10)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }

  private var currentSelection: UUID? {
    mode == .tunnels ? selection : profileSelection
  }

  private func addItem() {
    requestChange {
      switch mode {
      case .tunnels: selection = manager.add().id
      case .profiles: profileSelection = manager.addProfile().id
      case .cloudflare, .settings: break
      }
    }
  }

  private var deleteTitle: String {
    switch mode {
    case .tunnels: return "Remove “\(selection.flatMap(manager.tunnel)?.name ?? "")”?"
    case .profiles: return "Remove profile “\(profileSelection.flatMap(manager.profile)?.name ?? "")”?"
    case .cloudflare, .settings: return ""
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
    case .cloudflare, .settings:
      return ""
    }
  }

  private func deleteSelected() {
    manager.clearEditorSession()
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
    case .cloudflare, .settings:
      break
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch mode {
    case .tunnels:
      if let id = selection, let tunnel = manager.tunnel(id) {
        TunnelEditorView(tunnel: tunnel)
          .id(id)
      } else {
        ContentUnavailableView {
          Label("No Tunnel Selected", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
          Text(manager.tunnels.isEmpty
            ? "Add a tunnel with the New Tunnel button, or import your Secure Pipes connections."
            : "Select a tunnel to edit it.")
        } actions: {
          if manager.tunnels.isEmpty && SecurePipesImporter.isAvailable() {
            Button { importFlow.begin(manager: manager) } label: {
              Label("Import from Secure Pipes", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
    case .profiles:
      if let id = profileSelection, let profile = manager.profile(id) {
        ProfileEditorView(profile: profile)
          .id(id)
      } else {
        ContentUnavailableView {
          Label("No Profile Selected", systemImage: "person.badge.key")
        } description: {
          Text("A profile is a server plus its credentials. Tunnels that use it share the host, user, key and secrets.")
        }
      }
    case .cloudflare:
      RemoteTunnelDetail(selection: $remoteSelection)
    case .settings:
      SettingsView(section: settingsSection ?? .startup)
    }
  }
}

/// A square bordered icon button for the sidebar action bar, with a tooltip and a hover highlight.
private struct SidebarIconButton: View {
  let systemImage: String
  let help: String
  var disabled = false
  var destructive = false
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 30, height: 22)
        .foregroundStyle(destructive && hovering && !disabled ? Color.red : Color.primary)
    }
    .buttonStyle(.bordered)
    .disabled(disabled)
    .onHover { hovering = $0 }
    .help(help)
  }
}

/// The bar shown under an editor while it has unsaved changes.
struct UnsavedChangesBar: View {
  let revert: () -> Void
  let save: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "pencil.circle.fill")
        .foregroundStyle(.orange)
      Text("Unsaved changes")
        .foregroundStyle(.secondary)
      Spacer()
      Button { revert() } label: { Label("Revert", systemImage: "arrow.uturn.backward") }
        .buttonStyle(.bordered)
        .help("Throw away the edits and go back to the saved version")
      Button { save() } label: { Label("Save", systemImage: "checkmark").frame(minWidth: 64) }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("s")
        .help("Save the changes (Command-S). Connected tunnels reconnect with the new settings.")
    }
    .padding(10)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}
