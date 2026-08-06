import AppKit
import SwiftUI

private final class SelectionEventBox: @unchecked Sendable {
    let event: NSEvent
    var shouldConsume = false

    init(_ event: NSEvent) {
        self.event = event
    }
}

struct NativeTableSelectionBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.startObserving(in: view)
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {}

    static func dismantleNSView(_ nsView: PassthroughView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        private weak var observedView: NSView?
        private var eventMonitor: Any?
        private var selectionAnchor: Int?

        func startObserving(in view: NSView) {
            observedView = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let eventBox = SelectionEventBox(event)

                MainActor.assumeIsolated {
                    guard let self,
                          let observedView = self.observedView,
                          eventBox.event.window === observedView.window else { return }

                    let location = observedView.convert(eventBox.event.locationInWindow, from: nil)
                    guard observedView.bounds.contains(location),
                          let tableView = self.tableView(at: eventBox.event.locationInWindow),
                          tableView.row(at: tableView.convert(eventBox.event.locationInWindow, from: nil)) >= 0
                    else { return }

                    let row = tableView.row(at: tableView.convert(eventBox.event.locationInWindow, from: nil))
                    let modifiers = eventBox.event.modifierFlags.intersection([.command, .shift])
                    guard !modifiers.isEmpty else {
                        self.selectionAnchor = row
                        return
                    }

                    tableView.window?.makeFirstResponder(tableView)
                    if modifiers.contains(.shift) {
                        let anchor = self.selectionAnchor
                            ?? (tableView.selectedRow >= 0 ? tableView.selectedRow : row)
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
                        self.selectionAnchor = row
                    }
                    eventBox.shouldConsume = true
                }

                return eventBox.shouldConsume ? nil : event
            }
        }

        func stopObserving() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
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
