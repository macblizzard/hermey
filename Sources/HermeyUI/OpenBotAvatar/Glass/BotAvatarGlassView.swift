//  The glass body, as a SwiftUI view: whatever draws it, and nothing else.
//
//  One small type so the avatar's frame can name the shader's pass without knowing how it is drawn.
//  Where the process compiled the MSL (`HermeyGlassEngine.isReady`, which the route has already read)
//  this is a `MetalKit` view over the body's box; anywhere else it is an empty view, the route having
//  answered `.canvas` before this was ever built — the Live Activity, a preview, a Mac with no GPU.
import SwiftUI

/// The glass body's pass, in the avatar's own frame.
struct BotAvatarGlassView: View {

    /// One frame's numbers, exactly as the fragment function is fed them.
    var surface: BotAvatarGlassSurface
    /// The silhouette the body is drawn through — the path the `Canvas` route fills, in view points.
    var path: Path

    var body: some View {
        #if canImport(Metal) && !HERMEY_LIVE_ACTIVITY
        BotAvatarGlassCanvas(surface: surface, path: path)
            .allowsHitTesting(false)
        #else
        Color.clear
        #endif
    }
}
