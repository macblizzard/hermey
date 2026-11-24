import Foundation
import SwiftUI

/// The volume inferred from a definition's outline, and the cross-sections it is drawn from.
///
/// ## The model
///
/// A definition is a silhouette, not a 3-D model. Upstream infers the missing dimension: each filled
/// subpath is treated as a solid with a rounded rim, its front surface rising from the outline to a
/// plateau at the middle, and the drawing is the *stack of cross-sections* of that solid at depths
/// — nested offset contours, projected through the same view rotation as the face. Seen head-on the
/// stack is the outline; turned, the layers at the back and front slide apart and the body reads as
/// having depth. The eyes ride on the front surface, so they turn with it.
///
/// The depth is as deep as the part is thick, crescent-shaped parts getting up to 2.4× so they read
/// as discs (`partDepth`).
///
/// ## What is simplified, and why it still draws the same character
///
/// * **No solids of revolution.** Upstream detects an `x`-axis profile and revolves it (for turned
///   objects like a mug seen from the side) and otherwise inflates. Every part here inflates. Every
///   shipped definition in the contract is a blob, a box or a face — inflating is what upstream
///   itself does for all of them, and the revolve path only changes how a *side view* of a
///   symmetrical object is built, not the resting pose drawn here.
/// * **One plane stack, not two.** Upstream also builds side-facing planes and picks whichever
///   stack faces the viewer, so an almost-profile view keeps its silhouette. Here the view never
///   turns past a few degrees (the pose model is calm), so the `z` stack is the only one that can
///   show.
/// * **No thin-region refinement.** A narrow fin can fan out between two distant levels; the presets
///   have none, and a pasted definition with one still draws, with a slightly softer fin.
/// * **Contours from a distance field.** The cross-section at a depth is the offset contour of the
///   outline, which is what upstream's inset contours are. The field is sampled once per definition
///   and smoothed once — the result is the same nested-outline model, with a coarser interior.
///
/// Everything here is built once per definition (see `OpenBotAvatarModel`) and cached; the per-frame
/// drawing only applies affine transforms to paths that already exist.
public struct OpenBotAvatarVolume {

    /// One cross-section, already in the definition's own coordinates.
    public struct Slice: Identifiable {
        public let id: Int
        /// Depth of the plane, centred on 0: positive is toward the viewer.
        public let z: Double
        /// The filled profile in plane coordinates.
        public let path: Path
        /// Nested contours are drawn even-odd; the core reuses the definition's nonzero outline.
        public let evenOdd: Bool
        /// Distance of this contour from the outline; used only to skip slices hidden behind the
        /// core at rest.
        public let inset: Double
    }

    /// The tangent plane under an eye: its height and slope, so the eye turns with the surface.
    public struct EyePlane: Hashable {
        public var z: Double
        public var dzdx: Double
        public var dzdy: Double
    }

    /// One inflated part: an outline (with its holes), its depth and the slice stack.
    public struct Part {
        public let polygons: [[OpenBotAvatarGeometry.Point]]
        public let box: OpenBotAvatarGeometry.Box
        public let thickness: Double
        public let depth: Double
        let rxy: Double
        let rz: Double
        let field: OpenBotAvatarGeometry.Field
        public let core: Slice
        public let slices: [Slice]

        /// Front surface height `distance` units inside the outline (upstream's `surfaceZ`).
        public func surfaceHeight(inset distance: Double) -> Double {
            let half = depth / 2
            if rxy <= 0 || distance >= rxy { return half }
            let k = 1 - max(0, distance) / rxy
            return half - rz + (max(0, 1 - k * k)).squareRoot() * rz
        }

    }

    public let parts: [Part]
    public let box: OpenBotAvatarGeometry.Box
    public let pivot: OpenBotAvatarGeometry.Point
    /// Drawn eye size relative to the definition's: enlarged as far as the face has room for.
    public let eyeScale: Double
    public let eyePlanes: [EyePlane]
    /// Highest surface under each eye, for the eye's own depth.
    public let eyeZ: [Double]

