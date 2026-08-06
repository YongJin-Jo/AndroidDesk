import AppKit
import QuartzCore
import SwiftUI

struct NativeSkeletonPulseView: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> PulsingPlaceholderView {
        PulsingPlaceholderView(cornerRadius: cornerRadius)
    }

    func updateNSView(_ nsView: PulsingPlaceholderView, context: Context) {
        nsView.updateAppearance(cornerRadius: cornerRadius)
    }

    @MainActor
    final class PulsingPlaceholderView: NSView {
        private static let animationKey = "AndroidDeskSkeletonPulse"

        override var isFlipped: Bool { true }

        init(cornerRadius: CGFloat) {
            super.init(frame: .zero)
            wantsLayer = true
            updateAppearance(cornerRadius: cornerRadius)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                layer?.removeAnimation(forKey: Self.animationKey)
            } else {
                startPulsingIfNeeded()
            }
        }

        func updateAppearance(cornerRadius: CGFloat) {
            layer?.backgroundColor = NSColor.placeholderTextColor.withAlphaComponent(0.5).cgColor
            layer?.cornerRadius = cornerRadius
            startPulsingIfNeeded()
        }

        private func startPulsingIfNeeded() {
            guard layer?.animation(forKey: Self.animationKey) == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 0.85
            pulse.duration = 0.75
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: Self.animationKey)
        }
    }
}
