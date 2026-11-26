import Foundation
import SwiftUI

/// Marks: what a body can give way to.
///
/// A mark is a value — an `id` and a function that lays its parts out about its own centre — and a
/// pose names the marks it shows and how far the body has given way to each (`PoseMark`). That is
/// upstream 0.5.0's model (`packages/core/src/marks.ts`), where `Pose.marks` replaced `Pose.bang`
/// and `Pose.dots`: a mark is no longer a field of the pose, so a state of a host's own can show any
/// mark it likes, and a pose part way between two states can show two.
///
/// ## Why our eight states carry none
///
/// Upstream's `thinking` and `blocked` *are* marks: the body shrinks to nothing and three dots or an
/// exclamation mark stand where the face was. That was tried here and taken out — at 24 pt a marked
/// bot is a smaller, eyeless one in exactly the state that most needs the bot to still look like
/// itself, and a row of bots showed one of them as a different creature. So `OpenBotAvatarState`'s
/// eight branches set no mark at all (a guard refuses it), the body never gives way, and the
/// machinery below exists for definitions of a host's own. The one upstream fix worth having travels
/// with it: `bodyScale` keeps the body, small, rather than leaving the frame empty when several
/// marks each weigh too little to show.
public struct AvatarMark: @unchecked Sendable {
    /// Names the mark; a pose lists its marks in the order of their ids.
    public let id: String
    /// The mark's parts, fully grown, with `x` and `y` measured from the mark's centre.
    public let parts: @Sendable (MarkContext) -> [MarkPart]

    public init(id: String, parts: @escaping @Sendable (MarkContext) -> [MarkPart]) {
        self.id = id
        self.parts = parts
    }
}

/// Two marks with one id are the same mark — upstream's rule for a state's `id` too, and the reason
/// a change between two definitions that share an id is not a change at all. The closure is host
/// code and cannot be compared, so the id is what a pose's equality and hashing read.
extension AvatarMark: Hashable {
    public static func == (left: AvatarMark, right: AvatarMark) -> Bool { left.id == right.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One part of a mark: a fixed outline about its own centre, and where that centre is this frame.
public struct MarkPart: @unchecked Sendable {
    /// Stable name of the outline, e.g. `"dot"`. Keep an outline as it is from frame to frame and
    /// move the part with `x`, `y`, `turn` and `scale`: a material keeps what it builds per outline.
    public var shape: String
    /// The outline, about its own centre, in mark units. Upstream carries this as an SVG `d`; a
    /// `Path` is the same outline without a re-parse in every material.
    public var path: Path
    /// The outline's box in its own coordinates.
    public var box: CGRect
    /// Centre in the mark's coordinates, viewBox units …
    public var x: Double
    public var y: Double
    /// … then a rotation about the mark's centre (radians) and a scale about the part's own.
    public var turn: Double
    public var scale: Double
    /// The outline is a circle or an upright capsule filling `box`. A material draws such a part from
    /// a ready ball; for any other outline it builds the model in the outline's shape.
    public var round: Bool

    public init(shape: String,
                path: Path,
                box: CGRect,
                x: Double = 0,
                y: Double = 0,
                turn: Double = 0,
                scale: Double = 1,
                round: Bool = false) {
        self.shape = shape
        self.path = path
        self.box = box
        self.x = x
        self.y = y
        self.turn = turn
        self.scale = scale
        self.round = round
    }
}

/// `Path` holds an immutable `CGPath`, which is safe to read from any thread; the value's identity is
/// its geometry, which is what `==` below compares. So the conformance is unchecked rather than
/// absent, exactly as upstream's part is plain data a frame can carry anywhere.
extension MarkPart: Hashable {
    public static func == (left: MarkPart, right: MarkPart) -> Bool {
        left.shape == right.shape && left.box == right.box && left.x == right.x
            && left.y == right.y && left.turn == right.turn && left.scale == right.scale
            && left.round == right.round
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(shape)
        hasher.combine(box)
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(turn)
        hasher.combine(scale)
        hasher.combine(round)
    }
}

extension MarkPart {
    /// A circle of `radius`, filled by its box — the dots and the exclamation mark's full stop.
    public static func circle(radius: Double,
                              shape: String = "dot",
                              x: Double = 0,
                              y: Double = 0,
                              turn: Double = 0,
                              scale: Double = 1) -> MarkPart {
        let box = CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)
        return MarkPart(shape: shape,
                        path: Path(ellipseIn: box),
                        box: box, x: x, y: y, turn: turn, scale: scale, round: true)
    }

    /// An upright capsule `width` across and `height` tall, filled by its box — the exclamation
    /// mark's bar. Upstream's `capsule()` (marks.ts:64) is the same rounded rect in a path string.
    public static func capsule(width: Double,
                               height: Double,
                               shape: String = "bar",
                               x: Double = 0,
                               y: Double = 0,
                               turn: Double = 0,
                               scale: Double = 1) -> MarkPart {
        let box = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        return MarkPart(shape: shape,
                        path: Path(roundedRect: box, cornerRadius: min(width, height) / 2),
                        box: box, x: x, y: y, turn: turn, scale: scale, round: true)
    }
}

/// What a mark is laid out from.
public struct MarkContext: Hashable, Sendable {
    /// The length every mark is sized in, viewBox units: a share of the body's smaller side.
    public var unit: Double
    /// The animation clock, seconds, offset per avatar so several marks on a page do not move
    /// together. 0 when `still`.
    public var time: Double
    /// Hold the mark at rest (reduced motion).
    public var still: Bool

