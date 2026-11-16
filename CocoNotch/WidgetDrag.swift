import CocoNotchCore
import SwiftUI
import UniformTypeIdentifiers

/// A private, undeclared type for dragging widgets (tabs and Home cards): nothing outside CocoNotch offers it, so other
/// apps' drops are ignored.
let widgetDragType = UTType(tag: "coconotch-widget", tagClass: .filenameExtension, conformingTo: .data) ?? .data

/// The widget being dragged. One value for the tab bar and the Home cards, so a card can land on a tab and a tab on a
/// card. A drag that ends without a drop leaves it set, but only a new drag of ours can reach a drop, and that drag
/// sets it first.
private var draggedWidgetID: String?

struct DraggableWidget: ViewModifier {
    let id: String
    let isDraggable: Bool

    func body(content: Content) -> some View {
        if isDraggable {
            content.onDrag {
                draggedWidgetID = id
                let provider = NSItemProvider()
                let data = Data(id.utf8)
                // Visible only inside CocoNotch, so a widget can't be dropped into other apps either.
                provider.registerDataRepresentation(
                    forTypeIdentifier: widgetDragType.identifier, visibility: .ownProcess
                ) {
                    completion in
                    completion(data, nil)
                    return nil
                }
                return provider
            }
        } else {
            content
        }
    }
}

/// Moves the dragged widget onto `targetID` in the saved order. Proposes a move, so the cursor shows a plain reorder
/// instead of the "+" of copying into a drop zone.
struct WidgetDropDelegate: DropDelegate {
    let targetID: String
    @Binding var dropTargetID: String?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetID = nil
        guard let id = draggedWidgetID else { return false }
        draggedWidgetID = nil
        let defaults = UserDefaults.standard
        let preferences = NotchWidget.getPreferences(
            stored: defaults.string(forKey: PreferenceKey.widgetPreferences) ?? "")
        defaults.set(
            encodeWidgetPreferences(moveWidget(id, onto: targetID, in: preferences)),
            forKey: PreferenceKey.widgetPreferences
        )
        return true
    }
}
