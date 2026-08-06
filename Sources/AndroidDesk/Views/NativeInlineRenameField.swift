import AppKit
import SwiftUI

struct NativeInlineRenameField: NSViewRepresentable {
    let initialText: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> InlineTextField {
        let textField = InlineTextField(string: initialText)
        textField.delegate = context.coordinator
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .squareBezel
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.textColor = .controlTextColor
        textField.isEditable = true
        textField.isSelectable = true
        textField.focusRingType = .exterior
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        return textField
    }

    func updateNSView(_ nsView: InlineTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var didFinish = false

        init(
            onCommit: @escaping (String) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !didFinish,
                  let textField = notification.object as? NSTextField else { return }
            didFinish = true

            let movement = notification.userInfo?[NSText.movementUserInfoKey] as? NSNumber
            if movement?.intValue == NSTextMovement.cancel.rawValue {
                onCancel()
            } else {
                onCommit(textField.stringValue)
            }
        }
    }

    @MainActor
    final class InlineTextField: NSTextField {
        private var didRequestFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !didRequestFocus else { return }
            didRequestFocus = true
            window?.makeFirstResponder(self)
            selectFilenameStem()
        }

        private func selectFilenameStem() {
            let value = stringValue as NSString
            let extensionLength = value.pathExtension.utf16.count
            let stemLength = value.length - extensionLength - (extensionLength > 0 ? 1 : 0)
            let selectionLength = stemLength > 0 ? stemLength : value.length
            currentEditor()?.selectedRange = NSRange(location: 0, length: selectionLength)
        }
    }
}
