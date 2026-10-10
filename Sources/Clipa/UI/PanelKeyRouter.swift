import AppKit

/// What a key press in the panel should do.
enum PanelKeyAction: Equatable {
    case moveSelection(Int)
    case copySelected
    /// Leave the event to whatever has keyboard focus.
    case passThrough
}

/// Pure routing for the panel's key monitor.
///
/// The rule that matters: Return copies the selected clip whenever the panel —
/// not a text editor or an in-progress input-method composition — owns the key.
/// The search field must not swallow it: searching is live, so a Return that
/// only re-runs the search silently does nothing for the user.
struct PanelKeyRouter {
    /// A 备注 editor is open, so typing belongs to that field.
    var isTextEditorOpen: Bool
    /// An input method (Pinyin, Kana, …) is still composing in the focused
    /// field. Return commits the composition there and must not copy.
    var isComposingText: Bool

    func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> PanelKeyAction {
        if isTextEditorOpen { return .passThrough }
        if isComposingText { return .passThrough }
        switch keyCode {
        case 126: // ↑
            return .moveSelection(-1)
        case 125: // ↓
            return .moveSelection(1)
        case 36, 76: // return / enter
            return .copySelected
        default:
            return .passThrough
        }
    }
}
