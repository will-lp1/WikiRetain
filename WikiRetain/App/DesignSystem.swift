import SwiftUI

// MARK: - Motion
//
// Design-engineering motion defaults, following the principle that good defaults
// matter more than options. Custom timing curves (built-in easings "lack punch"),
// durations kept under ~300ms, ease-out for enter/exit, ease-in-out for on-screen
// movement, and never ease-in for UI.

enum Motion {
    /// Enter / exit. cubic-bezier(0.23, 1, 0.32, 1) — starts fast, settles softly.
    static let easeOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    /// On-screen movement / morphing. cubic-bezier(0.77, 0, 0.175, 1).
    static let easeInOut = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.30)
    /// Button-press feedback — snappy, 160ms, ease-out.
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    /// "Alive" elements — a subtle, low-bounce spring (bounce ≈ 0.18).
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    /// Returns `animation` normally, or a gentle opacity-only fade under Reduce Motion
    /// (reduced motion means fewer/gentler animations, not none).
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.18) : animation
    }
}

// MARK: - Pressable button style
//
// Instant, tactile feedback on every pressable element: a small scale-down
// (0.97) plus a slight dim, animated with a fast ease-out curve, honoring
// Reduce Motion (drops the scale, keeps the dim). A light haptic confirms the tap.

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var scale: CGFloat = 0.97
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .modifier(PressHaptic(isPressed: configuration.isPressed, enabled: haptic))
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Tactile press feedback with sensible defaults. Use on any pressable control.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// A firmer press (e.g. large primary/CTA buttons).
    static func pressable(scale: CGFloat, haptic: Bool = true) -> PressableButtonStyle {
        PressableButtonStyle(scale: scale, haptic: haptic)
    }
}

/// Fires one light impact on the leading edge of a press.
private struct PressHaptic: ViewModifier {
    let isPressed: Bool
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.sensoryFeedback(.impact(weight: .light, intensity: 0.4), trigger: isPressed) { _, now in now }
        } else {
            content
        }
    }
}
