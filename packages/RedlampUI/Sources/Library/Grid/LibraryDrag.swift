import AppKit
import RedlampLibrary

/// Library's drags (LIB-21, LIB-23, LIB-26): photos from the grid onto a folder or a collection, and a keyword from
/// the Keyword List onto photos in the grid. Each is AppKit's dragging session, its pasteboard holding a type of
/// Redlamp's own that nothing outside it takes: a keyword's path, or for photos a token naming the drag, whose photos
/// stay in memory (`DraggedPhotos`), so a drag of 20,000 starts within a frame.
@MainActor
@_spi(Harness) public enum LibraryDrags {
    static let photos = NSPasteboard.PasteboardType("app.redlamp.library.photos")
    static let keyword = NSPasteboard.PasteboardType("app.redlamp.library.keyword")

    /// The photos being dragged, while they are.
    private(set) static var dragged: DraggedPhotos?
    /// The regression suite's drag, which its synthetic mouse moves.
    private(set) static var simulated: SimulatedDrag?

    /// Drags follow the regression suite's synthetic mouse, which the window server doesn't, rather than starting
    /// AppKit's session (`SimulatedDrag`).
    @_spi(Harness) public static var simulates = false
    /// The drop targets outlined under a drag since launch, for the regression suite.
    @_spi(Harness) public internal(set) static var outlined = 0

    /// Starts dragging `item` from `view`, which `event` pressed and moved: AppKit's session, or the suite's. `mask`
    /// is what the drag offers within Redlamp; outside it, nothing.
    static func begin(
        _ item: NSDraggingItem, event: NSEvent, from view: NSView & NSDraggingSource & LibraryDragSource,
        mask: NSDragOperation, photos: DraggedPhotos? = nil,
    ) {
        dragged = photos
        guard simulates, let window = view.window else {
            view.beginDraggingSession(with: [item], event: event, source: view)
            return
        }
        simulated = SimulatedDrag(item, from: view, in: window, mask: mask)
        simulated?.move(to: event.locationInWindow, modifiers: event.modifierFlags)
    }

    /// The suite's drag follows `event`, a drag or the release of the press that began it; true when it took it.
    static func follow(_ event: NSEvent) -> Bool {
        guard let drag = simulated else { return false }
        switch event.type {
        case .leftMouseDragged:
            drag.move(to: event.locationInWindow, modifiers: event.modifierFlags)
        case .leftMouseUp:
            simulated = nil
            drag.drop(at: event.locationInWindow, modifiers: event.modifierFlags)
        default:
            return false
        }
        return true
    }

    /// A drag from Library has ended, dropped or not.
    static func ended() {
        dragged = nil
    }

    /// The photos a drag's pasteboard names, while they're dragged.
    static func photos(in info: any NSDraggingInfo) -> DraggedPhotos? {
        guard let dragged, string(photos, in: info) == dragged.token else { return nil }
        return dragged
    }

    /// The keyword a drag's pasteboard holds.
    static func keyword(in info: any NSDraggingInfo) -> KeywordPath? {
        string(keyword, in: info).flatMap(KeywordPath.init)
    }

    /// The suite's drags keep their item in memory: the pasteboard server may not answer where it runs.
    private static func string(_ type: NSPasteboard.PasteboardType, in info: any NSDraggingInfo) -> String? {
        if let simulated = info as? SimulatedDraggingInfo {
            return simulated.item.string(forType: type)
        }
        return info.draggingPasteboard.string(forType: type)
    }

    /// What the operations a drag offers come to while `modifiers` are held, as AppKit has them: ⌥ copies, ⌘ leaves
    /// it to the destination, both link.
    static func operations(_ mask: NSDragOperation, holding modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
        switch (modifiers.contains(.option), modifiers.contains(.command)) {
        case (true, true): mask.intersection(.link)
        case (true, false): mask.intersection(.copy)
        case (false, true): mask.intersection(.generic)
        case (false, false): mask
        }
    }

    /// A drag image: `thumbnail` fitted into `size`, with `count`'s badge when it's more than one.
    static func image(_ thumbnail: CGImage?, size: CGSize, count: Int) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            if let thumbnail {
                let scale = min(rect.width / CGFloat(thumbnail.width), rect.height / CGFloat(thumbnail.height))
                let fitted = CGSize(width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale)
                NSImage(cgImage: thumbnail, size: fitted).draw(in: CGRect(
                    x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                    width: fitted.width, height: fitted.height,
                ), from: .zero, operation: .sourceOver, fraction: 0.85)
            } else {
                NSColor(white: 0.35, alpha: 0.85).setFill()
                rect.fill()
            }
            guard count > 1 else { return true }
            let text = NSAttributedString(string: count.formatted(), attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white,
            ])
            let size = text.size()
            let badge = CGRect(
                x: rect.maxX - size.width - 14, y: rect.maxY - size.height - 6,
                width: size.width + 12, height: size.height + 4,
            )
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
            text.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 2))
            return true
        }
    }
}

/// A view Library's drags start from, told when its drag ends, dropped or not.
@MainActor
protocol LibraryDragSource: AnyObject {
    func libraryDragEnded()
}

/// Photos dragged from the grid (LIB-23, LIB-26): the selection, or the photo pressed when it isn't selected, as the
/// grid listed them when the drag began. Their URLs and folders are worked out off the main thread, and a drop waits
/// for them.
@MainActor
final class DraggedPhotos {
    struct Listed: Sendable {
        var urls: [URL]
        /// The folders they're in, as `LibraryService.path` gives them.
        var folders: Set<String>
    }

