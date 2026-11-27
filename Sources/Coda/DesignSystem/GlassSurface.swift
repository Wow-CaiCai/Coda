import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One material recipe for navigation and playback chrome on every platform.
/// Native Liquid Glass owns its lighting on OS 26+. Older systems use a live
/// backdrop material with a translucent face and directional edge highlights.
enum GlassSurfaceStyle {
    static let lightFaceOpacity = 0.10
    static let darkFaceOpacity = 0.14
    static let lightHighlightOpacity = 0.58
    static let darkHighlightOpacity = 0.28

    static func faceOpacity(dark: Bool) -> Double {
        dark ? darkFaceOpacity : lightFaceOpacity
    }

    static func highlightOpacity(dark: Bool) -> Double {
        dark ? darkHighlightOpacity : lightHighlightOpacity
    }
}

/// Fallback glass for systems without `glassEffect`. `light` is where the
/// pointer or finger is, in the surface's own coordinates; `glow` (0...1)
/// fades the spot and the edge lighting that follows it.
struct LegacyGlassBackground<S: Shape>: View {
    let shape: S
    var light: CGPoint?
    var glow: Double = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        surface
            .overlay {
                shape.fill((dark ? Color.black : .white)
                    .opacity(GlassSurfaceStyle.faceOpacity(dark: dark)))
            }
            .overlay {
                shape.fill(LinearGradient(
                    colors: [.white.opacity(dark ? 0.07 : 0.18), .white.opacity(0.01),
                             .black.opacity(dark ? 0.06 : 0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { spotlight(dark: dark) }
            .overlay {
                // Keep the edge inside the surface even for a capsule or circle.
                shape.stroke(LinearGradient(
                    colors: [.white.opacity(GlassSurfaceStyle.highlightOpacity(dark: dark)),
                             .white.opacity(dark ? 0.04 : 0.10),
                             .white.opacity(dark ? 0.14 : 0.30)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .clipShape(shape)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var surface: some View {
        #if os(macOS)
        // The fallback is used on macOS 15. A live backdrop across the
        // full-height floating sidebar makes native window transforms sample
        // and blur the desktop repeatedly, and AppKit's material is far more
        // diffused and grey than iOS's. Keep this surface self-contained.
        shape.fill(Color(nsColor: .windowBackgroundColor))
        #else
        shape.fill(.ultraThinMaterial)
        #endif
    }

    /// Light gathers under the touch and lights the nearby rim. Nothing is
    /// drawn at rest, so idle chrome costs no extra layers.
    @ViewBuilder
    private func spotlight(dark: Bool) -> some View {
        if let light, glow > 0.001 {
            GeometryReader { proxy in
                let size = proxy.size
                let radius = max(44, min(max(size.width, size.height), 260) * 0.55)
                ZStack {
                    shape.fill(RadialGradient(
                        colors: [.white.opacity((dark ? 0.16 : 0.30) * glow), .white.opacity(0)],
                        center: .init(x: light.x / max(size.width, 1), y: light.y / max(size.height, 1)),
                        startRadius: 0, endRadius: radius))
                    shape.stroke(RadialGradient(
                        colors: [.white.opacity((dark ? 0.55 : 0.90) * glow), .white.opacity(0)],
                        center: .init(x: light.x / max(size.width, 1), y: light.y / max(size.height, 1)),
                        startRadius: 0, endRadius: radius * 1.1), lineWidth: 1.5)
                        .clipShape(shape)
                }
            }
        }
    }
}

/// Liquid Glass reacts to touch: the control swells and squashes toward the
/// finger and its light follows it, then springs back. Older systems get the
/// same response here. Large chrome (sidebar, dock) only lets the light follow
/// the pointer; deforming a whole sidebar would read as a glitch.
struct LegacyGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @State private var light: CGPoint?
    @State private var hovering = false
    @State private var size: CGSize = .zero
    #if os(macOS)
    @StateObject private var press = GlassPressMonitor()
    private var pressed: Bool { press.pressed }
    private var stretch: CGSize { press.stretch }
    #else
    @State private var pressed = false
    @State private var stretch: CGSize = .zero
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var glow: Double { pressed ? 1 : (hovering ? 0.45 : 0) }

    /// Only button-sized glass reacts to presses. Some interactive surfaces
    /// are whole panels with lists inside; those must not squash or track drags.
    private var respondsToPress: Bool {
        #if os(macOS)
        // On iOS 16–25 a zero-distance drag on a control inside a scroll view
        // can hold up scrolling; keep the press response to the pointer platform.
        return interactive && size.width > 0 && max(size.width, size.height) <= 160
        #else
        return false
        #endif
    }

    func body(content: Content) -> some View {
        content
            .background {
                LegacyGlassBackground(shape: shape, light: light, glow: glow)
                    .animation(.easeOut(duration: 0.18), value: glow)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .modifier(PressDeformation(active: respondsToPress && !reduceMotion, pressed: pressed, stretch: stretch))
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    light = point
                    hovering = true
                case .ended:
                    hovering = false
                }
                press.track(hovering: hovering && respondsToPress)
            }
            .onDisappear { press.track(hovering: false) }
            #else
            .simultaneousGesture(pressTracking, including: respondsToPress ? .all : .subviews)
            #endif
    }

    #if !os(macOS)
    private var pressTracking: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                light = value.location
                if !pressed { pressed = true }
                // A little give toward the drag, capped so it stays a squish.
                let limit: CGFloat = 0.06
                stretch = CGSize(width: max(-limit, min(limit, value.translation.width / 400)),
                                 height: max(-limit, min(limit, value.translation.height / 400)))
            }
            .onEnded { _ in
                pressed = false
                stretch = .zero
            }
    }
    #endif
}

#if os(macOS)
/// Follows the mouse button for glass the pointer is over. A gesture would do
/// the same, but this glass sits inside Button labels, and on macOS a
/// zero-distance drag there takes the click away from the Button. Window
/// events are observed and passed on unchanged, so the Button still acts.
@MainActor
final class GlassPressMonitor: ObservableObject {
    @Published private(set) var pressed = false
    @Published private(set) var stretch: CGSize = .zero
    private var monitor: Any?
    private var hovering = false
    private var origin: CGPoint?

    func track(hovering: Bool) {
        self.hovering = hovering
        if hovering { install() } else if !pressed { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        origin = nil
        if pressed { pressed = false }
        if stretch != .zero { stretch = .zero }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard hovering else { return }
            origin = event.locationInWindow
            pressed = true
        case .leftMouseDragged:
            guard pressed, let origin else { return }
            // A little give toward the drag, capped so it stays a squish.
            // Window coordinates grow upward; the view's grow downward.
            let limit: CGFloat = 0.06
            stretch = CGSize(width: max(-limit, min(limit, (event.locationInWindow.x - origin.x) / 400)),
                             height: max(-limit, min(limit, (origin.y - event.locationInWindow.y) / 400)))
        case .leftMouseUp:
            guard pressed else { return }
            pressed = false
            stretch = .zero
            origin = nil
            if !hovering { remove() }
        default:
            break
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
#endif

private struct PressDeformation: ViewModifier {
    let active: Bool
    let pressed: Bool
    let stretch: CGSize

    func body(content: Content) -> some View {
        if active {
            // Swell on press, then stretch along the drag while the cross axis
            // narrows, keeping the apparent volume roughly constant.
            let base: CGFloat = pressed ? 1.06 : 1
            let sx = base * (1 + abs(stretch.width) - abs(stretch.height) * 0.5)
            let sy = base * (1 + abs(stretch.height) - abs(stretch.width) * 0.5)
            content
                .scaleEffect(x: sx, y: sy)
                .offset(x: stretch.width * 60, y: stretch.height * 60)
                .animation(pressed ? .spring(response: 0.22, dampingFraction: 0.62)
                                   : .spring(response: 0.42, dampingFraction: 0.48), value: pressed)
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.7), value: stretch)
        } else {
            content
        }
    }
}

/// Shape and spacing belong to the caller; lighting, contrast and accessibility
/// belong here so the sidebar, dock, back control and phone capsules stay in sync.
struct FloatingGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        if #unavailable(macOS 26.0) {
            content
                .compatGlass(in: shape)
                .clipShape(shape)
                .background {
                    // Shadow only the outline behind the opaque fallback.
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.09),
                                radius: 12, y: 4)
                }
        } else {
            nativeSurface(content)
        }
        #else
        nativeSurface(content)
        #endif
    }

    private func nativeSurface(_ content: Content) -> some View {
        content.compatGlass(in: shape)
            .clipShape(shape)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.09), radius: 12, y: 4)
    }
}

extension View {
    /// Floating chrome over scrolling content must own every touch inside its
    /// outline. The legacy glass material ignores hits, and on iOS 16/17 a bare
    /// hit shape still lets UIKit lists underneath receive the tap, so an empty
    /// gesture claims the gaps between controls. Apply it to a control
    /// container, never inside a Button's label, where it would win over the
    /// Button's own action.
    func blocksTouchPassThrough(in shape: some Shape) -> some View {
        background {
            shape.fill(Color.clear)
                .contentShape(shape)
                .onTapGesture {}
                #if os(iOS)
                // Before iOS 18 the root hosting view can return the page's
                // nested hosting view from UIKit hit testing even where
                // SwiftUI chrome sits on top, so a tap on a chrome Button also
                // reaches the row underneath. A real UIView behind the chrome
                // ends UIKit hit testing here; the chrome's SwiftUI controls
                // still receive the touch through their own hosting view.
                .background(UIKitTouchBarrier())
                #endif
                .accessibilityHidden(true)
        }
    }
}

#if os(iOS)
private struct UIKitTouchBarrier: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