    /// Build the volume of a validated definition.
    public init(definition: BotAvatarDefinition, polygons: [[OpenBotAvatarGeometry.Point]]) {
        let subpaths = Self.splitSubpaths(polygons)
        let holeFlags = subpaths.map { Self.isHole($0, among: subpaths) }
        var builtParts: [Part] = []
        for (index, outline) in subpaths.enumerated() where !holeFlags[index] {
            let cuts = subpaths.indices.filter { holeFlags[$0] && Self.containsProbe(outline, subpaths[$0]) }
            var partPolygons = outline
            for cut in cuts { partPolygons.append(contentsOf: subpaths[cut]) }
            builtParts.append(Self.makePart(polygons: partPolygons, outline: outline))
        }
        if builtParts.isEmpty {
            // A definition whose only subpaths read as holes: treat the whole path as one part.
            builtParts = [Self.makePart(polygons: polygons, outline: polygons.first ?? [])]
        }
        self.parts = builtParts
        let bounds = OpenBotAvatarGeometry.Box(polygons.flatMap { $0 })
        self.box = bounds
        self.pivot = bounds.center
        self.eyeScale = Self.boostedEyeScale(polygons: polygons, eyes: definition.eyes)
        let centers = OpenBotAvatarGeometry.eyeCenters(definition.eyes)
        // The eyes ride on whichever part is highest under their centres.
        let host = builtParts.max { left, right in
            let leftHeight = centers.map { Self.height(of: left, at: $0) }.min() ?? 0
            let rightHeight = centers.map { Self.height(of: right, at: $0) }.min() ?? 0
            return leftHeight < rightHeight
        }
        self.eyeZ = centers.map { center in host.map { Self.height(of: $0, at: center) } ?? 0 }
        self.eyePlanes = centers.map { center in
            guard let host else { return EyePlane(z: 0, dzdx: 0, dzdy: 0) }
            let step = 0.75
            let hx = Self.height(of: host, at: OpenBotAvatarGeometry.Point(center.x + step, center.y))
            let hx0 = Self.height(of: host, at: OpenBotAvatarGeometry.Point(center.x - step, center.y))
            let hy = Self.height(of: host, at: OpenBotAvatarGeometry.Point(center.x, center.y + step))
            let hy0 = Self.height(of: host, at: OpenBotAvatarGeometry.Point(center.x, center.y - step))
            return EyePlane(z: Self.height(of: host, at: center),
                            dzdx: (hx - hx0) / (2 * step),
                            dzdy: (hy - hy0) / (2 * step))
        }
    }

    /// Surface height under a point, 0 outside the part.
    static func height(of part: Part, at point: OpenBotAvatarGeometry.Point) -> Double {
        let distance = part.field.sample(point.x, point.y)
        guard distance > 0 else { return 0 }
        return part.surfaceHeight(inset: distance)
    }

    // MARK: - Building a part

    private static func makePart(polygons: [[OpenBotAvatarGeometry.Point]],
                                 outline: [OpenBotAvatarGeometry.Point]) -> Part {
        let box = OpenBotAvatarGeometry.Box(outline)
        let field = OpenBotAvatarGeometry.field(for: polygons, box: box)
        var inscribed = 0.0
        for value in field.values where value > inscribed { inscribed = value }
        let thickness = 2 * inscribed
        let depth = partDepth(thickness: thickness, box: box)
        let rxy = min(thickness / 2, depth / 2) * 0.9
        let rz = (depth / 2) * 0.85

        var slices: [Slice] = []
        let core = Slice(id: 0, z: 0, path: path(from: polygons), evenOdd: false, inset: 0)
        slices.append(core)
        let half = depth / 2
        if half > 0.05 {
            let steps = max(4, min(14, Int((rz / 0.8).rounded())))
            var levels: [Double] = [half - rz]
            if steps > 1 {
                for step in 1..<steps {
                    levels.append(half - rz + rz * sin(Double(step) / Double(steps) * .pi / 2))
                }
            }
            var id = 1
            for level in levels where level >= 0.02 {
                let inset = insetDistance(level: level, depth: depth, rxy: rxy, rz: rz)
                let loops = OpenBotAvatarGeometry.contours(of: field, at: inset)
                guard !loops.isEmpty else { continue }
                let contourPath = path(from: loops)
                let contourInset = loops.flatMap { $0 }.map { OpenBotAvatarGeometry.edgeDistance(polygons, $0) }.min() ?? 0
                for z in [level, -level] {
                    slices.append(Slice(id: id, z: z, path: contourPath, evenOdd: true, inset: contourInset))
                    id += 1
                }
            }
        }
        slices.sort { $0.z < $1.z }
        return Part(polygons: polygons, box: box, thickness: thickness, depth: depth,
                    rxy: rxy, rz: rz, field: field, core: core, slices: slices)
    }

