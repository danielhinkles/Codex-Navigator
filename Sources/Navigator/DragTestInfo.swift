import AppKit

/// Destination fixture uses the pasteboard produced by the actual native source.
@MainActor final class DragTestInfo:NSObject,NSDraggingInfo {
    var draggingDestinationWindow:NSWindow?
    var draggingSourceOperationMask:NSDragOperation = .move
    var draggingLocation:NSPoint = .zero
    var draggedImageLocation:NSPoint = .zero
    nonisolated var draggedImage:NSImage? {nil}
    var draggingPasteboard:NSPasteboard
    var draggingSource:Any?
    var draggingSequenceNumber=1
    var draggingFormation:NSDraggingFormation = .none
    var animatesToDestination=false
    var numberOfValidItemsForDrop=1
    var springLoadingHighlight:NSSpringLoadingHighlight = .none
    init(window:NSWindow,source:NSView,pasteboard:NSPasteboard) {draggingDestinationWindow=window;draggingSource=source;draggingPasteboard=pasteboard}
    func slideDraggedImage(to:NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination:URL)->[String]? {nil}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions,for view:NSView?,classes:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
}