    let token = UUID().uuidString
    let count: Int
    /// They're shown from the library, outside Recently Trashed, so they can move and go in collections.
    let fromLibrary: Bool
    private(set) var listed: Listed?
    private var listing: Task<Listed, Never>?

    init(photo: URL, fromLibrary: Bool) {
        count = 1
        self.fromLibrary = fromLibrary
        listed = Listed(urls: [photo], folders: [LibraryService.path(photo.deletingLastPathComponent())])
    }

    init(selection: PhotoSelection, items: [LibraryItem], ids: ContiguousArray<Int64>, fromLibrary: Bool) {
        count = selection.count
        self.fromLibrary = fromLibrary
        listing = Task {
            let listed = await Task.detached(priority: .userInitiated) {
                Self.list(selection, items: items, ids: ids)
            }.value
            self.listed = listed
            return listed
        }
    }

    /// The photos, in the grid's order.
    func urls() async -> [URL] {
        if let listed {
            return listed.urls
        }
        return await listing?.value.urls ?? []
    }

    private nonisolated static func list(
        _ selection: PhotoSelection, items: [LibraryItem], ids: ContiguousArray<Int64>,
    ) -> Listed {
        var urls: [URL] = []
        urls.reserveCapacity(selection.count)
        var folders = Set<String>()
        for (index, item) in zip(ids.indices, items) where selection.contains(ids[index]) {
            urls.append(item.url)
            folders.insert(item.folderPath)
        }
        let paths = folders.map { LibraryService.path(URL(fileURLWithPath: $0, isDirectory: true)) }
        return Listed(urls: urls, folders: Set(paths))
    }
}

/// A dragging session for the regression suite, whose synthetic mouse the window server doesn't follow: the
/// source's own drags and its release move it, and it tells the view under the pointer that takes its type what
/// AppKit's session would, through `NSDraggingDestination`, with an `NSDraggingInfo` of its own.
@MainActor
final class SimulatedDrag {
    private let info: SimulatedDraggingInfo
    private weak var source: (any LibraryDragSource)?
    private let window: NSWindow
    private let mask: NSDragOperation
    private var target: NSView?
    private var operation: NSDragOperation = []
    private static var sequence = 0

    init(_ item: NSDraggingItem, from source: NSView & LibraryDragSource, in window: NSWindow, mask: NSDragOperation) {
        Self.sequence += 1
        info = SimulatedDraggingInfo(
            item: item.item as? NSPasteboardItem ?? NSPasteboardItem(), source: source, window: window,
            sequence: Self.sequence,
        )
        self.source = source
        self.window = window
        self.mask = mask
    }

    func move(to location: NSPoint, modifiers: NSEvent.ModifierFlags) {
        info.location = location
        info.operations = LibraryDrags.operations(mask, holding: modifiers)
        let next = destination(at: location)
        if next !== target {
            target?.draggingExited(info)
            target = next
            operation = next?.draggingEntered(info) ?? []
        } else {
            operation = target?.draggingUpdated(info) ?? []
        }
    }

    func drop(at location: NSPoint, modifiers: NSEvent.ModifierFlags) {
        move(to: location, modifiers: modifiers)
        defer {
            source?.libraryDragEnded()
            LibraryDrags.ended()
        }
        guard let target else { return }
        guard !operation.isEmpty, target.prepareForDragOperation(info), target.performDragOperation(info) else {
            target.draggingExited(info)
            return
        }
        target.concludeDragOperation(info)
    }

    /// The view under `location` that takes the drag's types, or one of its superviews.
    private func destination(at location: NSPoint) -> NSView? {
        let types = Set(info.item.types)
        var view = window.contentView?.superview?.hitTest(location)
        while let current = view {
            if !current.isHiddenOrHasHiddenAncestor, !types.isDisjoint(with: current.registeredDraggedTypes) {
                return current
            }
            view = current.superview
        }
        return nil
    }
}

/// What `SimulatedDrag` tells destinations, its item kept in memory rather than on the drag pasteboard.
private final class SimulatedDraggingInfo: NSObject, NSDraggingInfo {
    let item: NSPasteboardItem
    let source: AnyObject
    weak var window: NSWindow?
    let sequence: Int
    var location = NSPoint.zero
    var operations: NSDragOperation = []
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(item: NSPasteboardItem, source: AnyObject, window: NSWindow, sequence: Int) {
        self.item = item
        self.source = source
        self.window = window
        self.sequence = sequence
    }

    var draggingDestinationWindow: NSWindow? {
        window
    }

    var draggingSourceOperationMask: NSDragOperation {
        operations
    }

    var draggingLocation: NSPoint {
        location
    }

    var draggedImageLocation: NSPoint {
        location
    }

    var draggedImage: NSImage? {
        nil
    }

    var draggingPasteboard: NSPasteboard {
        NSPasteboard(name: .drag)
    }

    var draggingSource: Any? {
        source
    }

    var draggingSequenceNumber: Int {
        sequence
    }

    var springLoadingHighlight: NSSpringLoadingHighlight {
        .none
    }

    func slideDraggedImage(to _: NSPoint) {}

    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions, for _: NSView?, classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any], using _: (
            NSDraggingItem,
            Int,
            UnsafeMutablePointer<ObjCBool>,
        ) -> Void,
    ) {}

    func resetSpringLoading() {}
}
