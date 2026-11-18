import Foundation

/// Direction thresholds are independent of the scroll view's layout and safe-area changes.
struct LegacyTabScrollIntent {
    private var lastTranslation: CGFloat = 0
    private var travel: CGFloat = 0

    mutating func begin(at translation: CGFloat) {
        lastTranslation = translation
        travel = 0
    }

    mutating func update(translation: CGFloat, offset: CGFloat, top: CGFloat, bottom: CGFloat) -> Bool? {
        let delta = lastTranslation - translation
        lastTranslation = translation
        if offset <= top + 2 {
            travel = 0
            return false
        }
        guard offset <= bottom + 1 else { travel = 0; return nil }
        if delta * travel < 0 { travel = 0 }
        travel += delta
        if travel > 32 {
            travel = 0
            return true
        }
        if travel < -18 {
            travel = 0
            return false
        }
        return nil
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// Watch vertical scrolling without replacing scroll-view delegates or consuming touches.
/// Installed only by the pre-iOS-26 phone navigation shell.
struct LegacyTabScrollObserver: UIViewRepresentable {
    let enabled: Bool
    let onCollapseChanged: (Bool) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.enabled = enabled
        view.onCollapseChanged = onCollapseChanged
    }

    static func dismantleUIView(_ view: ObserverView, coordinator: Void) {
        view.detach()
    }

    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var enabled = false
        var onCollapseChanged: ((Bool) -> Void)?
        private weak var observedWindow: UIWindow?
        private weak var scrollView: UIScrollView?
        private var pan: UIPanGestureRecognizer?
        private var intent = LegacyTabScrollIntent()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panChanged(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            window.addGestureRecognizer(pan)
            self.pan = pan
            observedWindow = window
        }

        func detach() {
            if let pan { observedWindow?.removeGestureRecognizer(pan) }
            pan = nil
            observedWindow = nil
            scrollView = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            scrollView = nil
            guard enabled, window != nil,
                  observedWindow?.rootViewController?.presentedViewController == nil,
                  bounds.contains(convert(touch.location(in: observedWindow), from: observedWindow)) else { return false }
            var ancestor = touch.view
            while let view = ancestor {
                if let scroll = view as? UIScrollView,
                   !(scroll is UITextView),
                   scroll.isScrollEnabled,
                   scroll.contentSize.height + scroll.adjustedContentInset.top
                    + scroll.adjustedContentInset.bottom > scroll.bounds.height + 1 {
                    scrollView = scroll
                    return true
                }
                ancestor = view.superview
            }
            return false
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  scrollView != nil else { return false }
            let velocity = pan.velocity(in: observedWindow)
            return abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            guard enabled, let scroll = scrollView else { return }
            let translation = pan.translation(in: observedWindow).y
            switch pan.state {
            case .began:
                intent.begin(at: translation)
            case .changed:
                let top = -scroll.adjustedContentInset.top
                let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                if let collapsed = intent.update(translation: translation, offset: scroll.contentOffset.y,
                                                 top: top, bottom: bottom) {
                    onCollapseChanged?(collapsed)
                }
            default:
                intent.begin(at: translation)
            }
        }
    }
}
#endif
