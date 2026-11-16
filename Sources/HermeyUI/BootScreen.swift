import HermesKit
import SwiftUI

/// The launch screen: the active theme's background, and the app's face in the middle of it, still.
///
/// This is the screen that covers the window between the process starting and the app being usable
/// — the socket dialled, the roster answered, the selected bot's sessions read. `LaunchReadiness`
/// owns *when* it goes away; this view owns only what it looks like, which is why it takes no
/// readiness, no model and no motion.
///
/// ```swift
/// LaunchGateView(model: app.model, isPaired: { app.isPaired }) {
///     BootScreen()
/// } content: {
///     RootView()
/// }
/// ```
///
/// ## It does not move
///
/// Deliberately, and unconditionally: no keyframes, no `TimelineView`, no Reduce Motion branch,
/// because there is nothing to reduce. A launch screen is on screen for a moment and is gone; the
/// face's life belongs to the bot rows, where `BotAvatarView` already animates it under the person's
/// own switch. The face here is drawn with `animates: false`, so `BotAvatarMotion.allows` refuses
/// every frame and the artwork is the resting pose at every size — the same shape, colour and eyes
/// the roster draws, standing still.
///
/// ## What it is made of
///
/// The fill is `Tokens.canvas`, the same canvas the session list and the window's own backdrop use,
/// read at draw time so a theme change is a redraw and not a stored colour. The face carries no
/// plate — the reference's own splash renders the character alone for exactly that reason ("The
/// splash shows the character alone, with no plate", `packages/ui-tokens/scripts/export-brand.ts`),
/// and `BotAvatarView` draws a shape, never a background.
///
/// ## The 108 pt face
///
/// The reference's splash icon is 620 pt of character inside a 1024 pt square (the same file), which
/// is ~61 % of the canvas; 108 pt is ~40 % of a 280 pt-wide phone in portrait and comfortably inside
/// the 96–120 pt a launch mark wants on both a phone and a Mac window. The eye ink is the fill
/// colour (`pageBackground:`) so the bars are cut out of the face rather than painted on it.
public struct BootScreen: View {

    /// The face's side, in points.
    /// Width ÷ height of the mark after its plate was made transparent: 790 × 770.
    public static let markAspect: CGFloat = 790.0 / 770.0

    public static let faceSide: CGFloat = 108

    /// How long the launch screen takes to leave once the app is usable.
    ///
    /// 180 ms, the reference's own layer fade (`logo-avatar-layer-in` / `logo-avatar-layer-out`,
    /// `packages/ui-web/src/logo-avatar.css`): long enough that the app does not appear to snap, short
    /// enough that it is a transition rather than a wait. There is no matching fade *in* — the launch
    /// screen is at full opacity on its first frame, because a splash that fades up is a splash that
    /// showed a white window first.
    public static let fadeOutDuration: Double = 0.18

    /// The identity the house face is drawn from, so the app's own mark is a fixed one rather than
    /// whatever an id happens to hash to. Any id works; this one is the app's name.
    public static let houseIdentity = "hermey"

    /// Kept for source compatibility with the callers that already pass it; the launch face is the
    /// brand mark (`Resources/HermeyMark.png`), which does not vary by identity.
    public var identity: String
    /// A stored `#RRGGBB` / `#RRGGBB::shape_N` value, as `BotAvatarView` takes it. `nil` derives both
    /// from `identity`.
    public var color: String?
    /// The face's side in points. 96–120 pt is the range this is designed for.
    public var side: CGFloat
    /// What VoiceOver says while the app is not up yet.
    public var label: String
    /// The fill. `nil` is `Tokens.canvas`, read at draw time so a theme change reaches it.
    public var background: Color?

    public init(identity: String = BootScreen.houseIdentity,
                color: String? = nil,
                side: CGFloat = BootScreen.faceSide,
                label: String = "Starting",
                background: Color? = nil) {
        self.identity = identity
        self.color = color
        self.side = side
        self.label = label
        self.background = background
    }

    public var body: some View {
        let fill = background ?? Tokens.canvas
        ZStack {
            fill
            // The app's own mark — the black-and-white face the icon is made of — not a bot's
            // identity-derived body: at launch there is no bot, and a coloured face would claim
            // there were. Transparent background, so it sits on whatever canvas the theme is.
            //
            // Read from the *app's* asset catalog: a SwiftPM resource bundle name is not a thing the
            // image loader sees on iOS, and a name that does not resolve draws nothing at all — a
            // splash with no mark reads as "no splash", which is how this shipped once (`0.1.482`).
            Image("HermeyMark")
                .resizable()
                .interpolation(.high)
                .aspectRatio(BootScreen.markAspect, contentMode: .fit)
                .frame(width: side, height: side / BootScreen.markAspect)
                .accessibilityHidden(true)
        }
        // The fill reaches the window's edges: on iOS that is under the status bar and the home
        // indicator, on the Mac under the (hidden) title bar, which is the whole point of a launch
        // screen — a canvas that stops short of an edge shows the system's own white in the gap.
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

#if DEBUG
#Preview("Boot screen · Midnight") {
    BootScreen()
        .preferredColorScheme(.dark)
}

#Preview("Boot screen · face sizes") {
    HStack(spacing: 0) {
        BootScreen(side: 96)
        BootScreen(side: 120)
    }
    .preferredColorScheme(.dark)
}
#endif
