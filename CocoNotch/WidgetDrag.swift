import SwiftUI
import UniformTypeIdentifiers

/// A private, undeclared type for dragging widgets (tabs and Home cards): nothing outside CocoNotch offers it, so other apps' drops are ignored.
let widgetDragType = UTType(tag: "coconotch-widget", tagClass: .filenameExtension, conformingTo: .data) ?? .data

struct DraggableWidget: ViewModifier {
    let id: String
    let isDraggable: Bool
    let onStart: () -> Void

    func body(content: Content) -> some View {
        if isDraggable {
            content.onDrag {
                onStart()
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

/// Proposes a move, so the cursor shows a plain reorder instead of the "+" of copying into a drop zone.
struct WidgetDropDelegate: DropDelegate {
    let targetID: String
    @Binding var dropTargetID: String?
    let perform: () -> Bool

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
        return perform()
    }
}
