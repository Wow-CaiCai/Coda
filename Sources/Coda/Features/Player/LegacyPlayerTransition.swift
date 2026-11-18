#if os(iOS)
import UIKit

/// Old iPads use one full-screen surface to avoid the system sheet's backdrop seam.
/// Supply explicit motion because this host no longer has the sheet's animator.
final class LegacyPlayerPresentationController: UIPresentationController {
    override var shouldRemovePresentersView: Bool { false }
    override var frameOfPresentedViewInContainerView: CGRect { containerView?.bounds ?? .zero }

    private(set) var backdropSurface: UIView?
    var onDismissalEnd: ((Bool) -> Void)?

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        guard let container = containerView else { return }
        container.backgroundColor = .black
        let source = presentingViewController.view.window?.rootViewController?.view
            ?? presentingViewController.view!
        guard let snapshot = source.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = container.bounds
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        snapshot.layer.masksToBounds = true
        container.insertSubview(snapshot, at: 0)
        backdropSurface = snapshot
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        if !completed { backdropSurface?.removeFromSuperview(); backdropSurface = nil }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        if completed { backdropSurface?.removeFromSuperview(); backdropSurface = nil }
        onDismissalEnd?(completed)
    }

    /// Preview a handle drag without entering UIKit's dismissal lifecycle.
    /// A cancelled preview restores geometry only; the hosting view stays active.
    func updatePlayerDrag(translation: CGFloat) {
        guard let surface = presentedView else { return }
        let progress = min(1, max(0, translation) / max(1, surface.bounds.height))
        let reduced = UIAccessibility.isReduceMotionEnabled
        surface.transform = reduced ? .identity : CGAffineTransform(translationX: 0, y: max(0, translation))
        surface.alpha = reduced ? 1 - progress : 1
        let scale = reduced ? 1 : 0.94 + 0.06 * progress
        backdropSurface?.transform = CGAffineTransform(scaleX: scale, y: scale)
        backdropSurface?.layer.cornerRadius = reduced ? 0 : 16 * (1 - progress)
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        let frame = frameOfPresentedViewInContainerView
        // A snapshot taken before rotation would show the old browsing layout
        // during dismissal. The presenter stays in the hierarchy and relayouts.
        if let backdropSurface, backdropSurface.bounds.size != frame.size {
            backdropSurface.removeFromSuperview()
            self.backdropSurface = nil
            containerView?.backgroundColor = .clear
        }
        // Frame assignment is undefined while the transition applies a transform.
        // Updating bounds/center preserves the running slide during layout callbacks.
        guard let surface = presentedView else { return }
        let bounds = CGRect(origin: .zero, size: frame.size)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if surface.bounds != bounds { surface.bounds = bounds }
        if surface.center != center { surface.center = center }
    }
}

final class LegacyPlayerTransition: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool
    private var animator: UIViewPropertyAnimator?

    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.2 : (presenting ? 0.52 : 0.38)
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: context).startAnimation()
    }

    func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
        // Return one animator for the entire UIKit transition.
        if let animator { return animator }
        let key: UITransitionContextViewKey = presenting ? .to : .from
        let controllerKey: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let surface = context.view(forKey: key),
              let controller = context.viewController(forKey: controllerKey) else {
            context.completeTransition(false)
            return UIViewPropertyAnimator(duration: 0, curve: .linear)
        }
        let container = context.containerView
        if presenting {
            surface.frame = context.finalFrame(for: controller)
            container.addSubview(surface)
            surface.layoutIfNeeded()
        }
        let reduced = UIAccessibility.isReduceMotionEnabled
        let offset = CGAffineTransform(translationX: 0, y: container.bounds.height)
        if presenting {
            surface.transform = reduced ? .identity : offset
            surface.alpha = reduced ? 0 : 1
        }
        let backdrop = (controller.presentationController as? LegacyPlayerPresentationController)?.backdropSurface
        let collapsed = CGAffineTransform(scaleX: 0.94, y: 0.94)
        let diagnostics = LegacyPlayerTransitionDiagnostics(surface: surface, backdrop: backdrop,
            height: container.bounds.height, presenting: presenting)
        diagnostics.start()
        let animations = {
            backdrop?.transform = self.presenting && !reduced ? collapsed : .identity
            backdrop?.layer.cornerRadius = self.presenting && !reduced ? 16 : 0
            surface.transform = reduced || self.presenting ? .identity : offset
            surface.alpha = reduced && !self.presenting ? 0 : 1
        }
        let duration = transitionDuration(using: context)
        let animator: UIViewPropertyAnimator
        if presenting && !reduced {
            animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.92, animations: animations)
        } else {
            // Linear scrubbing keeps the surface aligned with the finger.
            animator = UIViewPropertyAnimator(duration: duration,
                curve: context.isInteractive ? .linear : .easeInOut, animations: animations)
        }
        self.animator = animator
        animator.addCompletion { _ in
            let completed = !context.transitionWasCancelled
            if !completed {
                surface.transform = .identity
                surface.alpha = 1
                backdrop?.transform = self.presenting ? .identity : collapsed
                backdrop?.layer.cornerRadius = self.presenting ? 0 : 16
            }
            diagnostics.finish(completed: completed, cancelled: context.transitionWasCancelled)
            context.completeTransition(completed)
        }
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) {
        animator = nil
    }
}

/// Enabled only by UI-test launch environment; samples real presentation layers.
private final class LegacyPlayerTransitionDiagnostics: NSObject {
    private weak var surface: UIView?
    private weak var backdrop: UIView?
    private let height: CGFloat
    private let presenting: Bool
    private var link: CADisplayLink?
    private var samples = 0
    private var intermediate = 0
    private var minimumScale: CGFloat = 1

    init(surface: UIView, backdrop: UIView?, height: CGFloat, presenting: Bool) {
        self.surface = surface; self.backdrop = backdrop
        self.height = height; self.presenting = presenting
    }

    func start() {
        guard ProcessInfo.processInfo.environment["CODA_PLAYER_TRANSITION_DIAGNOSTICS"] == "1" else { return }
        let link = CADisplayLink(target: self, selector: #selector(sample))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func sample() {
        guard let surface else { return }
        samples += 1
        if let layer = surface.layer.presentation(), layer.frame.minY > 1, layer.frame.minY < height - 1 {
            intermediate += 1
        }
        if let layer = backdrop?.layer.presentation() {
            minimumScale = min(minimumScale, layer.transform.m11)
        }
    }

    func finish(completed: Bool, cancelled: Bool) {
        guard let link else { return }
        sample(); link.invalidate(); self.link = nil
        guard let window = surface?.window,
              let data = try? JSONSerialization.data(withJSONObject: [
                "phase": presenting ? "present" : "dismiss", "samples": samples,
                "intermediate": intermediate, "minimumScale": minimumScale,
                "completed": completed, "cancelled": cancelled,
                "reducedMotion": UIAccessibility.isReduceMotionEnabled
              ]), let summary = String(data: data, encoding: .utf8) else { return }
        let identifier = "legacyPlayerTransitionDiagnostics"
        let label = (window.subviews.first { $0.accessibilityIdentifier == identifier } as? UILabel) ?? UILabel()
        label.frame = CGRect(x: 0, y: window.bounds.height - 1, width: 1, height: 1)
        label.textColor = .clear
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = identifier
        label.text = summary
        if label.superview == nil { window.addSubview(label) }
    }
}
#endif
