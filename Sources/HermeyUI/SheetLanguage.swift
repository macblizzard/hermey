import SwiftUI

/// One window language for every sheet in both apps.
///
/// Before this, each sheet chose its own background, colour scheme and corner radius, so the same app
/// showed a black-on-black sheet next to a grey one with square corners, and a Mac sheet could follow
/// the system appearance while the window behind it was dark (asked for 2026-11-15: "fix the windows
/// for all menu items for macOS and iOS so that they all seem harmonious to the apps design elements
/// and themes").
///
/// The rule is one modifier, applied where the sheet is *presented*, so a new sheet cannot forget it:
///
/// * the canvas behind every sheet, ignoring the safe area, so a short one is not a pale card on a
///   dark page;
/// * the app's own appearance, forced — Hermey is a dark product, and following the system here is
///   what made two sheets disagree inside one window;
/// * the same corner radius as every card (`Tokens.radiusGrouped`), and a matching presentation
///   background on iOS so the corners are not cut out of the system's grey.
///
/// Detents, sizes and titles stay with each sheet: those are *what* it is, not how it looks.
public struct HermesSheetChrome: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(Tokens.canvas.ignoresSafeArea())
            .preferredColorScheme(.dark)
            #if os(iOS)
            .presentationCornerRadius(Tokens.radiusGrouped)
            .presentationBackground(Tokens.canvas)
            // Every sheet gets the grabber, because every sheet can be swiped away. It used to be
            // per-sheet, so a screen could be dismissible and still look like a page — reported
            // 2026-11-16 ("some closes with swipe down some doesn't"). This modifier is applied at
            // every presentation site (pinned by `test_window_language`), so the affordance cannot
            // drift sheet by sheet either.
            .presentationDragIndicator(.visible)
            #endif
    }
}

public extension View {
    /// The house style for anything presented as a sheet. Apply at the presentation site.
    func hermesSheetChrome() -> some View {
        modifier(HermesSheetChrome())
    }

    /// Swipe down on the sheet's header to close it.
    ///
    /// The system's own sheet drag competes with a scrollable body: with a `List` under the finger, a
    /// downward drag scrolls (and bounces back) instead of dismissing, so a sheet that is dismissible and
    /// looks dismissible still refuses to go — reported 2026-11-16 and again 2026-11-17 for exactly the
    /// three sheets whose bodies are long lists (Skills, Library, MCP). This puts a 44 pt strip along the
    /// top, above the first row, that owns the gesture, so a drag there always closes the sheet.
    ///
    /// Applied *inside* the sheet, on its root: a strip thin enough that every row stays reachable, and
    /// transparent so it changes nothing visually.
    func hermesSwipeToDismiss() -> some View {
        modifier(HermesSwipeToDismiss())
    }
}

/// See `hermesSwipeToDismiss()`. iOS only: on macOS a sheet is a window with its own close control.
public struct HermesSwipeToDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGFloat = 0

    public init() {}

    public func body(content: Content) -> some View {
        #if os(iOS)
        content.overlay(alignment: .top) {
            Color.clear
                .frame(height: 44)
                .contentShape(Rectangle())
                .offset(y: offset)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            // Only downwards, and only from rest: a drag that starts upward is the body's.
                            offset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            let shouldClose = value.translation.height > 90
                                || value.predictedEndTranslation.height > 160
                            offset = 0
                            if shouldClose { dismiss() }
                        }
                )
                .allowsHitTesting(true)
        }
        #else
        content
        #endif
    }
}
