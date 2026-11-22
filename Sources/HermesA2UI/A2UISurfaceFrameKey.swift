#if canImport(SwiftUI)
import SwiftUI

/// Where each drawn A2UI surface sits on screen, in global coordinates.
///
/// A transcript dismisses the keyboard on any tap ("a tap on the transcript is a tap outside the
/// box"). Native surfaces break that rule: tapping a `TextField` inside one has to focus it, and
/// the dismissal fired in the same gesture took the keyboard away again before it opened. The
/// surface publishes its frame; the transcript lets taps inside it through.
public struct A2UISurfaceFrameKey: PreferenceKey {
    public static var defaultValue: [CGRect] = []

    public static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}
#endif
