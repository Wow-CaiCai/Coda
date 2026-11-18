#if os(macOS)
import SwiftUI
import QuartzCore

/// Keep SwiftUI and native surfaces at their final layout throughout presentation.
/// Only an AppKit-owned ancestor layer moves; native frames never need to catch up.
struct DesktopNowPlayingPresentation<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var onDismissed: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PlayerSurface { PlayerSurface() }

    func updateNSView(_ view: PlayerSurface, context: Context) {
        view.onDismissed = onDismissed
        view.update(isPresented: isPresented, reduceMotion: reduceMotion,
                    content: AnyView(content().environment(\.self, context.environment)))
    }

    static func dismantleNSView(_ view: PlayerSurface, coordinator: ()) {
        view.cancelPresentation()
    }

    final class PlayerSurface: NSView {
        private let surface = NSView()
        private var hosting: NSHostingView<AnyView>?
        private var presented = false
        private var generation = 0
        private var awaitingFirstLayout = false
        private var reduceMotion = false
        var onDismissed: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            surface.wantsLayer = true
            addSubview(surface)
            surface.isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            presented ? super.hitTest(point) : nil
        }

        override func layout() {
            super.layout()
            // Moving the ancestor layer never changes these layout frames.
            if surface.frame != bounds { surface.frame = bounds }
            if let hosting, hosting.frame != surface.bounds { hosting.frame = surface.bounds }
            if awaitingFirstLayout, bounds.height > 0, bounds.width > 0 {
                awaitingFirstLayout = false
                setModelPosition(y: reduceMotion ? 0 : -bounds.height,
                                 opacity: reduceMotion ? 0 : 1)
                hosting?.layoutSubtreeIfNeeded()
                let token = generation
                // Commit the fully laid-out starting surface before moving it.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.presented else { return }
                    self.animate(toPresented: true, token: token)
                }
            }
        }

        func update(isPresented: Bool, reduceMotion: Bool, content: AnyView) {
            self.reduceMotion = reduceMotion
            if let hosting { hosting.rootView = content }
            guard presented != isPresented else { return }
            presented = isPresented
            generation += 1
            let token = generation

            if isPresented, hosting == nil {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                hosting = host
                surface.addSubview(host)
                surface.isHidden = false
                awaitingFirstLayout = true
                needsLayout = true
                layoutSubtreeIfNeeded()
            } else if hosting != nil {
                awaitingFirstLayout = false
                animate(toPresented: isPresented, token: token)
            }
        }

        private func setModelPosition(y: CGFloat, opacity: Float) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer?.transform = CATransform3DMakeTranslation(0, y, 0)
            surface.layer?.opacity = opacity
            CATransaction.commit()
        }

        private func animate(toPresented: Bool, token: Int) {
            guard let layer = surface.layer else { return }
            let visible = layer.presentation() ?? layer
            let startY = visible.transform.m42
            let startOpacity = visible.opacity
            let endY: CGFloat = toPresented || reduceMotion ? 0 : -bounds.height
            let endOpacity: Float = reduceMotion && !toPresented ? 0 : 1
            setModelPosition(y: endY, opacity: endOpacity)

            let translation = CABasicAnimation(keyPath: "transform.translation.y")
            translation.fromValue = startY
            translation.toValue = endY
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = startOpacity
            opacity.toValue = endOpacity
            let animation = CAAnimationGroup()
            animation.animations = [translation, opacity]
            animation.duration = reduceMotion ? 0.2 : 0.42
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.generation == token, !self.presented else { return }
                self.surface.isHidden = true
                self.hosting?.removeFromSuperview()
                self.hosting = nil
                self.onDismissed?()
            }
            layer.add(animation, forKey: "playerPresentation")
            CATransaction.commit()
        }

        func cancelPresentation() {
            generation += 1
            surface.layer?.removeAllAnimations()
            onDismissed = nil
        }
    }
}
#endif
