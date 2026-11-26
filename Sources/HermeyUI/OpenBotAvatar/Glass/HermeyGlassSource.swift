//  The glass shader's source, as the string the process compiles.
//
//  Why a string and not a `.metal` file: a build-time shader goes through Xcode's Metal step, which
//  needs the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) — a 1–2 GB
//  download the owner's Mac does not have and CI cannot install, so the app stopped building at the
//  Metal step the moment the shader was added. Compiling the same source at run time needs no
//  toolchain: `device.makeLibrary(source:options:)` is the Metal framework's own compiler, on every
//  machine that runs the app.
//
//  Everything below is upstream's terms, line by line, exactly as the `.metal` file held them — the
//  citations are the point of the file, so they are inside the string and not in a comment above it.
#if !HERMEY_LIVE_ACTIVITY
import Foundation

/// The MSL the glass body is drawn with: one library per process, compiled by `HermeyGlassEngine`.
enum HermeyGlassSource {

    /// The whole shader — upstream's studio, optics and tone map, one fragment function.
    ///
    /// Absent from the Live Activity's build on purpose (`project.yml` sets `HERMEY_LIVE_ACTIVITY`
    /// there, and that target's sources exclude this folder): the widget process draws the painted
    /// material and has no business carrying a shader it will never compile.
    ///
    /// The first version of this pass drew the body but did not look like glass: the refracted ray
    /// sampled the flat fill the body had been drawn into, so "what is behind the glass" was the
    /// glass, and at 96 % opacity in the middle that composites to an opaque coloured blob. The
    /// second gave the body depth from the mask's distance field but still shaded **one surface**, so
    /// there was nothing to refract *through*: the pictures read as glossy plastic, with no side wall,
    /// no second edge and no interior. This pass raymarches a body instead of shading a silhouette —
    /// a real thickness, two refractions, absorption along the path the light actually takes, and the
    /// contact the object makes with the page — and each departure from upstream is listed with its
    /// reason in the string's own prologue, where the terms are.
    ///
    /// `Tools/glass-proof` renders this pass offscreen — 24, 48 and 200 pt, `cat`, idle and working,
    /// over the theme's dark canvas and over its surface — so the look can be checked as pictures
    /// rather than by adjective. It is not part of the app's build.
    static let msl = """
        //
        //  HermeyGlassSource.swift
        //
        //  The glass material as a lit, refracting *volume*: the app surfaces' body, shaded by a Metal
        //  fragment function instead of a stack of `Canvas` gradients.
        //
        //  ## Where this comes from
        //
        //  The terms and every constant below are ported from upstream's `packages/core/src/dom/glass/
        //  shaders.ts` (the WebGL pass its `GlassMaterial` runs over the volume's distance field). What is
        //  *not* ported is its mechanics: upstream ray-marches a 3-D SDF texture it uploads per definition,
        //  which no fragment pass over a flat body can receive (its arguments are the body's box, not a
        //  volume). So the two surfaces here are the volume's own height profile — `OpenBotAvatarVolume`'s
        //  `surfaceHeight`, the same rounded inset the Canvas path fills — evaluated analytically at the
        //  pixel, front and back, and the back wall is solved in closed form instead of marched.
        //
        //  Ported, with the line each constant is read from:
        //
        //  * `IOR = 1.50` — shaders.ts:46;
        //  * `F0 = 0.04` and `fresnelSchlick` — shaders.ts:47 and shaders.ts:137-139 (Schlick, fifth power);
        //  * the studio softboxes and their weights — shaders.ts:152-161: key `(-0.60,-0.74,-0.30)`
        //    half `(0.70,0.155)` soft `0.090` tilt `-0.52` at `13.0`, rim `(-0.24,-0.76,-0.60)`
        //    half `(0.70,0.095)` soft `0.075` tilt `-0.22` at `8.0`;
        //  * the flat-on key softbox and its `1.45` weight — shaders.ts:273-275, the lobe upstream uses for
        //    the eye's bead, and the only one whose centre is on the viewer's side (`+z`);
        //  * the room, the floor bounce and the perimeter side glow — shaders.ts:147-149 and 160-162;
        //  * the internal studio: the cyclorama (167-172), the caustic tabletop pool (175-185) and the four
        //    dome lobes with their exponents and weights (188-194), and `tirBoost` `mix(0.92,1.22,isTIR)`
        //    (193);
        //  * the refraction itself, `refract(rd, n1, 1.0/IOR)` and `weight = 1 - F1` — shaders.ts:289-290;
        //  * Beer-Lambert absorption, `absorbSigma = -log(max(transColor,0.12)) * 0.62 + 0.08` — shaders.ts:
        //    421-422 — and the optical-thickness compression `totalPath / (refScale + totalPath*0.30)` with
        //    `refScale = max(halfDepth*2.2, 14)` — shaders.ts:335, 340-342;
        //  * the back-wall exit: the normal at the exit, `nIn = -nOut`, `refract(rayDir, nIn, IOR)`, and the
        //    `length(exitDir) < 0.001` total-internal-reflection branch with `tirEnergy = weight * 0.65` —
        //    shaders.ts:349-359;
        //  * Maxwell's Fresnel at that exit, `F_exit = fresnelSchlick(cosTrans)`, and the split
        //    `envOut*beer*exitWeight + reflEnv*beerTIR*reflWeight` — shaders.ts:362-373;
        //  * the alpha's `- 0.12 * directTrans` and `+ 0.16 * tirEnergy` — shaders.ts:392-399;
        //  * the *geometry*, which is not in the shader at all: each part's `depth`, `rxy` and `rz` and the
        //    inflate solid built from them — renderer.ts:186-190; the C-infinity crown `0.055 * sdEff`, the
        //    `side` term and the `hypot(side, top)` implicit surface — renderer.ts:256-261; and
        //    `maxHalfZ = max(2, max(part.depth/2)) + 1.0`, the shader's `halfDepth` — renderer.ts:272,343;
        //  * the tone map `peak/(1 + peak*0.48)` and the white roll `smoothstep(2.2,5.2,peak)*0.80` —
        //    shaders.ts:381-388;
        //  * the alpha composite `mix(0.36,0.68,pow(1-cos,1.55))` and its `0.28…0.98` clamp —
        //    shaders.ts:391-399 — and the `1/2.2` gamma at 408.
        //
        //  ## What is deliberately different, and why
        //
        //  * **The body is the reference's solid, not a silhouette.** A *silhouette* fragment pass has no
        //    volume: shade one surface and there is nothing to refract through, which is why the earlier
        //    pictures read as glossy plastic — no side wall, no second edge, no interior. The volume comes
        //    from `renderer.ts`, which is where upstream's "real 3-D" actually lives: each inflate part is
        //    built from its own `depth`, `rxy` and `rz` (186-190) as the implicit solid
        //    `hypot(side, (z - flatZ - crown)/rz) = 1` (256-261), which is an elliptical edge fillet over a
        //    vertical wall of height `2·flatZ` at the outline, meeting a flat face `rxy` inside it. That
        //    one equation is the whole of this pass's thickness (`bodyHeight`), so the wall is a wall
        //    rather than a stroked edge, the bevel is an ellipse rather than a quarter circle, a cat's ear
        //    is thin because its own outline is close, and the ray that enters the front can leave the
        //    back — the two surfaces are what make it a lens, and both refractions bend the studio, so the
        //    background visibly moves.
        //  * **The interior is integrated, not sampled once.** shaders.ts:346 and 371 read the internal
        //    studio at the exit point alone. A body with real depth is not one point: `kInteriorSteps`
        //    fixed samples are walked from the entry to the exit, and the light each one gathers is
        //    weighted by how much of it survives the path back out. That is what puts light *behind* the
        //    front surface instead of on it.
        //  * **Absorption is a function of the path length.** shaders.ts:335/340-342 compresses the
        //    marched path into an optical thickness with `refScale = max(halfDepth*2.2, 14)`, because
        //    its march accumulates a far longer path than the glass it crosses. Applied to a geometric
        //    path it saturates: a 5-pt ear and a 55-pt belly landed 15 % apart, which is the "uniform
        //    resin" the pictures showed. Here the optical thickness is the path itself over the body's
        //    own depth, and the path is shortened where the body is thin (`inset / halfDepth`), so an
        //    ear — a fin, not a slab — absorbs a fraction of what the belly does at 200 pt and at 24.
        //  * **The caustic is the wall's own light, and its landing is solved.** The arc on the page is
        //    an offset curve of the silhouette at `causticLanding`: the height of the wall at the
        //    critical-angle inset, times `tan((IOR-1)·atan(rise))` — a thin prism's deflection, from
        //    Snell's small-angle form — so thin glass throws its light close and thick glass throws it
        //    further. It is not a radial blur around the body, and its distance is not chosen: it is the
        //    same thickness profile the body is drawn from, evaluated at the same critical line.
        //  * **The two-line edge is the critical-angle boundary.** A thick glass edge reads as two
        //    lines: the outer grazing Fresnel, and a darker line one rim in where light stops leaving
        //    the glass. The second is `criticalInset` — the inset where the bevel's own slope reaches
        //    `tan(asin(1/IOR))`, solved from `rxy`/`rz` — so it lands wherever the geometry puts it,
        //    one rim inside the bright one, and moves as the body turns. It used to be a threshold on a
        //    dot product, which is why the pair merged on some parts of the contour and vanished on
        //    others.
        //  * **The edge is coverage, and it is decided once.** `edgeCoverage` reconciles the drawn
        //    outline's own antialiasing with the distance field's sub-pixel place on the contour, using
        //    one pixel in points (`foot`). The rim, the far face and the caustic's arc are all shaped
        //    from that same coordinate, so a line narrower than a pixel fades instead of snapping to
        //    the sample grid — which is what a staircase on a diagonal edge actually is.
        //  * **The reflection bends with the surface.** The previous pass drew a fixed rotated rectangle
        //    in the body's plane, which is a painted streak. This reflects a real softbox in
        //    `reflect(rdS, n1S)`; because that normal turns across the shoulder, the highlight wraps with
        //    the body's curvature instead of sitting on it.
        //  * **The refracted ray lands on a studio plate, not on our own fill.** Upstream's ray leaves the
        //    volume into the room it marched; ours used to sample the layer the body was drawn into — which
        //    is a flat fill of the body's own tint, so "what is behind the glass" *was the glass*. The plate
        //    (`sampleGlassPlate`) is the same cyclorama, key and caustic pool, laid out positionally behind
        //    the body, and it now carries two soft *edges* — a panel and a shelf — because a smooth
        //    gradient refracts invisibly: the eye reads refraction off an edge that bends. It is lit
        //    neutral, the body's hue reaching it at 45 % and again through Beer-Lambert.
        //  * **The tint is decoded to linear light once.** The `Canvas` hands us the sRGB value it would
        //    have filled; the optics below are linear (as upstream's are). One `pow(2.2)` in, the
        //    existing `pow(1/2.2)` out.
        //  * **The plateau gets a key, the rim gets a direction.** Upstream's key softboxes sit in front of
        //    the camera, so only a *steep* bevel reflects them: on a flat dome they contribute nothing and
        //    the body reads as gloss. The flat-on softbox lights the face; the rim band is weighted toward
        //    the side that faces the key, so the edge catches light instead of glowing evenly.
        //  * **Contact, from the same field.** A soft short shadow and the pool the body throws past its
        //    own edge, both read off the mask's *outside* distance — so both follow the silhouette exactly
        //    instead of an ellipse fitted to the bounding box.
        //  * **The alpha composite is upstream's, re-weighted.** `edgeTransparency`, `directTrans` and
        //    `tirEnergy` are upstream's; the luminance term is halved (`0.34` over `0.30…0.95` rather than
        //    `0.52` over `0.16…0.90`) and the rim adds `0.30`, so the middle of the body stays see-through
        //    and the edge stays solid. With upstream's weighting the body clamped shut over our dark canvas.
        //
        //  ## How it runs
        //
        //  It is not a build-time `.metal` file. Xcode's Metal step needs the Metal Toolchain component
        //  (`xcodebuild -downloadComponent MetalToolchain`), a 1–2 GB download the owner's Mac does not
        //  have and CI cannot install, so the file could not be built at all. It is a string:
        //  `HermeyGlassSource.msl`, right here, compiled once per process by `device.makeLibrary(source:)`
        //  into one `MTLLibrary`, whose fragment function draws the body into a `MetalKit` view sitting
        //  between the avatar's two `Canvas` passes; the body's silhouette arrives as a texture instead, because
        //  a `SwiftUI::Layer` is not reachable from a runtime-compiled library. If the compile
        //  fails the process keeps `BotAvatarGlassShader.isAvailable` false, logs Metal's own error once,
        //  and every surface takes the painted material: the route degrades, it never crashes.
        //
        //  The texture is a **silhouette**, not a fill: white, with the outline in its alpha and the
        //  distance field either side of it in green and blue. The fragment reads only those channels, so
        //  the flat painted body cannot appear under the shader even by accident. `Tools/glass-proof`
        //  renders it, offscreen, at 24, 48 and 200 pt.
        //
        #include <metal_stdlib>

        using namespace metal;

        // MARK: - The volume's resolution

        /// How many slices the interior is integrated over. A preprocessor constant, so the loop bound
        /// is a compile-time literal that unrolls, and no frame can ask for a different cost.
        ///
        /// shaders.ts:218 marches 96 times and bisects five (327) because it is chasing a 3-D SDF it
        /// has no derivative of. This body's two surfaces are closed-form, so the exit needs three
        /// refinements (`bodyExit`) and the *interior* only needs enough slices to show the studio's
        /// pool deepening along the path. Twelve is where the banding stopped being visible at 200 pt.
        #define kInteriorSteps 12u

        /// renderer.ts:256 — the C-infinity convex polish upstream lays across the flat front face
        /// (`crown = 0.055 * sdEff`), which is what keeps a lit face from being a dead plane.
        #define kCrown 0.055

        /// Where the studio plate stands behind the body, in half-depths, for the exit ray to land on.
        #define kPlateStandoff 2.4

        /// The plate's and the gathered interior's gains. Both are light, not tint: the tone map above
        /// rolls anything past 5.2 to white, so a gain here brightens the body without bleaching it,
        /// and the amber survives because the absorption is applied after.
        #define kPlateGain 1.35
        #define kInteriorGain 1.35

        /// How opaque the *glass itself* is: the share of the page the body hides, per unit of light it
        /// absorbs. Upstream's alpha is a surface term (Fresnel and luminance) because their glass is
        /// clear; an amber body with a 60-point path hides the page behind it, and an alpha that ignored
        /// that turns a solid object into a coloured film.
        #define kAbsorptionOpacity 0.45

        /// The proof's studio, and not the app's.
        ///
        /// `Tools/glass-proof` recompiles *this same string* with this switched to 1, so what the picture
        /// shows is the transform this pass applies — not an illustration of it. It replaces the studio
        /// with a coarse checkerboard, mid grey on near black: through a plate of glass the pattern has
        /// to arrive visibly compressed, bent and — past the point where the traced ray folds — inverted.
        /// A smooth studio can only ever be tinted, which is why a picture of one proves translucency and
        /// nothing about refraction.
        #define kPlatePattern 0

        // MARK: - Upstream's constants

        /// shaders.ts:46 — the refractive index of the glass upstream draws.
        constant float kIOR = 1.50;
        /// shaders.ts:47 — Schlick's reflectance at normal incidence for glass.
        constant float kF0 = 0.04;

        /// The cosine of the critical angle for `kIOR`, i.e. `sqrt(1 - 1/IOR²)`.
        ///
        /// Not a new tuning number: it is the total-internal-reflection limit that decides where the
        /// rear edge line sits, and it is derived from `kIOR` so the two can never disagree.
        static inline float sinCritical() {
            return sqrt(1.0 - 1.0 / (kIOR * kIOR));
        }

        /// `smoothstep` with its edges given the way upstream writes them (high edge first). MSL leaves
        /// `smoothstep` undefined when `edge0 > edge1`, so every reversed ramp in shaders.ts goes through
        /// here rather than being copied with its arguments swapped in the wrong direction.
        static inline float smoothstepR(float edge0, float edge1, float x) {
            return 1.0 - smoothstep(edge1, edge0, x);
        }

        /// How much of this pixel the body covers — the app's edge antialiasing, decided once.
        ///
        /// The mask's alpha is the drawn outline's own coverage, which Core Graphics antialiased at
        /// the drawable's resolution. The distance field is a second, independent estimate from either
        /// side of that outline: `inset` and `outside` are in points, so `(inset - outside) / foot` is
        /// the pixel's place on a one-pixel ramp across the contour (`foot` is one pixel in points).
        /// Averaging the two is not double coverage — on the contour both say one half — it is a
        /// coverage that stays smooth when a line narrower than a pixel lands between two samples,
        /// which is exactly where a bright rim used to snap to the pixel grid and staircase.
        static inline float edgeCoverage(float inset, float outside, float foot, float maskAlpha) {
            float ramp = clamp(0.5 + (inset - outside) / max(foot, 0.001), 0.0, 1.0);
            return clamp(0.5 * clamp(maskAlpha, 0.0, 1.0) + 0.5 * ramp, 0.0, 1.0);
        }

        /// shaders.ts:137-139 — Schlick's approximation, exactly as upstream writes it.
        static inline float fresnelSchlick(float cosTheta) {
            return kF0 + (1.0 - kF0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
        }

        /// shaders.ts:122-135 — a rectangular studio light seen through a reflective direction, feathered.
        static inline float softbox(float3 dir, float3 center, float2 halfSize, float softness, float tilt) {
            float3 c = normalize(center);
            float f = dot(dir, c);
            if (f <= 0.05) return 0.0;
            float3 up = abs(c.y) < 0.92 ? float3(0.0, -1.0, 0.0) : float3(1.0, 0.0, 0.0);
            float3 u = normalize(cross(up, c));
            float3 v = cross(c, u);
            float2 proj = float2(dot(dir, u), dot(dir, v)) / max(f, 0.25);
            float ct = cos(tilt), st = sin(tilt);
            proj = float2(ct * proj.x - st * proj.y, st * proj.x + ct * proj.y);
            float2 q = abs(proj) - halfSize;
            float dist = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0);
            return 1.0 - smoothstep(-softness, softness, dist);
        }

        /// shaders.ts:142-165 — the room outside the body: a quiet dark studio with two softboxes and a
        /// perimeter glow, in the body's own hue.
        static inline float3 sampleOuterStudio(float3 dirS, float3 jewelTint, float detail) {
            float3 d = normalize(dirS);

            float upFade = smoothstepR(0.9, -0.9, d.y);                       // shaders.ts:146
            float3 baseRoom = mix(float3(0.020), jewelTint * 0.14, 0.42) * (0.65 + 0.55 * upFade);
            float floorBounce = pow(clamp(d.y, 0.0, 1.0), 2.2);               // shaders.ts:148
            float3 col = baseRoom + jewelTint * (0.42 * floorBounce);

            float keyMain = softbox(d, float3(-0.60, -0.74, -0.30), float2(0.70, 0.155), 0.090, -0.52);
            col += float3(1.0) * (keyMain * 13.0);                            // shaders.ts:161 (key, 152)

            if (detail > 0.5) {
                float keyRim = softbox(d, float3(-0.24, -0.76, -0.60), float2(0.70, 0.095), 0.075, -0.22);
                col += float3(1.0) * (keyRim * 8.0);                          // shaders.ts:161 (rim, 153)
                float sideGlow = pow(clamp(1.0 - abs(d.z), 0.0, 1.0), 1.8)
                               * (0.55 + 0.45 * smoothstepR(0.6, -0.7, d.y));  // shaders.ts:160
                col += mix(jewelTint, float3(0.95, 1.0, 1.0), 0.48) * (sideGlow * 1.15);
            }
            return col;
        }

        /// shaders.ts:167-197 — the light the glass gathers inside itself: a cyclorama, the caustic pool
        /// under the body, and the four soft lobes that make a thick body glow instead of going grey.
        static inline float3 sampleInternalStudio(float3 posS, float3 dirS, float3 jewelTint,
                                                  float isTIR, float bottomRel, float detail) {
            float3 d = normalize(dirS);

            float upFade = smoothstepR(1.0, -1.0, d.y);                       // shaders.ts:171
            float3 col = mix(float3(0.022), jewelTint * 0.22, 0.55) * (0.65 + 0.50 * upFade);

            if (detail > 0.5 && d.y > -0.05) {
                // shaders.ts:175-185 — the tabletop the figurine stands on, as a falloff in the floor plane.
                float dySafe = max(d.y, 0.08);
                float tFloor = clamp((bottomRel - posS.y) / dySafe, 0.0, 260.0);
                float3 fp = posS + d * tFloor;
                float r2 = dot(fp.xz, fp.xz) / (50.0 * 50.0 * 0.60);
                float causticPool = exp(-r2 * 0.85);
                float hotCore = exp(-r2 * 2.4);
                float floorFade = smoothstep(-0.05, 0.42, d.y);
                col += jewelTint * (1.05 * causticPool + 0.48 * hotCore) * floorFade;
            }

            float upperLeft = pow(max(0.0, dot(d, normalize(float3(-0.55, -0.72, -0.42)))), 3.2);
            float rightRim  = pow(max(0.0, dot(d, normalize(float3( 0.82, -0.25, -0.52)))), 3.6);
            float leftRim   = pow(max(0.0, dot(d, normalize(float3(-0.88,  0.12, -0.46)))), 3.4);
            float topGlow   = pow(max(0.0, dot(d, normalize(float3( 0.05, -0.92, -0.38)))), 3.0);

            float tirBoost = mix(0.92, 1.22, isTIR);                          // shaders.ts:193
            col += mix(jewelTint, float3(1.0), 0.52)
                 * (upperLeft * 1.45 + rightRim * 1.15 + leftRim * 1.05 + topGlow * 1.10) * tirBoost;
            return col;
        }

        /// The studio the glass stands in front of, laid out in the body's own plane.
        ///
        /// Upstream reaches these three through its raymarch, so for it they *are* the room a refracted
        /// ray lands in. There is no room behind a flat body — the only thing behind it is the layer it
        /// was drawn into — so the same light is laid out positionally here and the traced ray's landing
        /// point moves it.
        ///
        /// Ported: the cyclorama's `mix(vec3(0.022), tint*0.22, 0.55)` and its vertical fade
        /// (shaders.ts:167-172), the caustic pool's `exp(-r2*0.85)` and `exp(-r2*2.4)` hot core
        /// (shaders.ts:175-185), and the key's angles and `13.0` weight (shaders.ts:152, 161).
        ///
        /// Ours: where in the plane each sits, and the two soft *edges* — a panel and a shelf. A studio
        /// of smooth gradients is invisible through glass: refraction is only legible where it bends
        /// something with an edge in it. The edges are the strongest claim this plate makes, and they are
        /// why the pictures now show the body bending its background instead of tinting it.
        /// A soft edge whose width is the wider of the studio's own feather and the studio-space
        /// distance one pixel of screen covers.
        ///
        /// This is the whole of the refraction being legible without aliasing. The shoulder compresses
        /// the studio: a single pixel out there lands over half a plate, so a fixed feather either blurs
        /// the flat middle into a wash or tears the wall into stair-steps. Measuring the footprint — the
        /// plane's own `fwidth` — gives an edge that is crisp where the bend is gentle and exactly one
        /// pixel wide where it is violent, which is what a camera does.
        static inline float footedStep(float edge, float feather, float x, float foot) {
            float w = max(feather, foot * 0.80);
            return smoothstep(edge - w, edge + w, x);
        }

        /// The share of this pixel a band covers: width `halfWidth` either side of `centre`, box-
        /// filtered over one pixel (`foot`, in points).
        ///
        /// A line narrower than a pixel has no business being drawn as a bright pixel or not drawn at
        /// all — those are the two answers a point sample can give, and together they are the dotted,
        /// stair-stepped rim. Filtering the band's own width over the pixel's width is the coverage it
        /// would get from four samples, for the cost of two adds and a divide: at 200 pt a 0.5-pt line
        /// fades to a dimmer set of pixels, and at 24 pt — where the whole rim is two pixels wide — the
        /// line still arrives at its true brightness instead of snapping on and off along the contour.
        static inline float bandCoverage(float x, float centre, float halfWidth, float foot) {
            return clamp((halfWidth + 0.5 * foot - abs(x - centre)) / max(foot, 1e-3), 0.0, 1.0);
        }

        static inline float3 sampleGlassPlate(float2 uv, float2 foot, float3 jewelTint, float detail) {
            if (kPlatePattern > 0) {
                // Proof only. Cells are ~0.45 of a half-extent, so they are legible at 200 pt and coarse
                // enough that the picture is about the bending rather than about filtering.
                float2 cell = floor(uv * 2.2 + 32.0);
                float checker = fmod(cell.x + cell.y, 2.0);
                return mix(float3(0.045, 0.048, 0.055), float3(0.62, 0.64, 0.68), checker)
                     * mix(float3(1.0), jewelTint, 0.30);
            }
            // Neutral studio light, not the body's hue: the tint is the absorption's job below, and a
            // plate that carried it as well doubled the saturation until the body read as maroon.
            float top = pow(clamp(0.5 - 0.5 * uv.y, 0.0, 1.0), 0.85);        // shaders.ts:167-172
            float3 col = mix(float3(0.120, 0.126, 0.140), float3(0.700, 0.740, 0.840), top);
            col *= mix(float3(1.0), jewelTint, 0.45);

            // The key: the wide, soft box high and to the left (shaders.ts:152), read at 13.0
            // (shaders.ts:161) and brought down to what survives the tone map at 24 pt.
            float2 keyP = float2((uv.x + 0.34) / 0.95, (uv.y + 0.58) / 0.55);
            col += float3(1.0) * (exp(-dot(keyP, keyP) * 1.35) * 13.0 * 0.055);

            if (detail > 0.5) {
                // The studio itself, so the refraction has edges to bend. Glass is legible as glass
                // mainly through the *image* it passes — its own surface reflection is 4 % — so the
                // room behind it has to be a room with edges in it, not a gradient. A window standing
                // behind and above the body, a tube light beside it, and the shelf it stands on: four
                // straight edges, one thin line, one horizon, each of which arrives bent.
                float window = footedStep(-0.36, 0.012, uv.x, foot.x)
                             * footedStep(0.52, 0.012, -uv.x, foot.x)
                             * footedStep(-1.35, 0.012, uv.y, foot.y)
                             * footedStep(0.02, 0.012, -uv.y, foot.y);
                // The room outside the window falls away, and the window itself is a box of light with
                // a gradient in it. Contrast, not level: the body has to stay on this page's darkness
                // while the studio behind it becomes something with a shape.
                col *= mix(1.0, 0.40, (1.0 - window) * detail);
                col += float3(0.92, 0.96, 1.0) * (window * mix(0.55, 1.55, top));

                // The tube light: the one feature thin enough to read as a line through the wall.
                // Their widths carry the same footprint rule the edges do: a tube narrower than the
                // pixel it lands on is a row of dots, not a line.
                float tubeW = max(0.030, foot.x * 1.20);
                float tube = exp(-pow((uv.x - 0.70) / tubeW, 2.0))
                           * footedStep(0.34, 0.02, -uv.y, foot.y) * footedStep(-0.95, 0.02, uv.y, foot.y);
                col += float3(0.95, 0.98, 1.0) * (tube * 1.90);
                float tube2 = exp(-pow((uv.x + 0.22) / max(0.024, foot.x * 1.10), 2.0))
                            * footedStep(0.30, 0.02, uv.y, foot.y);
                col += float3(0.90, 0.94, 1.0) * (tube2 * 1.20);

                // The shelf the body stands on, as a horizon.
                col += float3(0.72, 0.78, 0.90) * (footedStep(0.60, 0.010, uv.y, foot.y) * 0.34);

                // And the narrow right-hand strip (shaders.ts:153): upstream's second key, which is
                // the edge the eye reads the body's turn against.
                float strip = exp(-pow((uv.x - 0.98) / max(0.18, foot.x * 2.0), 2.0))
                            * smoothstepR(0.80, -0.95, uv.y);
                col += float3(0.90, 0.96, 1.0) * (strip * 1.10);
            }

            // The caustic tabletop pool beneath the body (shaders.ts:175-185), in the plane, and the
            // only place the tint belongs in the plate. It sits *below* the footprint so it is only
            // ever seen through the bottom shoulder — which is exactly where a real piece of glass
            // throws its light.
            float2 c = float2(uv.x / 0.90, (uv.y - 1.35) / 0.40);
            float r2 = dot(c, c);
            col += jewelTint * ((1.05 * exp(-r2 * 0.85) + 0.48 * exp(-r2 * 2.4)) * 1.20);
            return col;
        }

        /// The traced ray's landing point, folded back inside the plate.
        ///
        /// The shoulder sends rays out at up to sixty degrees, and on a body this thin they land two or
        /// three body-widths away; a hard clamp there is a visible flat band, because every pixel past
        /// the limit gets the same colour. `tanh` is monotone and smooth, so the bend stays continuous
        /// all the way out and the plate's own edge is never reached: `limit * tanh(r/limit)` is `r` for
        /// small `r` and never exceeds `limit`.
        static inline float2 foldIntoPlate(float2 v, float limit) {
            float r = length(v);
            return r < 1e-4 ? v : v * (limit * tanh(r / limit) / r);
        }

        // MARK: - The body's thickness

        /// renderer.ts:257 — `side`: how much of the bevel is left at `s` points inside the outline. One
        /// at the outline, zero where the bevel has met the flat face (`s = rxy`), and clamped rather
        /// than soft-maxed: `smax(a, 0, 0.28)` rounds a junction that is already C1, and the clamp is the
        /// same surface without the constant.
        static inline float bodySide(float s, float rxy) {
            return clamp((rxy - s) / max(rxy, 0.001), 0.0, 1.0);
        }

        /// The front surface's height `s` points inside the outline, from upstream's own implicit solid.
        ///
        /// renderer.ts:186-190 and 256-261 build each inflate part as a *solid*, not a silhouette:
        ///
        ///     half   = part.depth / 2          rxy = max(1.2, part.rxy)      rz = max(1.2, part.rz)
        ///     flatZ  = max(0, half - rz)       crown = 0.055 * sdEff          side = (rxy - sdEff)/rxy
        ///     d      = (1 - hypot(side, max(0, (z - flatZ - crown)/rz))) * scale
        ///
        /// so the surface is `hypot(side, (z - flatZ - crown)/rz) = 1` — an *elliptical* edge fillet over
        /// a vertical wall of height `2·flatZ` at the outline, meeting a flat face at `s = rxy`. Solved for
        /// z, that is the line below. It replaces the quarter-circle this pass used to invent: upstream's
        /// `flatZ` gives the silhouette a real wall to have, its `rz`/`rxy` give the bevel the ellipse a
        /// cast edge actually has, and its `crown` lifts the face by 0.055 per point so a lit face is a
        /// shallow cone instead of a plane. Every constant here is theirs; none is tuned by eye.
        static inline float bodyHeight(float s, float rxy, float rz, float flatZ) {
            float side = bodySide(s, rxy);
            float capped = min(s, rxy * 1.08);                                    // renderer.ts:192 rCap
            return flatZ + kCrown * capped + rz * sqrt(max(0.0, 1.0 - side * side));
        }

        /// d(height)/d(inset): the normal's tilt, infinite at the outline where the wall is vertical and
        /// `kCrown` on the flat face. The rim's width, the refraction's strength and the reflection's
        /// sweep are all read off this one number, so they cannot disagree with each other.
        static inline float bodyRise(float s, float rxy, float rz) {
            if (s >= rxy * 1.08) return 0.0;
            float side = bodySide(s, rxy);
            float bevel = max(sqrt(max(0.0, 1.0 - side * side)), 1e-3);
            return kCrown + rz * (side / bevel) / max(rxy, 0.001);
        }

        /// The slope whose normal is exactly the critical angle: `tan(asin(1/IOR))`.
        ///
        /// Not a tuning number — it is `1/sqrt(IOR²-1)`, the same limit `sinCritical()` is, written as
        /// a slope because the profile gives steepness directly. Where the bevel reaches it, light
        /// stops leaving the glass; that is the dark line a thick edge wears one rim inside its bright
        /// one, and it is why the pair is a boundary rather than a stroke.
        static inline float criticalSlope() {
            float s = sinCritical();
            return s / sqrt(max(1.0 - s * s, 0.02));
        }

        /// The inset at which the bevel's slope equals `criticalSlope()`, solved from the profile.
        ///
        /// `bodyRise` is `crown + rz*(side/bevel)/rxy`; setting it to `k` gives `side = k/sqrt(1+k²)`
        /// and so `s = rxy*(1 - side)`. It moves with `rxy` and `rz`, so on a shallow bevel the line
        /// sits deeper in than on a steep one — a boundary the geometry puts there, not a radius.
        static inline float criticalInset(float rxy, float rz) {
            float k = max((criticalSlope() - kCrown) * rxy / max(rz, 0.001), 0.0);
            return rxy * (1.0 - k / sqrt(1.0 + k * k));
        }

        /// The optical path a ray of `pathLength` travels through a body whose half depth is
        /// `halfDepth`, in body half-depths.
        ///
        /// shaders.ts:335,340-342 compresses the path (`totalPath / (refScale + totalPath*0.30)`,
        /// `refScale = max(halfDepth*2.2, 14)`) because its SDF march accumulates a much longer path
        /// than the glass it crosses. Here the path is already geometric, and compressing it is what
        /// made a 5-pt ear and a 55-pt belly land within 15 % of each other — the interior read as one
        /// wash. Linear in the path, normalised by the body's own depth, has no floor to saturate
        /// against, so the same gradient survives at 24 pt.
        static inline float opticalThickness(float pathLength, float halfDepth) {
            return pathLength / max(halfDepth * 1.75, 0.001);
        }

        /// Beer-Lambert along that path, with upstream's `absorbSigma` (shaders.ts:421-422).
        static inline float3 absorptionAlong(float optical, float3 absorbSigma) {
            return exp(-absorbSigma * optical);
        }

        /// Where the light that crossed the bottom wall lands on the page, in points from the
        /// silhouette — derived, not chosen.
        ///
        /// The wall at the critical line is a prism of height `2·h` whose face is tilted by
        /// `atan(rise)`; a thin prism deflects a ray by `(IOR - 1)` times that angle (the small-angle
        /// form of Snell, exact enough below the critical angle), and a ray displaced by the height it
        /// crossed lands `2·h·tan(deflection)` away. So the caustic's distance from the body is the
        /// thickness profile at the critical inset times the glass's own bending: thin glass throws
        /// its light close, a thick wall throws it further, and the curve follows the silhouette
        /// because it is the silhouette's offset at that distance.
        static inline float causticLanding(float rxy, float rz, float flatZ) {
            float at = criticalInset(rxy, rz);
            float deflection = atan(max(bodyRise(at, rxy, rz), 0.0)) * (kIOR - 1.0);
            return 2.0 * bodyHeight(at, rxy, rz, flatZ) * tan(clamp(deflection, 0.0, 1.35));
        }

        /// The inset at which a ray that entered at `s` meets the back surface.
        ///
        /// `reach` is how fast the ray moves further inside per point of depth it travels. Three
        /// refinements of `entry + exit` is all it takes, because the exit's height only falls as the
        /// ray moves in: the iteration is a contraction. shaders.ts:313-333 marches the SDF and bisects
        /// five times to find the same point; there is no SDF here (the profile *is* the solid), so it is
        /// solved instead of searched.
        static inline float bodyExit(float s, float reach, float rxy, float rz, float flatZ) {
            float entry = bodyHeight(s, rxy, rz, flatZ);
            float exitInset = s;
            float walk = 2.0 * entry;
            for (uint i = 0u; i < 3u; ++i) {
                exitInset = clamp(s + reach * walk, s, s + rxy);
                walk = entry + bodyHeight(exitInset, rxy, rz, flatZ);
            }
            return exitInset;
        }

        /// The view basis: the renderer's own yaw-then-pitch, model space (z toward the viewer) to the
        /// screen's (y down). The third row is the cross product of the first two, so the rotation stays
        /// orthonormal for every pose.
        static inline float3 toScreen(float3 n, float cosYaw, float sinYaw, float cosPitch, float sinPitch) {
            return float3(cosYaw * n.x + sinYaw * n.z,
                          sinYaw * sinPitch * n.x + cosPitch * n.y - cosYaw * sinPitch * n.z,
                          -sinYaw * cosPitch * n.x + sinPitch * n.y + cosYaw * cosPitch * n.z);
        }

        // MARK: - One frame's numbers

        /// Everything the fragment is fed for one frame, as `float4`s only, so the Swift side can hand it
        /// over with `setFragmentBytes` and both sides agree on the layout without a padding table.
        ///
        /// `size` carries both spaces: the shader works in points (the Canvas' own), while the drawable and
        /// the silhouette mask are in pixels — `size.xy` is the layer in points and `size.zw` the same layer
        /// in pixels, the scale between them being the display's.
        struct HermeyGlassUniforms {
            float4 tint;     // rgb — the body's colour, as the Canvas would have filled it (sRGB)
            float4 shape;    // half width, half height, corner radius, half depth (points)
            float4 profile;  // inset radius rxy, rise rz, centre x, centre y (points)
            float4 pose;     // yaw, pitch, the state's rim opacity, detail (0 compact, 1 full)
            float4 tone;     // the light-backdrop hairline, the exposure, the rim's gain, the absorption
            float4 size;     // points x, points y, pixels x, pixels y
        };

        // MARK: - The pass

        /// One view-covering quad in clip space: four vertices, a triangle strip, no vertex buffer.
        vertex float4 hermeyGlassVertex(uint vertexID [[vertex_id]]) {
            float2 corner = float2((vertexID & 1) == 0 ? 0.0 : 1.0, (vertexID & 2) == 0 ? 0.0 : 1.0);
            return float4(corner * 2.0 - 1.0, 0.0, 1.0);
        }

        /// The glass body.
        ///
        /// `shape`   — the body's half extents, corner radius and half depth, in points;
        /// `profile` — the inset `rxy` and rise `rz` in points, and the body's centre in the layer;
        /// `pose`    — yaw, pitch, the state's rim opacity and `detail` (0 compact, 1 full);
        /// `tone`    — the light-backdrop hairline, the exposure, the rim's gain and the absorption weight;
        /// `size`    — the layer in points and in pixels;
        /// `bodyLayer` — the body's silhouette filled **white**, y down from the top-left as `[[position]]`
        ///               is. Its alpha is the true silhouette, `g` the distance inside it and `b` the
        ///               distance outside — and nothing else is read from it.
        fragment half4 hermeyGlassBody(float4 pos [[position]],
                                       constant HermeyGlassUniforms &uniforms [[buffer(0)]],
                                       texture2d<half> bodyLayer [[texture(0)]],
                                       sampler bodySampler [[sampler(0)]]) {
            // The layer's points, from the drawable's pixels: every number below is in the space the
            // Canvas drew in, which is what the uniforms were built in.
            float2 size = uniforms.size.xy;
            float2 pixels = max(uniforms.size.zw, float2(1.0));
            float2 position = pos.xy * (size / pixels);
            float4 shape = uniforms.shape;
            float4 profile = uniforms.profile;
            float4 pose = uniforms.pose;
            float4 tone = uniforms.tone;

            // The mask, and nothing else: `a` is the drawn outline, `g` is how far inside it this pixel
            // is and `b` how far outside — a distance field in points, built once per size by
            // `BotAvatarGlassDrawer.makeMask`. Its colour is white, so a fragment that read it would
            // come out white; the painted body cannot leak in here, which the old flat-fill texture
            // could not promise.
            half4 silhouette = bodyLayer.sample(bodySampler, pos.xy / pixels);
            float maxInset = 0.5 * min(size.x, size.y);
            float inset = float(silhouette.g) * maxInset;
            float outside = float(silhouette.b) * maxInset;
            // One pixel, in the points the profile is written in. Every line this pass draws — the
            // rim, the far face, the caustic's arc — is wider than this at 200 pt and can be one
            // pixel at 24, so this is the width below which they must be antialiased rather than
            // clipped to the sample grid.
            float foot = size.x / max(pixels.x, 1.0);
            // The silhouette's coverage: the drawn edge's own antialiasing, reconciled with the
            // distance field's sub-pixel place on the contour. This is the edge, decided once.
            float coverage = edgeCoverage(inset, outside, foot, float(silhouette.a));

            // The direction the surface falls away in, from the same field: the gradient of a distance
            // field is a unit vector pointing inland, which is exactly what the dome's normal needs.
            float2 texel = 0.75 * (pixels / max(size, float2(1.0)));
            float2 gradSd = float2(float(bodyLayer.sample(bodySampler, (pos.xy + float2(texel.x, 0.0)) / pixels).g)
                                 - float(bodyLayer.sample(bodySampler, (pos.xy - float2(texel.x, 0.0)) / pixels).g),
                                   float(bodyLayer.sample(bodySampler, (pos.xy + float2(0.0, texel.y)) / pixels).g)
                                 - float(bodyLayer.sample(bodySampler, (pos.xy - float2(0.0, texel.y)) / pixels).g));
            gradSd = normalize(gradSd + float2(1e-6f));

            // The tint arrives as the sRGB value the `Canvas` would have filled; the optics below are
            // linear light, as upstream's are. Decoded once here, encoded once at the end.
            float3 tint = pow(max(uniforms.tint.rgb, float3(0.0)), float3(2.2));

            float2 halfExtent = max(shape.xy, float2(0.5));
            float2 centre = profile.zw;
            float2 p = position - centre;
            float halfDepth = max(shape.w, 0.0);

            // The body as a solid, from the part's own numbers — renderer.ts:186-190: `half` its depth,
            // `rxy`/`rz` the ellipse its edge is rounded with, and `flatZ` the wall that ellipse leaves at
            // the outline. `u2` is the profile's `sdEff`: how far inside the outline this pixel is, capped
            // where the bevel has ended, which is what the mask's own distance field already is.
            float rxy = max(profile.x, 0.001);
            float rz = min(max(profile.y, 0.0), max(halfDepth, 0.001));
            float flatZ = max(0.0, halfDepth - rz);

            float height = bodyHeight(inset, rxy, rz, flatZ);
            float rise = bodyRise(inset, rxy, rz);

            // The front surface's normal: the height field's gradient, negated — the field rises inland,
            // so the normal leans out. The wall at the outline has an infinite rise and the flat face has
            // only the crown's, which is exactly the sweep that makes the reflection follow the form.
            float3 nModel = normalize(float3(-rise * gradSd.x, -rise * gradSd.y, 1.0));

            float cosYaw = cos(pose.x), sinYaw = sin(pose.x);
            float cosPitch = cos(pose.y), sinPitch = sin(pose.y);
            float3 nS = toScreen(nModel, cosYaw, sinYaw, cosPitch, sinPitch);

            float detail = pose.w;
            float cos1 = clamp(nS.z, 0.0, 1.0);
            float F1 = fresnelSchlick(cos1);

            // 0 at the silhouette's edge, 1 on the plateau: the body's own optical thickness, which is
            // what separates a solid piece of glass (thin, bright rim; deep, tinted middle) from a dome
            // of tinted gloss.
            float thick = clamp(height / max(halfDepth, 0.001), 0.0, 1.0);

            // shaders.ts:416-422 — the tint's own hue, and the absorption that gives it its depth. A body
            // that is nearly grey keeps a crystal-blue cast rather than a colourless one, as upstream does.
            float maxC = max(tint.r, max(tint.g, tint.b));
            float minC = min(tint.r, min(tint.g, tint.b));
            float sat = maxC > 0.001 ? (maxC - minC) / maxC : 0.0;
            float3 pureHue = maxC > 0.05 ? (tint / maxC) : float3(0.88, 0.94, 0.97);
            float3 jewelTint = mix(float3(0.88, 0.94, 0.97), pureHue, clamp(sat * 1.08, 0.0, 1.0));
            float3 transColor = mix(float3(0.97), jewelTint, clamp(sat * 0.88, 0.0, 1.0));
            float3 absorbSigma = (-log(max(transColor, float3(0.12))) * 0.62 + float3(0.08)) * tone.w;

            // The view ray: orthographic, along -z, as upstream's `rdS` (shaders.ts:201-202).
            float3 rdS = float3(0.0, 0.0, -1.0);
            float3 n1S = normalize(float3(nS.xy, max(nS.z, 0.02)));

            // 1 — the external Fresnel reflection of the studio (shaders.ts:282-285).
            float3 reflDirS = reflect(rdS, n1S);
            float3 accum = sampleOuterStudio(reflDirS, jewelTint, detail) * F1;

            // The key's own reflection, in the bent normal: a softbox on the viewer's side, high on the
            // key's side (shaders.ts:274-275's lobe, at its own `1.45`). Because `reflDirS` turns with
            // the shoulder, the highlight wraps the body's curvature — it is a reflection, not a band,
            // and its width is whatever the surface's curvature makes it.
            // A studio panel's reflection is an *image*, so its edge is as hard as the panel's. `0.030` of
            // feather is what makes it a highlight rather than a painted gradient, and because `reflDirS`
            // is the bent normal it sweeps and narrows with the shoulder's own curvature — widest where the
            // surface turns evenly, sharpest where it turns fastest.
            //
            // And a reflection is only as sharp as the pixel sampling it: where the bent normal sweeps
            // further in one pixel than the panel's own feather, the panel is feathered by that sweep. It
            // is the specular half of edge coverage — without it a bevel that turns quickly (an ear's
            // diagonal) draws the key as a sawtooth of lit and unlit pixels, which is the dotted highlight
            // in the pictures, and no amount of silhouette antialiasing touches it.
            float specFoot = min(0.30, length(fwidth(reflDirS)) * 0.85);
            float shoulder = softbox(reflDirS, float3(-0.52, -0.68, 0.52), float2(0.30, 0.14), 0.030 + specFoot, -0.35);
            accum += float3(1.0) * (shoulder * 1.95 * (0.55 + 0.45 * (1.0 - thick)) * (0.35 + 0.65 * (1.0 - cos1)));

            float weight = 1.0 - F1;

            // Upstream's own unit: the body spans 100 of them, so every optical constant above is used at
            // the scale it was tuned at however many points this surface is drawn in.
            float u = max(size.x, size.y) / 100.0;

            // 2 — refraction at the front surface (shaders.ts:289). `into` is the ray *inside* the glass.
            float3 into = refract(rdS, n1S, 1.0 / kIOR);
            bool entryTIR = length(into) < 0.001;
            into = entryTIR ? normalize(reflect(rdS, n1S)) : normalize(into);

            // How fast the ray moves further inside per point of depth: the in-plane component along the
            // field's own inland direction, over the depth it covers. Clamped, because at the very outline
            // the ray is grazing and the walk would run away along the wall.
            float reach = clamp(dot(into.xy, gradSd) / max(-into.z, 0.06), 0.0, 6.0);
            float exitInset = bodyExit(inset, reach, rxy, rz, flatZ);
            float exitHeight = bodyHeight(exitInset, rxy, rz, flatZ);
            float pathLength = (height + exitHeight) / max(0.30, -into.z);

            // 3 — the back surface's normal, and the exit refraction (shaders.ts:349-355). The back wall
            // is the same profile, mirrored in z, so its outward normal leans the same way and points away
            // from the viewer: the two refractions are the two halves of a lens.
            float exitRise = bodyRise(exitInset, rxy, rz);
            float3 n2M = normalize(float3(-exitRise * gradSd.x, -exitRise * gradSd.y, -1.0));
            float3 n2S = toScreen(n2M, cosYaw, sinYaw, cosPitch, sinPitch);

            float3 leaving = refract(into, -n2S, kIOR);
            bool rearTIR = length(leaving) < 0.001;
            float cosTrans = 0.0;
            float F2 = 0.0;
            float exitWeight = 0.0;
            float reflWeight = weight;
            if (!rearTIR) {
                // shaders.ts:355-373 — the transmitted share, by Maxwell's Fresnel on the air side.
                cosTrans = clamp(dot(leaving, n2S), 0.0, 1.0);
                F2 = fresnelSchlick(cosTrans);
                exitWeight = weight * (1.0 - F2);
                reflWeight = weight * F2;
            } else {
                // shaders.ts:356-359 — pure TIR: nothing leaves, all of it turns back. This is the band
                // that makes a glass edge read as *thick*: the wall becomes a mirror, and what it shows is
                // the studio behind the body. Weighting it by a Fresnel term computed from a direction that
                // does not exist was the bug that flattened it into a grey band.
                leaving = normalize(reflect(into, -n2S));
            }

            // What the exit ray sees: the studio, standing `kPlateStandoff` half-depths behind the body.
            // Where it lands is the image of the background, so this is the whole of "the glass bends what
            // is behind it" — no offset invented in the plane, the traced ray's own landing.
            float3 exitPoint = float3(p + into.xy * pathLength, -exitHeight);
            float plateZ = -halfDepth * (1.0 + kPlateStandoff);
            float travelZ = (plateZ - exitPoint.z) / min(leaving.z, -0.22);
            float2 land = exitPoint.xy + leaving.xy * travelZ;
            float2 plateUV = foldIntoPlate(land / halfExtent, 1.55);
            float2 plateFoot = fwidth(plateUV) + 1e-5;
            float3 plate = sampleGlassPlate(plateUV, plateFoot, jewelTint, detail);

            // shaders.ts:335, 340-342 — the ray's path, through the thickness the glass actually
            // presents. The absorbed length is the ray's own, shortened where the body is thin:
            // `inset / halfDepth` is how much body lies between this point and the nearest wall, so
            // an ear — a fin, not a slab — and the wall itself cross a fraction of what the belly
            // does. That is the whole of the difference between a solid piece of glass and a tinted
            // dome, and it is why the gradient stays readable where the body narrows instead of only
            // where it is deepest.
            float localBody = smoothstep(0.03, 0.85, inset / max(halfDepth, 0.001));
            float absorbingPath = pathLength * (0.30 + 0.70 * localBody);
            float optical = opticalThickness(absorbingPath, halfDepth);
            float3 beer = absorptionAlong(optical, absorbSigma);
            float lumThrough = dot(beer, float3(0.2126, 0.7152, 0.0722));
            float3 reflEnv = sampleInternalStudio(exitPoint / max(u, 0.0001), normalize(reflect(into, -n2S)),
                                                  jewelTint, 1.0, halfExtent.y / max(u, 0.0001), detail);

            // 4 — the interior, integrated. shaders.ts:346/371 read the internal studio once, at the exit;
            // a body with depth is not one point, so `kInteriorSteps` fixed slices are walked from the front
            // surface to the back, each gathering the studio it looks into. Front-to-back, so nothing here
            // depends on the order the samples happen to be unrolled in.
            float3 gather = float3(0.0);
            float stepLength = pathLength / float(kInteriorSteps);
            float eyeRel = halfExtent.y / max(u, 0.0001);
            for (uint i = 0u; i < kInteriorSteps; ++i) {
                float walked = (float(i) + 0.5) * stepLength;
                float3 posS = float3((p + into.xy * walked) / max(u, 0.0001),
                                     (height - walked) / max(u, 0.0001));
                float3 slice = sampleInternalStudio(posS, into, jewelTint, rearTIR ? 1.0 : 0.0,
                                                    eyeRel, detail);
                gather += slice * exp(-absorbSigma * (optical * (walked / max(pathLength, 0.001))));
            }
            gather /= float(kInteriorSteps);
            float3 through = (plate * kPlateGain + gather * kInteriorGain) * beer;

            // The rim's width, solved from the profile instead of chosen: the inset at which the bevel's
            // slope falls to `1.5`, i.e. where the surface is still more than 35° from the viewer. Inverting
            // `rise = rz*(side/bevel)/rxy` gives `side = k/sqrt(1+k²)`, so a steep edge is a thin line and
            // a shallow one is broad — the width follows the thickness gradient because it comes out of it.
            // The line's *brightness* is Schlick's, whose fifth power keeps the hottest part sub-pixel.
            float grazeK = 1.5 * rxy / max(rz, 0.001);
            float rimWidth = max(1.0, rxy * (1.0 - grazeK / sqrt(1.0 + grazeK * grazeK)));

            // 5 — the far face. The mask is the *projected* silhouette, so a body's two faces would cast
            // one outline and the whole thing would read flat however well the surface is lit. The back
            // face is the same field read one depth vector away — `toScreen((0,0,-2·halfDepth))`, the
            // projection the volume's own slice stack gets for free — and on a body turned by the idle
            // pose that offset is a fifth of its width. Its edge is the second contour a thick object
            // shows, and past it the ray is inside the *wall*, which is the long dark path a real rim has.
            float3 depthAxis = toScreen(float3(0.0, 0.0, -1.0), cosYaw, sinYaw, cosPitch, sinPitch);
            float2 backShift = depthAxis.xy * (2.0 * halfDepth) * (pixels / size);
            half4 backField = bodyLayer.sample(bodySampler, (pos.xy - backShift) / pixels);
            float backInset = float(backField.g) * maxInset;
            float backOutside = float(backField.b) * maxInset;
            // The far face fades in over its own antialiased edge. A hard `step` on the mask's coverage is a
            // one-texel staircase multiplied into a bright line — which is exactly how a rendering bug looks.
            float backEdge = (1.0 - smoothstep(0.0, rimWidth * 1.35, backInset))
                           * smoothstep(0.15, 0.85, float(backField.a));
            float backWall = smoothstep(0.0, rimWidth * 2.2, backOutside);
            // The far wall's own edge, lit from inside by the studio it just crossed.
            through += mix(jewelTint, float3(1.0), 0.45) * (backEdge * 0.95 * detail);
            // And the wall itself: two more surfaces to cross, so it is the darkest thing in the body.
            through *= mix(1.0, 0.30, backWall * 0.85 * detail);

            // 6 — the internal focus. The back surface's curvature concentrates the studio: a bundle
            // entering over one point of inset leaves over less, and the light piles up where that
            // narrowing is strongest — the second difference of the profile, times the path it acts over.
            // A real caustic, a real arc, and it lands wherever the wall turns instead of at a fixed radius.
            float probe = inset + max(0.75, rxy * 0.10);
            float bend = abs(bodyRise(probe, rxy, rz) - rise) / max(probe - inset, 0.001);
            float focus = clamp(pathLength * bend * 0.10, 0.0, 3.0);
            focus *= focus;
            float3 keyColour = mix(jewelTint, float3(1.0, 0.96, 0.90), 0.62);
            through += (gather * 0.55 + keyColour * 0.45) * (focus * 0.55 * detail);

            // Two interfaces, two Fresnel losses, and the TIR'd share going back into the glass at 0.65 of
            // its energy (shaders.ts:353-373).
            accum += through * exitWeight;
            accum += reflEnv * (beer * 1.22) * reflWeight;                    // shaders.ts:353, 371
            float tirEnergy = reflWeight * 0.65;                              // shaders.ts:358, 373
            float directTrans = exitWeight * smoothstep(0.10, -0.70, leaving.z);  // shaders.ts:372

            // 7 — the rim: two lines, both solved from the profile, and both antialiased by the same
            // coverage the silhouette uses.
            //
            // The bright one is the grazing Fresnel edge, at the width the shoulder gives it
            // (`rimWidth`, the inset where the bevel is still more than 35° from the viewer). Its core
            // is a sub-pixel line so the contour itself stays crisp when the body is 24 pt, and the
            // band behind it is the key reflected in the bevel: together they are the polished edge.
            float rimBand = 1.0 - smoothstep(0.0, rimWidth, inset);
            float rimCore = bandCoverage(inset, 0.0, max(0.30, rimWidth * 0.13), foot);
            float2 rimDir = normalize(float2(-0.55, -0.80));
            float rimFacing = 0.62 + 0.38 * clamp(dot(normalize(nS.xy + float2(1e-5f)), rimDir) * 0.5 + 0.5,
                                                  0.0, 1.0);
            float3 rimLight = mix(jewelTint, float3(0.95, 1.0, 1.0), 0.55);
            // Weighted by the Fresnel it is standing in for: the state's rim glow is a light table, not a
            // paint, so it brightens with `F1` and fades to a quarter on the face. A band of constant
            // brightness is a stroked outline however thin it is.
            accum += rimLight * (rimBand * (0.55 + pose.z * tone.z)) * rimFacing * (0.25 + 0.75 * F1);
            accum += mix(rimLight, float3(1.0), 0.30)
                   * (rimCore * smoothstep(0.25, 0.85, coverage) * 0.55 * (0.35 + 0.65 * rimFacing));

            // The second line: where the light stops leaving the glass. `criticalInset` is the point of
            // the bevel whose normal is at the critical angle — solved from `rxy`/`rz`, so it sits one
            // rim inside the bright one on every pose and every size instead of wherever a dot-product
            // threshold happened to land, which is why the two lines were sometimes one. Dark, because
            // a TIR'd ray comes back off the wall carrying the studio behind the body, which is the
            // darkest thing in the room.
            float darkInset = criticalInset(rxy, rz);
            float darkWidth = max(0.45, rimWidth * 0.20);
            float darkLine = bandCoverage(inset, darkInset, darkWidth, foot);
            darkLine *= smoothstep(0.30, 0.75, bodySide(inset, rxy));
            accum = mix(accum, accum * 0.30 + keyColour * 0.05,
                        clamp(darkLine, 0.0, 1.0) * 0.78 * detail);

            // A light page's hairline, outside the rim, so the silhouette holds on paper: the same job the
            // Canvas path's `outerHairline` does, done at the outermost point of the falloff.
            if (tone.x > 0.001) {
                float hair = (1.0 - smoothstep(0.0, max(0.75, rimWidth * 0.5), inset)) * tone.x;
                accum = mix(accum, float3(0.06), clamp(hair, 0.0, 1.0) * 0.55);
            }

            // The exposure, before anything is mapped: a gain on the light, not on the pixels.
            accum *= max(tone.y, 0.0);

            // shaders.ts:381-388 — the tone map, and the roll to white on a highlight that peaks.
            float peak = max(accum.r, max(accum.g, accum.b));
            float3 col = accum;
            if (peak > 0.0001) {
                float mapped = peak / (1.0 + peak * 0.48);
                col = accum * (mapped / peak);
                float whiteRoll = smoothstep(2.2, 5.2, peak);
                col = mix(col, float3(mapped), whiteRoll * 0.80);
            }

            // shaders.ts:390-399 — how much of the pixel the surface keeps. Upstream's edge transparency
            // between the middle and the rim, its `directTrans` (what got through, so the page shows) and
            // its `tirEnergy` (what the wall turned back, so it does not); the luminance term is added, and
            // the rim adds its own, so the body stays see-through where it is thick and solid where the
            // light catches the edge.
            float lum = max(col.r, max(col.g, col.b));
            float edgeTransparency = mix(0.36, 0.68, pow(1.0 - cos1, 1.55));
            float alpha = clamp(edgeTransparency * 1.15
                                - 0.06 * clamp(directTrans, 0.0, 1.0)
                                - 0.08 * weight
                                + 0.30 * smoothstep(0.30, 0.95, lum)
                                + 0.16 * clamp(tirEnergy, 0.0, 1.0)
                                + kAbsorptionOpacity * (1.0 - lumThrough)
                                + 0.30 * rimBand,
                                0.34, 0.97);

            // 8 — the page, from the same field. Two things happen where glass meets paper: a short
            // contact shadow under the body, and the caustic — the light that crossed the bottom wall
            // and landed past the footprint, at the distance `causticLanding` solves for.
            //
            // `outside` is the distance from the drawn silhouette, so both follow the outline exactly
            // rather than an ellipse fitted to the box. The shadow is black at its own opacity, so the
            // page goes darker; the caustic is light, so it goes warmer. They are the same field.
            // Contact is two terms, not one: a dark line where the glass touches paper (a point or two
            // wide, and the darkest thing on the page) and a short penumbra behind it. One soft
            // exponential was neither — it darkened too slowly to read as contact and too little to
            // anchor the body.
            float tight = exp(-outside / max(0.70, foot * 1.4)) * smoothstep(0.0, 0.28, outside) * 0.80;
            float penumbra = exp(-outside / max(2.0, foot * 4.0)) * smoothstep(0.0, 0.6, outside) * 0.24;
            float shadowAlpha = tight + penumbra;
            // Where the wall's light lands: an arc *parallel to the silhouette* at the solved
            // distance — focused by the thickness, not blurred out of the middle. Its inner edge is
            // the fold, where the mapping from the wall to the page turns over; its outer edge is a
            // short falloff, because the focus has a width.
            float landing = causticLanding(rxy, rz, flatZ);
            float arcWidth = max(0.60, landing * 0.055);
            float arc = exp(-pow((outside - landing) / arcWidth, 2.0));
            // Which way this part of the contour faces, from the field itself: the gradient of
            // `outside` is the outward normal of the silhouette, so its downward component is how much
            // of the wall stands over the page. It is smooth along the contour and costs two
            // derivatives — no extra sample, and no hand-placed ellipse. The wall's light goes down, so
            // the arc dies around the bottom corners instead of ringing the body.
            float2 outwardN = normalize(float2(dfdx(outside), dfdy(outside)) + float2(1e-6f));
            float under = clamp(outwardN.y, 0.0, 1.0);
            float facing = under * under;
            // A coarse gate on the same thing, so a horizontal stretch of contour below the ears (where
            // the normal is ambiguous) cannot light up.
            float below = smoothstep(0.16, 0.62, (position.y - centre.y) / max(halfExtent.y, 1.0))
                        * smoothstep(0.10, 0.55, facing);
            // A caustic has a *hard* inner edge and a short outer one: inside the focal line the wall's
            // light has not converged yet, past it the focus has a width. Cutting the inner side and
            // letting only the outer Gaussian through is what makes it a line instead of a halo.
            arc *= smoothstep(landing - arcWidth * 2.4, landing - arcWidth * 0.60, outside);
            // How bright: the wall's own transmission. A short path through amber is nearly white, so
            // the arc is warm; the longer the wall, the more of it the tint eats. Same absorption as
            // the body, at the wall's own path — no separate colour for the light on the page.
            float wallPath = 2.0 * bodyHeight(criticalInset(rxy, rz), rxy, rz, flatZ);
            float3 wallBeer = absorptionAlong(opticalThickness(wallPath, halfDepth), absorbSigma);
            float3 causticLight = mix(jewelTint, float3(1.0, 0.96, 0.90), 0.68) * wallBeer * 1.55;
            float caustic = arc * below * smoothstep(0.0, 0.5, outside) * 0.95;
            // The light that crossed the thin wall and did not converge: a warm falloff from the
            // footprint out to the arc. It is what binds the two together — without it the page under
            // the body is pure black and the caustic reads as a detached neon line, because on a dark
            // page a shadow is invisible while the light that caused it is not.
            float nearPool = exp(-outside / max(1.1, landing * 0.60)) * below
                           * smoothstep(1.1, 3.2, outside) * 0.34;
            // The fold's dark inner edge: the arc gathers light on one side and starves the other, and
            // that contrast is what makes a caustic a curve rather than a glow.
            float foldDark = exp(-pow((outside - max(landing - arcWidth * 1.55, 0.4))
                                      / max(0.45, arcWidth * 0.60), 2.0));
            foldDark *= below * smoothstep(0.0, 0.5, outside) * 0.55;

            col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));               // shaders.ts:408

            // A half-bit dither on the way out. The body's gradients run smooth over hundreds of pixels
            // into an 8-bit target, so without this they band — and banding is a flaw a person reads as
            // "plastic", because nothing cast has a gradient with steps in it. Alpha gets its own,
            // because a premultiplied target quantises the two separately.
            float dither = fract(sin(dot(pos.xy, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
            col = max(col + dither / 255.0, float3(0.0));
            alpha = clamp(alpha + dither / 255.0, 0.0, 1.0);

            // Never wider than the drawing itself: the mask's alpha is the silhouette, and a shader that
            // paints past it would put glass outside the bot. Last, so the dither above cannot give a
            // pixel the body does not cover a speck of opacity.
            alpha *= coverage;

            // Premultiplied over whatever is behind the view, back to front: the contact shadow and the
            // fold's dark edge lie on the page (black at an opacity, so they darken it), and the arc's
            // light is added over them. A pixel outside the body is `1 - alpha`, so nothing painted
            // here can reach through the glass itself.
            // The page's light is linear and the body's pixels are already encoded (`col`), so the
            // caustic is encoded once here. Added in the wrong space it is a dull red smear — which is
            // what a caustic measured in linear light and written into an sRGB sum looks like.
            float3 causticRGB = pow(clamp(causticLight, 0.0, 1.0), float3(1.0 / 2.2));
            float page = 1.0 - alpha;
            float shadeA = clamp((shadowAlpha + foldDark) * page, 0.0, 1.0);
            float arcA = clamp(caustic * page, 0.0, 1.0);
            float poolA = clamp(nearPool * page, 0.0, 1.0);
            float3 outRGB = col * alpha + causticRGB * (arcA + poolA * 0.55);
            float outA = clamp(alpha + shadeA * (1.0 - alpha) + arcA + poolA * 0.55, 0.0, 1.0);
            return half4(half3(outRGB), half(outA));
        }
"""
}
#endif
