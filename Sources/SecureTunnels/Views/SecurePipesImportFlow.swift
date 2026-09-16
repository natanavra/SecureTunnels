import SwiftUI
import SecureTunnelsCore

/// Runs a Secure Pipes import with a confirmation first. Adding is the default; overwriting tunnels that were
/// imported before is a separate, clearly destructive choice.
@MainActor
@Observable
final class SecurePipesImportFlow {
  var preview: ImportPreview?
  var message: String?

  func begin(manager: TunnelManager) {
    do {
      let found = try manager.previewSecurePipesImport()
      if found.new.isEmpty && found.existing.isEmpty {
        message = "No connections were found in the Secure Pipes configuration."
        return
      }
      preview = found
    } catch {
      message = "Import failed: \(error.localizedDescription)"
    }
  }

  func run(manager: TunnelManager, overwrite: Bool) {
    preview = nil
    do {
      let summary = try manager.importFromSecurePipes(overwriteExisting: overwrite)
      var parts: [String] = []
      if summary.added > 0 { parts.append("added \(summary.added) new") }
      if summary.updated > 0 { parts.append("overwrote \(summary.updated) existing") }
      if summary.skipped > 0 { parts.append("left \(summary.skipped) existing unchanged") }
      let secrets = summary.added + summary.updated > 0
        ? " Key passphrases and passwords are not carried over, so enter them in each tunnel and press Save." : ""
      message = "Import " + parts.joined(separator: ", ") + "." + secrets
    } catch {
      message = "Import failed: \(error.localizedDescription)"
    }
  }

  var dialogMessage: String {
    guard let preview else { return "" }
    var lines: [String] = []
    if !preview.new.isEmpty {
      lines.append("\(preview.new.count) connection(s) are new and will be added.")
    }
    if !preview.existing.isEmpty {
      lines.append("\(preview.existing.count) connection(s) were imported before. Adding keeps their current "
        + "settings. Overwriting replaces their host, ports and options with the Secure Pipes values and "
        + "cannot be undone; groups, profile links and saved secrets are kept.")
    }
    lines.append("No tunnel is ever removed by an import.")
    return lines.joined(separator: "\n\n")
  }
}

struct SecurePipesImportDialogs: ViewModifier {
  @Environment(TunnelManager.self) private var manager
  @Bindable var flow: SecurePipesImportFlow

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "Import from Secure Pipes?",
        isPresented: Binding(get: { flow.preview != nil }, set: { if !$0 { flow.preview = nil } }),
        titleVisibility: .visible
      ) {
        if let preview = flow.preview {
          if !preview.new.isEmpty {
            Button("Add \(preview.new.count) New") { flow.run(manager: manager, overwrite: false) }
          }
          if !preview.existing.isEmpty {
            Button(preview.new.isEmpty
              ? "Overwrite \(preview.existing.count) Existing"
              : "Add New and Overwrite \(preview.existing.count) Existing", role: .destructive) {
              flow.run(manager: manager, overwrite: true)
            }
          }
          Button("Cancel", role: .cancel) { flow.preview = nil }
        }
      } message: {
        Text(flow.dialogMessage)
      }
      .alert("Secure Pipes Import", isPresented: Binding(get: { flow.message != nil }, set: { if !$0 { flow.message = nil } })) {
        Button("OK") { flow.message = nil }
      } message: {
        Text(flow.message ?? "")
      }
  }
}