    public init(unit: Double, time: Double, still: Bool) {
        self.unit = unit
        self.time = time
        self.still = still
    }
}

/// A mark in a pose, and how far the body has given way to it, 0…1.
public struct PoseMark: @unchecked Sendable, Hashable {
    public var mark: AvatarMark
    public var weight: Double

    public init(mark: AvatarMark, weight: Double) {
        self.mark = mark
        self.weight = weight
    }

    public static func == (left: PoseMark, right: PoseMark) -> Bool {
        left.mark == right.mark && left.weight == right.weight
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(mark)
        hasher.combine(weight)
    }
}

// MARK: - The built-in marks

public extension AvatarMark {

    /// The exclamation mark: it jumps and shakes every couple of seconds.
    ///
    /// Every number is `BANG` in `packages/core/src/marks.ts:70-88`: a bar 0.21 × 0.5 units, a full
    /// stop of radius 0.115, a 0.1 gap between them, one alarm every 2.6 s that is a jump over its
    /// first 0.3 with a shake of 0.2 rad at 3 cycles that dies away as it lands, a lift of 0.09
    /// units, and the stop lagging the bar by 45 % so the mark stretches as it jumps.
    static let bang = AvatarMark(id: "bang") { context in
        let u = context.unit, t = context.time
        let barWidth = 0.21 * u, barHeight = 0.5 * u, dotRadius = 0.115 * u, gap = 0.1 * u
        let total = barHeight + gap + 2 * dotRadius
        let p = context.still ? 1 : ((t.truncatingRemainder(dividingBy: 2.6)) + 2.6)
            .truncatingRemainder(dividingBy: 2.6) / 2.6
        let alarm = p < 0.3 ? p / 0.3 : 1
        let jump = context.still ? 0 : sin(.pi * alarm)
        let turn = context.still ? 0 : 0.2 * sin(2 * .pi * 3 * alarm) * (1 - alarm)
        let lift = -0.09 * u * jump
        let barY = -total / 2 + barHeight / 2, dotY = total / 2 - dotRadius
        return [
            MarkPart.capsule(width: barWidth, height: barHeight,
                             x: 0, y: barY + lift, turn: turn),
            MarkPart.circle(radius: dotRadius,
                            x: 0, y: dotY + lift * 0.45, turn: turn),
        ]
    }

    /// The three dots: they take turns hopping.
    ///
    /// `DOTS` in marks.ts:91-102 — radius 0.1 units, 0.31 apart, one hop each 1.25 s with the
    /// second and third a beat of 0.17 behind, the hop over the first 0.4 of the turn, 0.16 units up
    /// and 12 % larger at the top.
    static let dots = AvatarMark(id: "dots") { context in
        let u = context.unit, t = context.time
        let radius = 0.1 * u, step = 0.31 * u
        return [0, 1, 2].map { index in
            let period = 1.25
            let raw = t - Double(index) * 0.17
            let p = context.still ? 0 : (raw.truncatingRemainder(dividingBy: period) + period)
                .truncatingRemainder(dividingBy: period) / period
            let hop = p < 0.4 ? sin(.pi * (p / 0.4)) : 0
            return MarkPart.circle(radius: radius, shape: "dot3",
                                   x: Double(index - 1) * step,
                                   y: -0.16 * u * hop,
                                   scale: 1 + 0.12 * hop)
        }
    }
}

// MARK: - Blending, sanitising, placing

public enum OpenBotAvatarMarks {

