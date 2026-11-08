import OpenBotUI
import SwiftUI

/// The 7 pt grab strip between the bot panel and the conversation.
///
/// The panel drags between `WorkspaceStore.sidebarFloor` (200 pt) and `Geometry.sidebarMax`
/// (400 pt): below 200 a bot row's name and description collide with its unread dot, and there
/// is no collapsed avatar strip any more — the list *is* the panel.
struct PaneDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let onCommit: () -> Void

    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Tokens.canvas)
            // The persistent boundary line is drawn by the shell (one hairline, in
            // `WorkspaceShell`); this view only *lights up* its hit strip, so the
            // divider never draws a second line a couple of points from that one.
            Rectangle()
                .fill(hovering ? Tokens.borderFocus : Color.clear)
                .frame(width: 1)
        }
        .frame(width: Geometry.paneDivider)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = width }
                    let base = dragStart ?? width
                    let proposed = base + value.translation.width
                    width = min(range.upperBound, max(range.lowerBound, proposed))
                }
                .onEnded { _ in
                    dragStart = nil
                    onCommit()
                }
        )
        .accessibilityLabel("Resize the bot panel")
    }
}

// MARK: - Previews

private struct PaneDividerPreview: View {
    @State private var width: CGFloat = Geometry.sidebarDefault

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: width)
            PaneDivider(width: $width,
                        range: WorkspaceStore.sidebarFloor...Geometry.sidebarMax,
                        onCommit: {})
            Color.clear.frame(maxWidth: .infinity)
        }
        .frame(width: 640, height: 320)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Pane divider") {
    PaneDividerPreview()
}
#endif
