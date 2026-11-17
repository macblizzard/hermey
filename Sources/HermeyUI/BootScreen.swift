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
/// ## It blinks, and does nothing else
///
/// The face is the app's own mark, so it holds still: no keyframes, no `TimelineView`, no continuous
/// animation — the face's life belongs to the bot rows, where `BotAvatarView` animates it under the
/// person's own switch. It does blink, because a still face at launch reads as a picture of a face
/// (asked for 2026-11-17: "would it be possible to add an eye blink on app boot screen during bootup").
///
/// A blink is two eyelids coming down over the mark's own ink for 90 ms and going back up in 140 ms,
/// roughly every four seconds, with one early enough that a fast launch still shows it. That is two
/// short Core Animation transitions per blink and nothing in between — no work per frame, no timer on
/// the render path, and nothing at all under Reduce Motion, where the face stays open.
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

    /// Where the mark's eyes are, as fractions of the artwork, and what the eyelid is painted in.
    ///
    /// Measured from `Resources/HermeyMark.png` rather than guessed: the two dark bars are 790 × 770
    /// artwork at x 215–329 and 460–574, y 266–455 and 283–472. A lid covers one bar from its top down,
    /// in the face's own vertical shading — the mark is white at the crown (250) and grey at the chin
    /// (169), so a flat lid colour would read as a painted rectangle for the 90 ms it is up.
    static let eyelids: [CGRect] = [
        CGRect(x: 215.0 / 790, y: 266.0 / 770, width: 115.0 / 790, height: 190.0 / 770),
        CGRect(x: 460.0 / 790, y: 283.0 / 770, width: 115.0 / 790, height: 190.0 / 770),
    ]

    /// The face's own shading where the lids land, sampled from the artwork rather than guessed: `250`
    /// where the bars begin and `206` where they end. Rendering the lids over the bars with these two
    /// stops leaves no eye ink visible at full closure (measured: the darkest pixel left is 206 against
    /// ink at 54–66), and the seam above each lid differs from the face by 3–5/255.
    static let lidTop = Color(white: 250.0 / 255)
    static let lidBottom = Color(white: 206.0 / 255)
    /// The bar's corner radius, as a fraction of its own height (the artwork's bars are rounded ends).
    static let lidCorner: CGFloat = 0.42

    /// How long the lid takes to come down, how long to go back up, and the gap between blinks.
    static let lidCloseDuration: Double = 0.09
    static let lidOpenDuration: Double = 0.14
    static let blinkInterval: ClosedRange<Double> = 3.4 ... 5.6
    /// The first blink, early enough that a launch which is over in a second still shows it.
    static let firstBlinkDelay: Double = 0.55

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 = eyes open, 1 = shut. One value for both eyes: a face that winks is a different expression.
    @State private var lid: CGFloat = 0

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
                .overlay { eyelids }
                .accessibilityHidden(true)
        }
        // The fill reaches the window's edges: on iOS that is under the status bar and the home
        // indicator, on the Mac under the (hidden) title bar, which is the whole point of a launch
        // screen — a canvas that stops short of an edge shows the system's own white in the gap.
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .task { await blink() }
    }

    /// Two bars of the face's own shading, coming down over the mark's ink.
    ///
    /// The lid is anchored at the top of each bar and grows downwards, which is the direction eyelids
    /// move; the height is a fraction of the bar, so it scales with the mark at any size.
    private var eyelids: some View {
        GeometryReader { geometry in
            ForEach(Array(BootScreen.eyelids.enumerated()), id: \.offset) { _, bar in
                let height = bar.height * geometry.size.height * lid
                let width = bar.width * geometry.size.width
                LinearGradient(colors: [BootScreen.lidTop, BootScreen.lidBottom],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: width * BootScreen.lidCorner,
                                                style: .continuous))
                    .position(x: (bar.minX + bar.width / 2) * geometry.size.width,
                              y: bar.minY * geometry.size.height + height / 2)
                    .opacity(lid > 0.001 ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Blink now and then, for as long as the launch screen is up.
    ///
    /// Cancelled with the view: `Task.sleep` is the only thing this owns, so a launch that ends in half
    /// a second leaves nothing running. Reduce Motion turns it off rather than shortening it — a face
    /// that moves is exactly what that setting is asking not to see.
    private func blink() async {
        guard !reduceMotion else { return }
        try? await Task.sleep(for: .seconds(BootScreen.firstBlinkDelay))
        while !Task.isCancelled {
            withAnimation(.easeIn(duration: BootScreen.lidCloseDuration)) { lid = 1 }
            try? await Task.sleep(for: .seconds(BootScreen.lidCloseDuration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: BootScreen.lidOpenDuration)) { lid = 0 }
            let rest = Double.random(in: BootScreen.blinkInterval)
            try? await Task.sleep(for: .seconds(rest))
        }
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