    /// As deep as the part is thick, but tall slender parts get up to 2.4× their thickness so they
    /// read as discs (upstream's `partDepth`, clamped to `MAX_PART_DEPTH`).
    static func partDepth(thickness: Double, box: OpenBotAvatarGeometry.Box) -> Double {
        let long = max(box.width, box.height)
        let raw = 0.8 * max(thickness, min(0.4 * long, 2.4 * thickness))
        return min(30, max(3, raw))
    }

    /// How far inside the surface reaches `level` (upstream's `insetAt`), as a free function so the
    /// slice builder does not have to construct a part to ask.
    static func insetDistance(level: Double, depth: Double, rxy: Double, rz: Double) -> Double {
        let half = depth / 2
        if rxy <= 0 || rz <= 0 || level <= half - rz { return 0 }
        if level >= half { return rxy }
        let s = (level - (half - rz)) / rz
        return rxy * (1 - (max(0, 1 - s * s)).squareRoot())
    }

    static func path(from loops: [[OpenBotAvatarGeometry.Point]]) -> Path {
        Path { path in
            for loop in loops where loop.count >= 2 {
                path.move(to: CGPoint(x: loop[0].x, y: loop[0].y))
                for point in loop.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x, y: point.y))
                }
                path.closeSubpath()
            }
        }
    }

    // MARK: - Subpaths

    /// Split a flattened path into its closed subpaths.
    static func splitSubpaths(_ polygons: [[OpenBotAvatarGeometry.Point]]) -> [[OpenBotAvatarGeometry.Point]] {
        polygons.filter { $0.count >= 3 }
    }

    private static func probe(_ polygon: [OpenBotAvatarGeometry.Point]) -> OpenBotAvatarGeometry.Point? {
        let box = OpenBotAvatarGeometry.Box(polygon)
        // A point just inside the top edge, middle of the run, is inside nearly every closed path;
        // if it is not, sample the centre.
        let centre = box.center
        return OpenBotAvatarGeometry.contains([polygon], centre) ? centre : nil
    }

    private static func containsProbe(_ outline: [OpenBotAvatarGeometry.Point], _ hole: [OpenBotAvatarGeometry.Point]) -> Bool {
        guard let point = probe(hole) else { return false }
        return OpenBotAvatarGeometry.contains([outline], point)
    }

    /// A subpath is a hole when its own fill is mostly *not* inside the whole path's nonzero fill —
    /// upstream's rule, measured at the subpath's centre.
    static func isHole(_ subpath: [OpenBotAvatarGeometry.Point], among all: [[OpenBotAvatarGeometry.Point]]) -> Bool {
        guard let point = probe(subpath) else { return false }
        return !OpenBotAvatarGeometry.contains(all, point)
    }

    /// The largest eye scale (up to `eyeBoost`) whose drawn eyes keep `eyeBoostPad` from the
    /// outline. A small face keeps the definition's own scale instead of pushing the eyes off it.
    static func boostedEyeScale(polygons: [[OpenBotAvatarGeometry.Point]], eyes: BotAvatarDefinition.Eyes) -> Double {
        for factor in [OpenBotAvatarGeometry.eyeBoost, 1.38, 1.30, 1.22, 1.15, 1.08] {
            let scale = eyes.scale * factor
            if OpenBotAvatarGeometry.eyesFit(polygons, eyes: eyes, scale: scale, margin: OpenBotAvatarGeometry.eyeBoostPad) {
                return scale
            }
        }
        return eyes.scale
    }
}
