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

    func makeCoordinator() -> Coordinator {
        Coordinator(dragWriters: dragWriters)
    }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.startObserving(in: view)
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.dragWriters = dragWriters
    }

    static func dismantleNSView(_ nsView: PassthroughView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, NSDraggingSource {
        var dragWriters: (IndexSet) -> [any NSPasteboardWriting]
        private weak var observedView: NSView?
        private var eventMonitor: Any?
        private var selectionAnchor: Int?
        private var mouseDownRow: Int?
        private var didStartDragging = false

        init(dragWriters: @escaping (IndexSet) -> [any NSPasteboardWriting]) {
            self.dragWriters = dragWriters
        }

        func startObserving(in view: NSView) {
            observedView = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
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

        private func handle(_ eventBox: TableEventBox) {
            let event = eventBox.event
            guard let observedView,
                  event.window === observedView.window,
                  observedView.bounds.contains(observedView.convert(event.locationInWindow, from: nil)),
                  let tableView = tableView(at: event.locationInWindow) else { return }

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
                let draggingItems = zip(writers, rowIndexes).map { writer, rowIndex in
                    let item = NSDraggingItem(pasteboardWriter: writer)
                    let frame = tableView.rect(ofRow: rowIndex)
                    let image = NSImage(
                        systemSymbolName: "doc.on.doc",
                        accessibilityDescription: "파일 전송"
                    )
                    item.setDraggingFrame(frame, contents: image)
                    return item
                }
                tableView.beginDraggingSession(with: draggingItems, event: event, source: self)
                didStartDragging = true
                eventBox.shouldConsume = true

            case .leftMouseUp:
                mouseDownRow = nil
                didStartDragging = false

            default:
                break
            }
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

        private func tableView(at windowLocation: NSPoint) -> NSTableView? {
            guard let contentView = observedView?.window?.contentView,
                  let hitView = contentView.hitTest(windowLocation) else { return nil }

            var currentView: NSView? = hitView
            while let current = currentView {
                if let tableView = current as? NSTableView {
                    return tableView
                }
                currentView = current.superview
            }
            return nil
        }
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