    /// The marks of a pose part way between two, each weight mixed (a mark only one side shows
    /// counts as 0 on the other), in the order of their ids so the result does not depend on which
    /// side came first. A mark that has gone altogether is left out. `marks.ts:109`.
    public static func blended(_ a: [PoseMark],
                               _ b: [PoseMark],
                               _ mix: (Double, Double) -> Double) -> [PoseMark] {
        func weight(_ list: [PoseMark], _ id: String) -> Double {
            list.first { $0.mark.id == id }?.weight ?? 0
        }
        // A mark both sides name is the one being changed to, should the two differ under one id.
        let names = b + a.filter { first in !b.contains { $0.mark.id == first.mark.id } }
        return names
            .map { PoseMark(mark: $0.mark, weight: mix(weight(a, $0.mark.id), weight(b, $0.mark.id))) }
            .filter { $0.weight > 0 }
            .sorted { $0.mark.id < $1.mark.id }
    }

    /// The marks a state's pose gave, as a pose holds them: one per id, in the order of their ids,
    /// each weight within 0…1. An entry whose weight does not count is left out, and a second mark
    /// under an id already taken is dropped. `marks.ts:123`.
    public static func sanitised(_ given: [PoseMark]) -> [PoseMark] {
        var marks: [PoseMark] = []
        for entry in given {
            guard entry.weight > 0, entry.weight.isFinite else { continue }
            guard !marks.contains(where: { $0.mark.id == entry.mark.id }) else { continue }
            marks.append(PoseMark(mark: entry.mark, weight: min(1, entry.weight)))
        }
        return marks.sorted { $0.mark.id < $1.mark.id }
    }

    /// The parts a mark laid out, as the renderer can draw them: an entry with no outline or no box of
    /// some size is left out, and a place, turn or scale that is not a finite number is that of a
    /// part at rest in the mark's centre, so a slip in one field cannot put NaN into a frame.
    /// `marks.ts:141`.
    public static func parts(of given: [MarkPart]) -> [MarkPart] {
        given.compactMap { part in
            guard part.box.width > 0, part.box.height > 0 else { return nil }
            guard part.path.isEmpty == false else { return nil }
            var clean = part
            clean.x = part.x.isFinite ? part.x : 0
            clean.y = part.y.isFinite ? part.y : 0
            clean.turn = part.turn.isFinite ? part.turn : 0
            clean.scale = part.scale.isFinite ? part.scale : 1
            return clean
        }
    }

    /// The unit every mark is sized in: a share of the body's smaller side, within limits that read
    /// at any size. `effects.ts:381`.
    public static func unit(for box: OpenBotAvatarGeometry.Box) -> Double {
        min(78, max(34, min(box.width, box.height)))
    }

    /// A mark starts to grow at this weight, just before the body is gone, so something is always on
    /// screen. `effects.ts:377`.
    static let markFrom = 0.45

    static func grown(_ weight: Double) -> Double {
        smooth((min(1, max(0, weight)) - markFrom) / (1 - markFrom))
    }

    /// The parts of a pose's marks at one moment, placed on the body. A mark's weight 0…1 is how far
    /// the body has given way to it: the mark grows in as the body goes, from the body's centre.
    /// `effects.ts:390`.
    public static func placed(_ marks: [PoseMark],
                              in box: OpenBotAvatarGeometry.Box,
                              seed: UInt32,
                              time: Double,
                              still: Bool) -> [MarkPart] {
        guard !marks.isEmpty else { return [] }
        let centre = box.center
        let context = MarkContext(unit: unit(for: box),
                                  time: still ? 0 : time + OpenBotAvatarState.noise(seed, 9) * 10,
                                  still: still)
        return marks.flatMap { entry -> [MarkPart] in
            let grow = grown(entry.weight)
            guard grow > 0 else { return [] }
            return parts(of: entry.mark.parts(context)).map { part in
                var placed = part
                placed.x = centre.x + part.x * grow
                placed.y = centre.y + part.y * grow
                placed.scale = part.scale * grow
                return placed
            }
        }
    }

    /// How much of its size the body keeps while it gives way to its marks: gone a little past half
    /// way. Several marks that each weigh too little to show (three at a third each, when a change
    /// between two is interrupted by a third) would leave nothing on screen: until one of them shows,
    /// the body stays as small as it is when a mark first does. `effects.ts:406`.
    ///
    /// This is the one fix 0.5.0 took into upstream's six states, and it is why a pose whose marks
    /// have not yet grown keeps a body. For our eight built-in states the list is always empty, so
    /// this returns 1 and nothing about their drawing changes.
    public static func bodyScale(_ marks: [PoseMark]) -> Double {
        func left(_ weight: Double) -> Double { 1 - smooth(min(1, max(0, weight)) / 0.55) }
        let scale = left(marks.reduce(0.0) { $0 + $1.weight })
        return marks.contains { grown($0.weight) > 0 } ? scale : max(scale, left(markFrom))
    }

    static func smooth(_ u: Double) -> Double {
        let x = min(1, max(0, u))
        return x * x * (3 - 2 * x)
    }
}
