import SwiftUI

/// Whether a row is fully checked, unchecked, or partially checked because
/// only some of what it contains is. Shared by the library tree (artists and
/// albums) and the playlist list, which is why it isn't nested in either
/// store — `MusicLibraryStore.CheckState` is a typealias onto this.
enum SelectionCheckState: Equatable { case off, on, mixed }

/// A button that cycles between on / off (and can also display a "mixed" state
/// driven by the parent). Tap calls `toggle` — the parent decides what that
/// means (e.g. mixed → on).
struct TristateCheckbox: View {
    let state: SelectionCheckState
    /// Shown, but not changeable — the state is being decided elsewhere. Used
    /// when the sync mode is "Entire music library", and for a track a checked
    /// playlist requires. A checkbox that silently ignored the click would be
    /// worse than one that visibly can't be clicked.
    var locked: Bool = false
    var lockReason: String? = nil
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(locked)
        .opacity(locked ? 0.55 : 1)
        .help(lockReason ?? "")
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        switch state {
        case .off: "square"
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .off: "Not selected"
        case .on: "Selected"
        case .mixed: "Some tracks selected"
        }
    }
}
