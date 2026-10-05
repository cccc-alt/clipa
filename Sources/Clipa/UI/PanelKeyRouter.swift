import AppKit

enum PanelKeyAction: Equatable {
    case moveSelection(Int)
    case copySelected

    case passThrough
}

struct PanelKeyRouter {

    var isTextEditorOpen: Bool

    var isComposingText: Bool

    func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> PanelKeyAction {
        if isTextEditorOpen { return .passThrough }
        if isComposingText { return .passThrough }
        switch keyCode {
        case 126:
            return .moveSelection(-1)
        case 125:
            return .moveSelection(1)
        case 36, 76:
            return .copySelected
        default:
            return .passThrough
        }
    }
}
