import AppKit
import SwiftUI

private final class TableEventBox: @unchecked Sendable {
    let event: NSEvent
    var shouldConsume = false

    init(_ event: NSEvent) {
        self.event = event
    }
}

struct NativeFileTableBridge: NSViewRepresentable {
    let dragWriters: (IndexSet) -> [any NSPasteboardWriting]
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    var editingRow: Int? = nil
    var onCreateFolder: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            dragWriters: dragWriters,
            onDragBegan: onDragBegan,
            onDragEnded: onDragEnded,
            editingRow: editingRow,
            onCreateFolder: onCreateFolder
        )
    }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.startObserving(in: view)
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.dragWriters = dragWriters
        context.coordinator.onDragBegan = onDragBegan
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onCreateFolder = onCreateFolder
        context.coordinator.refreshEditingRow(editingRow)
    }

    static func dismantleNSView(_ nsView: PassthroughView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, NSDraggingSource {
        var dragWriters: (IndexSet) -> [any NSPasteboardWriting]
        var onDragBegan: () -> Void
        var onDragEnded: () -> Void
        var onCreateFolder: (() -> Void)?
        private var editingRow: Int?
        private weak var observedView: NSView?
        private weak var observedTableView: NSTableView?
        private var eventMonitor: Any?
        private var selectionAnchor: Int?
        private var mouseDownRow: Int?
        private var didStartDragging = false

        init(
            dragWriters: @escaping (IndexSet) -> [any NSPasteboardWriting],
            onDragBegan: @escaping () -> Void,
            onDragEnded: @escaping () -> Void,
            editingRow: Int?,
            onCreateFolder: (() -> Void)?
        ) {
            self.dragWriters = dragWriters
            self.onDragBegan = onDragBegan
            self.onDragEnded = onDragEnded
            self.editingRow = editingRow
            self.onCreateFolder = onCreateFolder
        }

        func startObserving(in view: NSView) {
            observedView = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                let eventBox = TableEventBox(event)
                MainActor.assumeIsolated {
                    self?.handle(eventBox)
                }
                return eventBox.shouldConsume ? nil : event
            }
        }

        func stopObserving() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            onDragEnded()
        }

        func refreshEditingRow(_ newEditingRow: Int?) {
            guard editingRow != newEditingRow else { return }
            let previousEditingRow = editingRow
            editingRow = newEditingRow
            guard let tableView = owningTableView() else { return }

            var rows = IndexSet()
            if let previousEditingRow,
               tableView.numberOfRows > previousEditingRow {
                rows.insert(previousEditingRow)
            }
            if let newEditingRow,
               tableView.numberOfRows > newEditingRow {
                rows.insert(newEditingRow)
            }
            guard !rows.isEmpty, tableView.numberOfColumns > 0 else { return }
            tableView.reloadData(
                forRowIndexes: rows,
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
            if let newEditingRow, tableView.numberOfRows > newEditingRow {
                tableView.scrollRowToVisible(newEditingRow)
            }
        }

        private func handle(_ eventBox: TableEventBox) {
            let event = eventBox.event
            guard let observedView,
                  event.window === observedView.window else { return }

            if event.type == .keyDown {
                handleCreateFolderShortcut(event, eventBox: eventBox)
                return
            }

            guard
                  observedView.bounds.contains(observedView.convert(event.locationInWindow, from: nil)),
                  !isTextEditingTarget(at: event.locationInWindow),
                  let tableView = tableView(at: event.locationInWindow) else { return }
            observedTableView = tableView

            let tableLocation = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: tableLocation)

            switch event.type {
            case .leftMouseDown:
                guard row >= 0 else { return }
                mouseDownRow = row
                didStartDragging = false
                handleSelection(at: row, event: event, tableView: tableView, eventBox: eventBox)

            case .leftMouseDragged:
                guard !didStartDragging,
                      let mouseDownRow,
                      mouseDownRow >= 0,
                      tableView.selectedRowIndexes.contains(mouseDownRow) else { return }
                let writers = dragWriters(tableView.selectedRowIndexes)
                guard !writers.isEmpty else { return }

                let rowIndexes = Array(tableView.selectedRowIndexes)
                guard let preview = dragPreview(for: rowIndexes, in: tableView) else { return }
                let leaderIndex = min(
                    rowIndexes.firstIndex(of: mouseDownRow) ?? 0,
                    writers.count - 1
                )
                let draggingItems = writers.enumerated().map { index, writer in
                    let item = NSDraggingItem(pasteboardWriter: writer)
                    item.setDraggingFrame(
                        preview.frame,
                        contents: index == leaderIndex ? preview.image : nil
                    )
                    return item
                }
                onDragBegan()
                let session = tableView.beginDraggingSession(
                    with: draggingItems,
                    event: event,
                    source: self
                )
                session.draggingFormation = .none
                session.draggingLeaderIndex = leaderIndex
                didStartDragging = true
                eventBox.shouldConsume = true

            case .leftMouseUp:
                mouseDownRow = nil
                didStartDragging = false

            case .rightMouseDown:
                guard row < 0, onCreateFolder != nil else { return }
                let menu = NSMenu()
                let item = NSMenuItem(
                    title: "새 폴더",
                    action: #selector(createFolderFromContextMenu),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
                NSMenu.popUpContextMenu(menu, with: event, for: tableView)
                eventBox.shouldConsume = true

            default:
                break
            }
        }

        @objc private func createFolderFromContextMenu() {
            onCreateFolder?()
        }

        private func handleCreateFolderShortcut(_ event: NSEvent, eventBox: TableEventBox) {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "n",
                  let tableView = owningTableView(),
                  isFirstResponder(inside: tableView),
                  onCreateFolder != nil else { return }
            onCreateFolder?()
            eventBox.shouldConsume = true
        }

        private func isFirstResponder(inside tableView: NSTableView) -> Bool {
            var responderView = tableView.window?.firstResponder as? NSView
            while let view = responderView {
                if view === tableView { return true }
                responderView = view.superview
            }
            return false
        }

        private func handleSelection(
            at row: Int,
            event: NSEvent,
            tableView: NSTableView,
            eventBox: TableEventBox
        ) {
            let modifiers = event.modifierFlags.intersection([.command, .shift])
            guard !modifiers.isEmpty else {
                selectionAnchor = row
                if !tableView.selectedRowIndexes.contains(row) {
                    tableView.window?.makeFirstResponder(tableView)
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                return
            }

            tableView.window?.makeFirstResponder(tableView)
            if modifiers.contains(.shift) {
                let anchor = selectionAnchor ?? (tableView.selectedRow >= 0 ? tableView.selectedRow : row)
                let lowerBound = min(anchor, row)
                let upperBound = max(anchor, row)
                var indexes = IndexSet(integersIn: lowerBound..<(upperBound + 1))
                if modifiers.contains(.command) {
                    indexes.formUnion(tableView.selectedRowIndexes)
                }
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            } else {
                var indexes = tableView.selectedRowIndexes
                if indexes.contains(row) {
                    indexes.remove(row)
                } else {
                    indexes.insert(row)
                }
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                selectionAnchor = row
            }
            eventBox.shouldConsume = true
        }

        private func dragPreview(
            for rowIndexes: [Int],
            in tableView: NSTableView
        ) -> (frame: NSRect, image: NSImage)? {
            let rowImages = rowIndexes.compactMap { rowIndex in
                tableView.rowView(atRow: rowIndex, makeIfNecessary: true).flatMap {
                    snapshot(of: $0)
                }
            }
            guard let firstRow = rowIndexes.first,
                  !rowImages.isEmpty else { return nil }

            let imageSize = NSSize(
                width: rowImages.map(\.size.width).max() ?? 0,
                height: rowImages.reduce(0) { $0 + $1.size.height }
            )
            let image = NSImage(size: imageSize)
            image.lockFocus()
            var y = imageSize.height
            for rowImage in rowImages {
                y -= rowImage.size.height
                rowImage.draw(
                    in: NSRect(
                        x: 0,
                        y: y,
                        width: rowImage.size.width,
                        height: rowImage.size.height
                    )
                )
            }
            image.unlockFocus()

            var frame = tableView.rect(ofRow: firstRow)
            frame.size = imageSize
            return (frame, image)
        }

        private func snapshot(of view: NSView) -> NSImage? {
            let bounds = view.bounds
            guard !bounds.isEmpty,
                  let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }

            view.cacheDisplay(in: bounds, to: representation)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(representation)
            return image
        }

        private func tableView(at windowLocation: NSPoint) -> NSTableView? {
            guard let contentView = observedView?.window?.contentView else { return nil }

            if let hitView = contentView.hitTest(windowLocation) {
                var currentView: NSView? = hitView
                while let current = currentView {
                    if let tableView = current as? NSTableView {
                        return tableView
                    }
                    currentView = current.superview
                }
            }
            return tableView(containing: windowLocation, in: contentView)
        }

        private func tableView(containing windowLocation: NSPoint, in view: NSView) -> NSTableView? {
            let location = view.convert(windowLocation, from: nil)
            guard !view.isHidden, view.bounds.contains(location) else { return nil }
            if let tableView = view as? NSTableView {
                return tableView
            }
            for subview in view.subviews.reversed() {
                if let tableView = tableView(containing: windowLocation, in: subview) {
                    return tableView
                }
            }
            return nil
        }

        private func owningTableView() -> NSTableView? {
            if let observedTableView {
                return observedTableView
            }
            var currentView = observedView?.superview
            while let current = currentView {
                if let tableView = current as? NSTableView {
                    return tableView
                }
                currentView = current.superview
            }
            return nil
        }

        private func isTextEditingTarget(at windowLocation: NSPoint) -> Bool {
            guard let contentView = observedView?.window?.contentView,
                  let hitView = contentView.hitTest(windowLocation) else { return false }

            var currentView: NSView? = hitView
            while let current = currentView {
                if current is NSTextField || current is NSTextView {
                    return true
                }
                currentView = current.superview
            }
            return false
        }
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
