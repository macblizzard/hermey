import Foundation
import HermesKit

/// Where the balloon sits beside its pet: above and to the side, never over it.
///
/// The owner's complaint about 0.1.630 was the one thing a callout must never do — it was centred
/// over the icon, so on a 96 pt pet the bubble hid the thing it was talking about. A speech bubble
/// belongs above the speaker's shoulder, not in front of its face.
///
/// So the seats are tried in order, and the first that fits the display *and* leaves the pet's frame
/// untouched wins:
///
/// 1. above and to the right of the pet's top-right corner — the default;
/// 2. the mirror image, above and to the left, when the right would leave the display;
/// 3. directly above, centred — the tail still lands on the pet;
/// 4. below, when the pet is too close to the top of the screen for either;
/// 5. beside the pet, when the display is too short for the bubble above or below it at all.
///
/// A side seat puts the bubble's inner edge `tailReach` past the pet's edge. That number is not
/// arbitrary: `PetBalloonShape` clamps `tailCentre` to `cornerRadius + tailWidth / 2` from the
/// bubble's edge, so a bubble offset by exactly that much has its tail root on the pet's edge rather
/// than at the nearest point the shape allows.
///
/// Pure arithmetic on `PetRect`, like `PetGeometry`: the rules can be read and tested off a window
/// server, which is the only way CI — with no AppKit — can see them.
enum PetCalloutPlacement {
    /// The gap between the bubble and the pet, in points.
    static let gap: Double = 8

    /// How far the bubble's inner edge is set past the pet's edge on a side seat: the shape's own
    /// corner-safe tail offset, so the tail root lands on the pet's edge.
    static var tailReach: Double {
        Double(PetCalloutMetrics.cornerRadius + PetCalloutMetrics.tailWidth / 2)
    }

    /// Which seat the bubble took. Declared in the order they are tried in.
    enum Side: String {
        case aboveRight
        case aboveLeft
        case above
        case below
        case beside
    }

    struct Result: Equatable {
        var rect: PetRect
        var side: Side
    }

    /// The first seat that fits, or the least-bad one that keeps the bubble off the pet.
    static func place(pet: PetRect, balloon: PetRect, in frame: PetRect) -> Result {
        let width = balloon.width
        let height = balloon.height
        let above = pet.maxY + gap
        let right = pet.maxX - tailReach
        let left = pet.minX + tailReach - width
        let centred = clampX(pet.minX + (pet.width - width) / 2, width: width, in: frame)

        // 1. Above and to the right of the pet's top-right corner: its tail root sits on the pet's
        //    right edge, and the bubble grows away over the desktop.
        if above + height <= frame.maxY,
           right >= frame.minX, right + width <= frame.maxX {
            return Result(rect: box(right, above, width, height), side: .aboveRight)
        }

        // 2. The mirror, when the right-hand seat would leave the display.
        if above + height <= frame.maxY,
           left >= frame.minX, left + width <= frame.maxX {
            return Result(rect: box(left, above, width, height), side: .aboveLeft)
        }

        // 3. Directly above, centred: still clear of the pet, and the tail still finds its middle.
        if above + height <= frame.maxY {
            return Result(rect: box(centred, above, width, height), side: .above)
        }

        // 4. Below — the only seat that is not above, and still a gap clear of the pet.
        let below = pet.minY - gap - height
        if below >= frame.minY {
            return Result(rect: box(centred, below, width, height), side: .below)
        }

        // 5. A display too short for the bubble above or below the pet: beside it, so the pet is
        //    still not covered. The tail points down from the bubble's edge here, which is the
        //    closest a downward cue can get in a display this small.
        let middle = clampY(pet.minY + (pet.height - height) / 2, height: height, in: frame)
        let besideRight = pet.maxX + gap
        if besideRight + width <= frame.maxX {
            return Result(rect: box(besideRight, middle, width, height), side: .beside)
        }
        let besideLeft = pet.minX - gap - width
        if besideLeft >= frame.minX {
            return Result(rect: box(besideLeft, middle, width, height), side: .beside)
        }

        // 6. A display with no room anywhere clear of the pet (a mirrored tiny display): take the
        //    clamped seat, but never one that sits on the pet's frame.
        let fallback = box(centred, clampY(pet.minY + (pet.height - height) / 2,
                                          height: height, in: frame),
                           width, height)
        return Result(rect: clearOf(pet, fallback, in: frame), side: .above)
    }

    /// The pet's centre as a fraction of the bubble's width, which is what the tail follows.
    ///
    /// The shape clamps the fraction itself, so a side seat — where the pet is off the bubble's inner
    /// edge — still gets a tail on the pet's edge rather than one in the bubble's middle.
    static func tailFraction(pet: PetRect, balloon: PetRect) -> Double {
        guard balloon.width > 0 else { return 0.5 }
        let fraction = (pet.minX + pet.width / 2 - balloon.minX) / balloon.width
        return min(max(fraction, 0), 1)
    }

    // MARK: - Arithmetic

    private static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PetRect {
        PetRect(x: x, y: y, width: width, height: height)
    }

    private static func clampX(_ x: Double, width: Double, in frame: PetRect) -> Double {
        min(max(x, frame.minX), max(frame.minX, frame.maxX - width))
    }

    private static func clampY(_ y: Double, height: Double, in frame: PetRect) -> Double {
        min(max(y, frame.minY), max(frame.minY, frame.maxY - height))
    }

    /// A rect that overlaps the pet, lifted above it or dropped below it — the last resort of a
    /// display that cannot hold the bubble anywhere clear of the icon.
    private static func clearOf(_ pet: PetRect, _ rect: PetRect, in frame: PetRect) -> PetRect {
        let apart = rect.maxY <= pet.minY || rect.minY >= pet.maxY
            || rect.maxX <= pet.minX || rect.minX >= pet.maxX
        guard !apart else { return rect }

        var lifted = rect
        let above = pet.maxY + gap
        let below = pet.minY - gap - rect.height
        if above + rect.height <= frame.maxY {
            lifted.y = above
        } else if below >= frame.minY {
            lifted.y = below
        } else {
            lifted.y = max(frame.minY, below)
        }
        return lifted
    }
}
