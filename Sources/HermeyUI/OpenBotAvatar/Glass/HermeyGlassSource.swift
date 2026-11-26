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
    static let msl = """
        //
        //  HermeyGlassSource.swift
        //
        //  The glass material as a lit, refracting surface: the app surfaces' body, shaded by a Metal
        //  fragment function instead of a stack of `Canvas` gradients.
        //
        //  ## Where this comes from
        //
        //  The terms and every constant below are ported from upstream's `packages/core/src/dom/glass/
        //  shaders.ts` (the WebGL pass its `GlassMaterial` runs over the volume's distance field). What is
        //  *not* ported is its mechanics: upstream ray-marches a 3-D SDF texture it uploads per definition,
        //  which no fragment pass over a flat body can receive (its arguments are the body's box, not a
        //  volume). So the surface here is the volume's own height profile — `OpenBotAvatarVolume`'s
        //  `surfaceHeight`, the same rounded inset the Canvas path fills — evaluated analytically at the
        //  pixel.
        //
        //  Ported, with the line each constant is read from:
        //
        //  * `IOR = 1.50` — shaders.ts:46;
        //  * `F0 = 0.04` and `fresnelSchlick` — shaders.ts:47 and shaders.ts:137-139 (Schlick, fifth power);
        //  * the studio softboxes and their weights — shaders.ts:152-161: key `(-0.60,-0.74,-0.30)`
        //    half `(0.70,0.155)` soft `0.090` tilt `-0.52` at `13.0`, rim `(-0.24,-0.76,-0.60)`
        //    half `(0.70,0.095)` soft `0.075` tilt `-0.22` at `8.0`;
        //  * the flat-on key softbox and its `1.45` weight — shaders.ts:273, the one upstream uses for the
        //    eye's bead: it is the only lobe whose centre is on the viewer's side (`+z`), and so the only
        //    one a surface facing the viewer can reflect;
        //  * the room, the floor bounce and the perimeter side glow — shaders.ts:147-149 and 160-162;
        //  * the internal studio: the cyclorama (167-172), the caustic tabletop pool (175-185) and the four
        //    dome lobes with their exponents and weights (188-194), and `tirBoost` `mix(0.92,1.22,isTIR)`
        //    (193);
        //  * the refraction itself, `refract(rd, n1, 1.0/IOR)` and `weight = 1 - F1` — shaders.ts:289-290;
        //  * Beer-Lambert absorption, `absorbSigma = -log(max(transColor,0.12)) * 0.62 + 0.08` — shaders.ts:
        //    421-422 — and the optical-thickness compression `totalPath / (refScale + totalPath*0.30)` with
        //    `refScale = max(halfDepth*2.2, 14)` — shaders.ts:340-342;
        //  * the tone map `peak/(1 + peak*0.48)` and the white roll `smoothstep(2.2,5.2,peak)*0.80` —
        //    shaders.ts:381-388;
        //  * the alpha composite `mix(0.36,0.68,pow(1-cos,1.55))` and its `0.28…0.98` clamp —
        //    shaders.ts:391-399 — and the `1/2.2` gamma at 408.
        //
        //  ## What is deliberately different, and why
        //
        //  The first shader on this path drew the body but did not *look* like glass: an opaque, glossy
        //  coloured blob. Three of upstream's terms only work in upstream's own setting, and each of them
        //  had to be given a stand-in here. Each is marked at its use below.
        //
        //  * **The refracted ray lands on a studio plate, not on our own fill.** Upstream's ray leaves the
        //    volume into the room it marched; ours used to sample the layer the body was drawn into — which
        //    is a flat fill of the body's own tint. So "what is behind the glass" *was the glass*, at 96 %
        //    opacity in the middle, which is exactly the opaque blob. The plate below
        //    (`sampleGlassPlate`) is the same cyclorama, key and caustic pool, laid out positionally in the
        //    body's plane; the refraction offset moves it, so the offset is visible at all, and the body's
        //    tint reaches it only through Beer-Lambert.
        //  * **The tint is decoded to linear light once.** The `Canvas` hands us the sRGB value it would
        //    have filled; the optics below are linear (as upstream's are), and the old code fed the sRGB
        //    value straight in and gamma-encoded it again at the end — a pastel, double-gamma gloss. One
        //    `pow(2.2)` in, the existing `pow(1/2.2)` out.
        //  * **The plateau gets a key, the rim gets a direction.** Upstream's key softboxes sit in front of
        //    the camera, so only a *steep* bevel reflects them: on a flat dome they contribute nothing and
        //    the body reads as gloss. The flat-on softbox from shaders.ts:273 lights the face; the rim band
        //    is weighted toward the side that faces the key, so the edge catches light instead of glowing
        //    evenly.
        //  * **A contact shadow, drawn by this pass, just outside the silhouette.** Upstream's glass sits on
        //    a page that already has one; our pass is the only thing drawn over the ribbons, so the body
        //    would otherwise float. It is ours, not upstream's, and it is the only dark thing here.
        //  * **The alpha composite is upstream's, re-weighted.** `edgeTransparency` and the `0.28…0.98`
        //    clamp are upstream's; the luminance term is halved (`0.30` from `0.52`, over `0.35…1.0` rather
        //    than `0.16…0.90`) and the rim adds `0.26`, so the middle of the body stays see-through and the
        //    edge stays solid. With upstream's weighting the body clamped shut over our dark canvas.
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
        //  The texture is a **silhouette**, not a fill: white, with the outline in its alpha. The fragment
        //  reads only that alpha, so the flat painted body cannot appear under the shader even by accident —
        //  there is no tint in the texture to appear. `Tools/glass-proof` renders it, offscreen, at 24, 48
        //  and 200 pt.
        //
        #include <metal_stdlib>

        using namespace metal;

        // MARK: - Upstream's constants

        /// shaders.ts:46 — the refractive index of the glass upstream draws.
        constant float kIOR = 1.50;
        /// shaders.ts:47 — Schlick's reflectance at normal incidence for glass.
        constant float kF0 = 0.04;

        /// `smoothstep` with its edges given the way upstream writes them (high edge first). MSL leaves
        /// `smoothstep` undefined when `edge0 > edge1`, so every reversed ramp in shaders.ts goes through
        /// here rather than being copied with its arguments swapped in the wrong direction.
        static inline float smoothstepR(float edge0, float edge1, float x) {
            return 1.0 - smoothstep(edge1, edge0, x);
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
        /// was drawn into — so the same light is laid out positionally here and the refracted offset
        /// moves it. Ported: the cyclorama's `mix(vec3(0.022), tint*0.22, 0.55)` and its vertical fade
        /// (shaders.ts:167-172), the caustic pool's `exp(-r2*0.85)` and `exp(-r2*2.4)` hot core
        /// (shaders.ts:175-185), and the key's angles and `13.0` weight (shaders.ts:152, 161).
        /// Ours: where in the plane each sits, and the gaussian widths, so the whole studio stays inside
        /// the body at 24 pt as well as at 200.
        static inline float3 sampleGlassPlate(float2 uv, float3 jewelTint, float detail) {
            float upFade = smoothstepR(0.95, -0.95, uv.y);                    // shaders.ts:171
            float3 col = mix(float3(0.022), jewelTint * 0.22, 0.55)
                       * (0.65 + 0.50 * upFade) * 2.40;

            // The key: the wide, soft box high and to the left (shaders.ts:152), read at 13.0
            // (shaders.ts:161) and brought down to what survives the tone map at 24 pt.
            float2 keyP = float2((uv.x + 0.34) / 0.95, (uv.y + 0.58) / 0.55);
            col += float3(1.0) * (exp(-dot(keyP, keyP) * 1.35) * 13.0 * 0.055);

            if (detail > 0.5) {
                // The narrow right-hand strip (shaders.ts:153): the second edge the eye reads the
                // refraction against as the body turns.
                float strip = exp(-pow((uv.x - 0.86) / 0.20, 2.0)) * smoothstepR(0.80, -0.95, uv.y);
                col += float3(0.90, 0.96, 1.0) * (strip * 2.40);
            }

            // The caustic tabletop pool beneath the body (shaders.ts:175-185), in the plane.
            float2 c = float2(uv.x / 0.90, (uv.y - 0.94) / 0.34);
            float r2 = dot(c, c);
            col += jewelTint * ((1.05 * exp(-r2 * 0.85) + 0.48 * exp(-r2 * 2.4)) * 1.55);
            return col;
        }

        // MARK: - The body's shape

        /// A rounded box signed distance, negative inside: the part's box with its own inset radius as the
        /// corner. The volume's outline is a blob, a box or a face, and this is the form that covers all
        /// three; the *drawn* silhouette is still the body's own outline (the mask's alpha).
        static inline float sdRoundedBox(float2 p, float2 halfExtent, float r) {
            float2 q = abs(p) - (halfExtent - r);
            return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
        }

        /// `OpenBotAvatarVolume.Part.surfaceHeight` — the front surface rising from the outline to a plateau
        /// `halfDepth` in the middle, over the inset `rxy` and the rise `rz`.
        static inline float surfaceHeight(float inset, float rxy, float rz, float halfDepth) {
            if (rxy <= 0.0 || inset >= rxy) return halfDepth;
            float k = 1.0 - max(inset, 0.0) / rxy;
            return halfDepth - rz + sqrt(max(0.0, 1.0 - k * k)) * rz;
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
        ///               is. Its alpha is the true silhouette and the only thing this function reads from it.
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

            // Where the body is, and nothing else. The texture is a white fill, so a fragment that
            // accidentally read its colour would come out white — the painted body cannot leak in here,
            // which is the guard the old flat-fill texture could not offer.
            float coverage = float(bodyLayer.sample(bodySampler, pos.xy / pixels).a);

            // The tint arrives as the sRGB value the `Canvas` would have filled; the optics below are
            // linear light, as upstream's are. Decoded once here, encoded once at the end.
            float3 tint = pow(max(uniforms.tint.rgb, float3(0.0)), float3(2.2));

            float2 halfExtent = max(shape.xy, float2(0.5));
            float corner = min(min(shape.z, halfExtent.x), halfExtent.y);
            float2 centre = profile.zw;
            float2 p = position - centre;
            float halfDepth = max(shape.w, 0.0);

            // How far inside the form this pixel is. A pixel outside the rounded form but inside the drawn
            // outline — a blob's corner, a fin — is at the edge of the surface (inset 0, the normal at the
            // rim, the rim band at its widest); the mask's own alpha is what limits the shaded region, so
            // nothing here has to decide where the bot stops.
            float sd = sdRoundedBox(p, halfExtent, corner);
            float inset = max(-sd, 0.0);

            // The height field, and the normal it implies: dh/d(inset) is the closed form of `surfaceHeight`,
            // and the gradient of the distance is the direction the dome falls away in.
            float2 gradSd = float2(sdRoundedBox(p + float2(0.75, 0.0), halfExtent, corner)
                                 - sdRoundedBox(p - float2(0.75, 0.0), halfExtent, corner),
                                   sdRoundedBox(p + float2(0.0, 0.75), halfExtent, corner)
                                 - sdRoundedBox(p - float2(0.0, 0.75), halfExtent, corner)) / 1.5;

            float rxy = max(profile.x, 0.001);
            float rz = max(profile.y, 0.0);
            float dh = 0.0;
            if (inset < rxy && rz > 0.0) {
                float k = 1.0 - inset / rxy;
                dh = rz * k / (rxy * sqrt(max(1e-3, 1.0 - k * k)));
            }
            float3 nModel = normalize(float3(dh * gradSd.x, dh * gradSd.y, 1.0));

            float cosYaw = cos(pose.x), sinYaw = sin(pose.x);
            float cosPitch = cos(pose.y), sinPitch = sin(pose.y);
            float3 nS = toScreen(nModel, cosYaw, sinYaw, cosPitch, sinPitch);

            float detail = pose.w;
            float cos1 = clamp(nS.z, 0.0, 1.0);
            float F1 = fresnelSchlick(cos1);

            // 0 at the silhouette's edge, 1 on the plateau: the body's own optical thickness, which is
            // what separates a solid piece of glass (thin, bright rim; deep, tinted middle) from a dome of
            // tinted gloss.
            float height = surfaceHeight(inset, rxy, rz, halfDepth);
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

            // The key, seen flat-on. Upstream's two softboxes sit in front of the camera, so only a
            // steep bevel reflects them and a dome facing us gets no highlight at all; this third lobe
            // (shaders.ts:273, the eye's bead) is centred on the viewer's side, so the plateau catches it.
            float keyFlat = softbox(reflDirS, float3(-0.52, -0.68, 0.52), float2(0.22, 0.28), 0.10, -0.35);
            accum += float3(1.0) * (keyFlat * 1.45);                          // shaders.ts:273

            float weight = 1.0 - F1;

            // Upstream's own unit: the body spans 100 of them, so every optical constant above is used at
            // the scale it was tuned at however many points this surface is drawn in.
            float u = max(size.x, size.y) / 100.0;
            float halfDepthU = halfDepth / max(u, 0.0001);

            // 2 — refraction (shaders.ts:289-345). The refracted ray's travel is the offset that moves the
            // studio plate; where the ray reflects internally the plate is read as a reflection instead.
            float3 rayDir = refract(rdS, n1S, 1.0 / kIOR);
            float opticalDist;
            float3 exitDirS;

            bool tir = length(rayDir) < 0.001;
            if (tir) {
                exitDirS = reflect(rdS, n1S);
                opticalDist = 1.15;
            } else {
                rayDir = normalize(rayDir);
                exitDirS = normalize(float3(rayDir.xy, -abs(rayDir.z)));
                float totalPathU = (2.0 * halfDepthU) / max(0.30, cos1);
                float refScale = max(halfDepthU * 2.2, 14.0);                 // shaders.ts:340-342
                opticalDist = totalPathU / (refScale + totalPathU * 0.30);
            }

            float3 refractedRay = tir ? reflect(rdS, n1S) : rayDir;
            float2 travel = refractedRay.xy * (2.0 * halfDepth * 1.6 / max(0.35, cos1));
            travel = clamp(travel, float2(-8.0), float2(8.0));

            // A solid piece of glass is a lens: what is behind it is pulled in toward the middle and
            // displaced by the refracted ray. `-1…1` across the body's box, in the same points as `p`.
            float2 boxUV = p / halfExtent;
            float2 plateUV = boxUV * mix(0.94, 0.76, thick) + travel / halfExtent;
            float3 plate = sampleGlassPlate(plateUV, jewelTint, detail);

            // Beer-Lambert through the body's own thickness: thin at the rim (bright), deep at the plateau
            // (the tint's own colour, darkened by its absorption).
            float3 beer = exp(-absorbSigma * (0.55 + 2.60 * thick));
            float3 through = plate * beer * mix(1.30, 0.62, thick);

            // The light the body gathers in itself (the internal studio), strongest where the body is
            // thickest so it reads as depth rather than a wash.
            float3 internal = sampleInternalStudio(float3(p / max(u, 0.0001), 0.0), exitDirS,
                                                   jewelTint, tir ? 1.0 : 0.0,
                                                   halfExtent.y / max(u, 0.0001), detail);
            through += internal * (0.24 + 0.36 * thick);
            accum += through * weight;

            // 3 — the rim. Upstream's is the Fresnel term at the edge of a real 3-D solid; this carries the
            // state's rim opacity (the eight states' light table) at the widest point of the falloff, and
            // leans toward the side the key is on, so the edge catches light instead of glowing evenly.
            float rimWidth = max(1.0, 0.035 * max(size.x, size.y));
            float rimBand = 1.0 - smoothstep(0.0, rimWidth, inset);
            float2 rimDir = normalize(float2(-0.55, -0.80));
            float rimFacing = 0.55 + 0.45 * clamp(dot(normalize(nS.xy + float2(1e-5)), rimDir) * 0.5 + 0.5,
                                                  0.0, 1.0);
            float3 rimLight = mix(jewelTint, float3(0.95, 1.0, 1.0), 0.55);
            accum += rimLight * (rimBand * (0.55 + pose.z * tone.z)) * rimFacing;

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
            // between the middle and the rim; the luminance term is halved and the rim adds its own, so
            // the body stays see-through where it is thick and solid where the light catches the edge.
            float lum = max(col.r, max(col.g, col.b));
            float edgeTransparency = mix(0.36, 0.68, pow(1.0 - cos1, 1.55));
            float alpha = clamp(edgeTransparency
                                - 0.10 * weight
                                + 0.30 * smoothstep(0.35, 1.00, lum)
                                + 0.26 * rimBand,
                                0.28, 0.98);

            // Never wider than the drawing itself: the mask's alpha is the silhouette, and a shader that
            // paints past it would put glass outside the bot.
            alpha *= coverage;

            // The contact shadow: a soft pool under the base, plus a dark band just outside the outline.
            // Ours — upstream's glass sits on a page that already has one, and this pass is the only thing
            // drawn over the ribbons, so without it the body floats.
            float2 shadowP = float2(p.x / max(halfExtent.x * 0.86, 0.5),
                                    (p.y - halfExtent.y * 0.96) / max(halfExtent.y * 0.16, 0.8));
            float shadowShape = 1.0 - smoothstep(0.15, 1.0, length(shadowP));
            float contact = (1.0 - smoothstep(0.0, max(1.5, 0.055 * max(size.x, size.y)), max(sd, 0.0)))
                          * step(0.0, sd);
            float shadowAlpha = max(shadowShape * 0.55, contact * 0.30);

            col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));               // shaders.ts:408

            // Premultiplied over whatever is behind the view: the glass, and the shadow it sits in.
            float3 outRGB = col * alpha;
            float outA = alpha + shadowAlpha * (1.0 - alpha);
            return half4(half3(outRGB), half(outA));
        }
"""
}
#endif
