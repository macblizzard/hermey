import Foundation
import SwiftUI

/// The bot's own generated avatar, edited inside the bot's settings — the same view on the Mac and
/// the phone, so the two shells cannot grow different editors.
///
/// What it offers, in the order a person moves through it:
///
/// * a **live preview** of the draft, at the bot's current state, which is the only thing here that
///   answers "what will it look like"; it is drawn large enough (200 pt) that a glass body's
///   streak and catchlight are visible, because a material chosen at thumbnail size is a guess;
/// * a **state strip** — the eight activity states as chips, plus one **Example** chip that draws a
///   state of the host's own (`AvatarStateDefinition`), because a renderer that can be told a state
///   by name and a definition of its own is only useful if the editor can show both. A tap moves the
///   preview above; nothing is saved and no bot's activity is touched, so trying `blocked` on a bot
///   that is working cannot make the app say it is blocked. The strip wraps into rows rather than
///   scrolling sideways, so it fits a phone at the default text size and cannot push the sheet
///   around when the selection changes (a chip's width depends on its word, never on being chosen);
/// * a **material** choice — the rows of `BotAvatarMaterialSpec.all`, so the list grows with the
///   table and this view never hard-codes two cases — and, under Glass, one line saying which of
///   glass's two drawings *this* device will really use, asked of `BotAvatarGlassRoute` rather than
///   promised by the copy. Glass on a phone and glass in a preview process are not the same surface,
///   and a row that called both "3D" would be lying about one of them;
/// * **twelve presets** to start from (a blob, a box, a mug, a sprout, a cat, an egg, a bottle, a
///   star, a droplet, an hourglass, an open book and a mushroom) and a **Random** button beside
///   them that applies a shape, a material and a colour at once — all three read from the tables
///   this view already draws from (`OpenBotAvatarRandom`), so there is no second palette here and a
///   random face is always one Save can store;
/// * a **Classic** row — the fixed faces the app shipped before it could draw one
///   (`BotAvatarClassics`: the eight bodies × palette colours, the same strings the old shape picker
///   wrote). The two families are alternatives, never a pair: picking a Classic face clears the
///   stored definition, and picking a preset or Random clears the Classic face, in one save
///   (`BotAvatarSelection`). The row says which family the bot is on now, because a swatch row with
///   no "you are here" is a decoration;
/// * a **JSON box** for a definition copied from upstream's editor, with the contract's own reasons
///   shown inline when it cannot be imported;
/// * **colour and eye placement** — x, y, spacing, scale — which edit the definition live;
/// * **Save** and **Reset**. Reset deletes both halves — the drawn avatar and the fixed face — so
///   the bot goes back to the face its id derives.
///
/// **Nothing here writes the bot's config or its soul.** The only thing this view can save is a
/// face: a drawn avatar, or the one string `bots.color` holds. That is deliberate: a face is
/// decoration, and decoration must not be able to change how a bot thinks.
public struct OpenBotAvatarEditor: View {
    public let botID: String
    public let botName: String
    /// What the host has stored now, or nil. Seeds the draft, and decides whether Reset is offered.
    public let stored: BotAvatarDocument?
    /// The fixed face the host stores for this bot (`bots.color`), or nil when its id derives one.
    /// Seed of the Classic row's selection, and the other half Reset clears.
    public let face: BotFaceChoice?
    /// The state the preview shows when the sheet opens: the host may pass what the bot is doing now
    /// (the Mac does), and the default — `.idle`, which is what the phone passes — is the calm face.
    /// It seeds the strip's first selection and nothing else: the strip is a preview control, so the
    /// choice lives in this view and never travels back to a bot's activity.
    public var previewState: OpenBotAvatarState
    /// Saves one family — or, with nil, clears both. Errors are shown inline.
    public let save: (BotAvatarSelection?) async throws -> Void

    /// The side the preview is drawn at, in points. It is the number `facePreview` passes as `size:`
    /// — the material row asks the glass route about it, because "will this device draw glass as a
    /// lit surface" is a question about the size it is drawn at. A guard keeps the two equal.
    static let previewSide: Double = 200

    /// Which family the draft is in. The preview, the Save button and the dirty check all follow
    /// it, so "what will this bot wear" has one answer on this screen.
    @State private var family: BotAvatarSelection.Family
    /// The Classic face chosen in this session, or the one the host holds.
    @State private var classicChoice: BotFaceChoice?
    @State private var draft: BotAvatarDefinition
    @State private var colorHex: String?
    @State private var material: BotAvatarMaterial
    @State private var jsonText: String
    @State private var jsonStatus: JSONStatus = .ok
    @State private var saving = false
    @State private var resetting = false
    @State private var saveError: String?
    @State private var savedNote: String?
    /// What the preview draws: one of the eight names, or the example definition. It is a preview
    /// choice, so it is a `@State` here and nowhere else — no store, no bot, no activity.
    @State private var previewChoice: OpenBotAvatarStateChoice
    /// The last pick the Random button applied, as `OpenBotAvatarRandomPick.combination`, so the
    /// next press cannot land on the same shape + material + colour.
    @State private var lastRandomPick: String?

    /// A person who has asked for less transparency gets the painted glass. Read here so the material
    /// row can say what the preview above it will really draw — the same environment
    /// `OpenBotAvatarView` reads for itself.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private enum JSONStatus: Equatable {
        case ok
        case failed([String])
    }

    /// The draft's colour, falling back to the house colour for the swatch.
    private var draftColor: Color {
        colorHex.flatMap(OpenBotAvatarColor.color(hex:)) ?? OpenBotAvatarRenderer.defaultColor
    }

    private var dirty: Bool {
        switch family {
        case .classic:
            // A bot with a drawn avatar is on the *other* family, so any Classic pick is a change —
            // even the face it still has stored behind the drawing, or a bot could not come back.
            if stored != nil { return true }
            return classicChoice != face
        case .custom:
            guard let stored else { return true }
            return stored.definition != draft || stored.color != colorHex || stored.material != material
        }
    }

    public init(botID: String,
                botName: String,
                stored: BotAvatarDocument?,
                face: BotFaceChoice? = nil,
                previewState: OpenBotAvatarState = .idle,
                save: @escaping (BotAvatarSelection?) async throws -> Void) {
        self.botID = botID
        self.botName = botName
        self.stored = stored
        self.face = face
        self.previewState = previewState
        self.save = save
        // A bot with nothing stored starts on the first preset: an editor that opens on an empty box
        // asks the person to invent a path before they can press Save.
        let seed = stored?.definition ?? OpenBotAvatarPresets.blob
        _draft = State(initialValue: seed)
        _colorHex = State(initialValue: stored?.color)
        // Solid first: a bot that has never chosen a material is the face it already wears.
        _material = State(initialValue: stored?.material ?? .solid)
        _jsonText = State(initialValue: (try? seed.jsonText()) ?? "")
        // The strip opens on the state the host passed, which is `idle` unless a surface knew what
        // the bot was doing. A tap moves it; nothing else in this view reads or writes a bot's state.
        _previewChoice = State(initialValue: OpenBotAvatarStateChoice(previewState))
        // Which family the bot is on now, from the host's own two answers: a stored definition wins
        // on every surface, so a bot that has one is on the drawn family whatever else is stored.
        // A bot with neither is on the Classic family — the face its id derives — and the row shows
        // which of the eight it would replace.
        _family = State(initialValue: BotAvatarSelection.stored(document: stored, face: face)?.family
            ?? .classic)
        _classicChoice = State(initialValue: face)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            preview
            // Both doors are always here: the presets lead to the drawn family, the classics to the
            // fixed one, and a tab that hid the door it is not standing in would be a one-way trip.
            presets
            classics
            // Everything below only edits a *drawn* avatar. Shown while the draft is a classic face
            // they would be controls that change nothing and a Save that stays disabled, which is
            // how a person concludes the tab is broken.
            if family == .custom {
                materialRow
                jsonBox
                controls
            }
            actions
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 200 pt, not a thumbnail: a glass body's streak is ~1.5 pt wide and its eye
            // catchlight is 1 pt, and both vanish below the thresholds the renderer applies, which
            // would make the choice a guess. It sits on its own row so the same layout works in a
            // 520 pt sheet and on a phone. The preview is a themed surface, so its rim follows the
            // scheme like every other drawing in the app.
            facePreview
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                        .fill(Tokens.canvas)
                )
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(alignment: .center, spacing: 10) {
                Text(previewTitle)
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                if family == .custom {
                    Text("\(Int(draft.eyes.x.rounded())) · \(Int(draft.eyes.y.rounded())) · spacing \(String(format: "%.1f", draft.eyes.spacing)) · ×\(String(format: "%.2f", draft.eyes.scale))")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textSecondary)
                }
                Spacer(minLength: 0)
            }
            // The strip belongs to the preview, not to a settings section: it is how the person asks
            // the drawing above "and what do you look like while you think". Only the drawn family
            // has states to show — a Classic face is one body and one palette, held at rest.
            if family == .custom {
                stateStrip
            }
            Text(previewNote)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The face the draft would leave the bot wearing.
    ///
    /// Two drawings, because there are two families: the drawn avatar's own renderer, or the
    /// shape-and-palette face — the same `BotAvatarView` every other surface uses, with
    /// `ignoresStoredAvatar` so a preview of the *other* family is not overwritten by the definition
    /// this bot already has.
    @ViewBuilder
    private var facePreview: some View {
        switch family {
        case .classic:
            BotAvatarView(identity: botID,
                          color: classicChoice?.raw,
                          activity: .idle,
                          size: 200,
                          animates: false,
                          label: "\(botName)'s avatar",
                          ignoresStoredAvatar: true)
        case .custom:
            // The strip's choice goes straight in as `state:` — one of the eight names or the
            // example definition, which is the same parameter the app passes a bot's real state
            // through. Nothing is keyed on it: a change of state must not remount this view, because
            // the animator inside it is what eases the change, and the model it draws is cached by
            // the definition (`OpenBotAvatarModel.model(for:)`), so tapping a chip re-decodes nothing.
            OpenBotAvatarView(definition: draft,
                              color: colorHex,
                              material: material,
                              state: previewChoice,
                              size: 200,
                              label: "\(botName)'s avatar")
        }
    }

    /// "Blob" or "Pebble · Emerald": the name of what the preview is drawing.
    private var previewTitle: String {
        switch family {
        case .custom:
            return draft.name
        case .classic:
            let resolved = classicChoice?.identity(for: botID)
                ?? BotAvatarIdentity.resolve(identity: botID)
            let palette = BotAvatarPalette.match(resolved.color.hex)?.name
                ?? resolved.color.hex.uppercased()
            return "\(resolved.shape.name) · \(palette)"
        }
    }

    /// What pressing Save will do, in one sentence, for the family the draft is in.
    private var previewNote: String {
        switch family {
        case .custom:
            return "Preview shows the state you pick. Every state edits the same definition — the avatar is one drawing, not eight."
        case .classic:
            return "Classic face: one of the bodies and palette colours this app already ships. Saving it clears any drawn avatar this bot has."
        }
    }

    // MARK: - State strip

    /// The eight states — and one of a host's own — as chips under the preview.
    ///
    /// **Why a strip and not a menu.** A state is the part of a face that changes while it is worn,
    /// and a menu hides seven of the eight behind a tap and a popover: a person comparing `waiting`
    /// with `blocked` would do it one popover at a time, and could not see both drawings. Nine short
    /// words are cheap to show, and each one is a recognisable face at 200 pt.
    ///
    /// **Why it wraps.** Nine chips at the default text size come to roughly 540 pt, so they are not
    /// one row on a 393 pt phone. The alternatives were a horizontal scroll — which hides the Example
    /// chip past the edge, on the one platform where it must be discoverable — or shrinking the words
    /// below the type scale. `GridItem(.adaptive(minimum:))` wraps into rows of equal columns instead:
    /// four across a phone, five across the Mac's 520 pt sheet, with `minimumScaleFactor` so a longer
    /// word at a larger text size shrinks instead of truncating. Equal columns are also what keeps
    /// the sheet still: a chip's width comes from its column, never from its word or from being
    /// selected, so a tap cannot reflow the strip.
    ///
    /// **The ninth chip** is `OpenBotAvatarExampleState`: a real `AvatarStateDefinition`, drawn by
    /// the same renderer as the eight, so the state API 0.5.1 added is visible in the product rather
    /// than only in the source. It is a chip and not its own row because it is the same kind of thing
    /// as the other eight — a state to look at — and a row of one would read as a setting.
    private var stateStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
            ForEach(OpenBotAvatarState.allCases, id: \.self) { activity in
                stateChip(OpenBotAvatarStateChoice(activity), title: activity.rawValue.capitalized)
            }
            stateChip(OpenBotAvatarStateChoice(OpenBotAvatarExampleState.definition), title: "Example")
        }
    }

    /// One chip: its word in the house type and tokens, and a selection that changes fill, text
    /// colour and border but **not** the font or the padding — a chip that grew when chosen would
    /// move its neighbours, and the preview above it.
    ///
    /// The button's whole effect is the `@State` it sets. It writes no store, no bot and no activity:
    /// the strip is a window on the renderer, not a remote control for a bot.
    private func stateChip(_ choice: OpenBotAvatarStateChoice, title: String) -> some View {
        let chosen = previewChoice.id == choice.id
        return Button {
            previewChoice = choice
        } label: {
            Text(title)
                .font(TypeScale.font(TypeScale.sm, weight: .medium))
                .foregroundStyle(chosen ? Tokens.accent : Tokens.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(chosen ? Tokens.controlActive : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .strokeBorder(chosen ? Tokens.accent : Tokens.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .hermeyFocusQuiet()
    }

    // MARK: - Material

    /// The materials the table holds, as a choice. Driven by `BotAvatarMaterialSpec.all` rather than
    /// by a hard-coded pair, so the next material is a row there and a word here, not a new control.
    private var materialRow: some View {
        let current = BotAvatarMaterialSpec.spec(for: material)
        return VStack(alignment: .leading, spacing: 8) {
            SectionCaption("MATERIAL")
            Picker("Material", selection: $material) {
                ForEach(BotAvatarMaterialSpec.all, id: \.material) { spec in
                    Text(spec.name).tag(spec.material)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .hermeyFocusQuiet()
            Text(current.summary)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            // Glass is two drawings — the Metal surface on an app surface above the shader's floor,
            // the painted material everywhere else — and the row says which one *this* device will
            // use rather than promising the better of the two. Asked of the route, never assumed:
            // the answer depends on the process (a Metal device, a bundle carrying `default.metallib`,
            // not a preview), on Reduce Transparency, and on the size the preview is drawn at.
            if material == .glass {
                Text(glassSurfaceNote)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What Glass really is here, at the size the preview draws it — one short line, and the honest
    /// one. It asks `BotAvatarGlassRoute` (through `drawn`, which is `decide`) so this row cannot
    /// drift from what the preview above is doing: when the view falls back to the painter, so does
    /// this sentence, and the copy never promises refraction a phone cannot draw.
    private var glassSurfaceNote: String {
        let route = BotAvatarGlassRoute.drawn(material: material,
                                              side: Self.previewSide,
                                              reduceTransparency: reduceTransparency)
        switch route {
        case .metal:
            return "Drawn as a lit, refracting surface on this device."
        case .canvas:
            // Two reasons reach the painter, and they read differently to a person: a setting they
            // chose, or simply what this process can do. Both are said, neither is dressed up.
            return reduceTransparency
                ? "Drawn as a painted surface on this device — Reduce Transparency is on."
                : "Drawn as a painted surface on this device."
        }
    }

    // MARK: - Presets

    /// The shapes to start from, and Random.
    ///
    /// Random sits on the section's own line rather than under the grid because it is not one more
    /// shape — it is the other way to start, and it sets the material and the colour too. It picks
    /// from `OpenBotAvatarRandom`, which reads the presets, the material table and the app's palette;
    /// nothing about a random face is written here, which is what keeps this view from growing a
    /// second colour list beside `BotAvatarPalette`.
    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionCaption("START FROM")
                Spacer(minLength: 8)
                Button("Random") { randomise() }
                    .buttonStyle(.plain)
                    .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                    .foregroundStyle(Tokens.accent)
                    .help("A random shape, material and colour")
                    .hermeyFocusQuiet()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(OpenBotAvatarPresets.all, id: \.id) { preset in
                    Button {
                        adopt(preset)
                    } label: {
                        VStack(spacing: 4) {
                            OpenBotAvatarView(definition: preset,
                                              color: colorHex,
                                              material: material,
                                              state: .idle,
                                              size: 34,
                                              animates: false,
                                              label: nil)
                            Text(preset.name)
                                .font(TypeScale.font(TypeScale.sm))
                                .foregroundStyle(Tokens.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                                .fill(family == .custom && preset.id == draft.id
                                      ? Tokens.controlActive : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .hermeyFocusQuiet()
                }
            }
        }
    }

    // MARK: - Classic faces

    /// The other family: the fixed faces, in their own labelled row.
    ///
    /// One row that scrolls, not a screen: this is eight choices, and the person is on this tab to
    /// leave or join the drawn family, not to browse. Every swatch is drawn by `BotAvatarView` in
    /// the face's own colour, from the table (`BotAvatarClassics`), so a classic face here is the
    /// same drawing as the same face everywhere else.
    ///
    /// The line under the row is the "you are here": without it the row cannot say whether the bot
    /// is wearing one of these or its own avatar, and a tap that does nothing visible reads as a bug.
    private var classics: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("CLASSIC")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BotAvatarClassics.all) { classic in
                        Button {
                            chooseClassic(classic)
                        } label: {
                            BotAvatarView(identity: botID,
                                          color: classic.choice.raw,
                                          activity: .idle,
                                          size: 34,
                                          animates: false,
                                          label: classic.name,
                                          ignoresStoredAvatar: true)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                                        .fill(isChosen(classic) ? Tokens.controlActive : .clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                                        .strokeBorder(isChosen(classic) ? Tokens.accent : .clear,
                                                      lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(classic.name)
                        .hermeyFocusQuiet()
                    }
                }
                .padding(.vertical, 1)
            }
            Text(familyNote)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether this swatch is the face the draft leaves the bot on.
    private func isChosen(_ classic: BotAvatarClassicFace) -> Bool {
        family == .classic && classicChoice?.raw == classic.choice.raw
    }

    /// Which family the bot is on, and what the other one would cost.
    private var familyNote: String {
        switch family {
        case .classic:
            return "\(botName) wears a Classic face — a shipped body and a palette colour."
        case .custom:
            return "\(botName) wears its own drawn avatar. Picking a face here replaces it, and Save clears the drawing."
        }
    }

    // MARK: - JSON

    private var jsonBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionCaption("DEFINITION JSON")
                Spacer()
                Button("Apply") { applyJSON() }
                    .buttonStyle(.plain)
                    .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                    .foregroundStyle(Tokens.accent)
                    .hermeyFocusQuiet()
            }
            TextEditor(text: $jsonText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 96, idealHeight: 120, maxHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.canvas)
                )
                .onChange(of: jsonText) { _, _ in validateJSONPreview() }
            switch jsonStatus {
            case .ok:
                Text("One path in a 0 0 100 100 box plus the eye pair. A definition from open-bot-avatar's editor pastes in unchanged.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let errors):
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(errors, id: \.self) { message in
                        Text(message)
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption("COLOUR AND EYES")
            HStack {
                ColorPicker("Body colour", selection: Binding(
                    get: { draftColor },
                    set: { colorHex = OpenBotAvatarColor.hex(of: $0) }
                ), supportsOpacity: false)
                .font(TypeScale.font(TypeScale.sm))
                .hermeyFocusQuiet()
                Spacer()
                if colorHex != nil {
                    Button("House colour") { colorHex = nil }
                        .buttonStyle(.plain)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.accent)
                        .hermeyFocusQuiet()
                }
            }
            slider("Eyes x", value: $draft.eyes.x, range: 4...96, step: 0.5)
            slider("Eyes y", value: $draft.eyes.y, range: 4...96, step: 0.5)
            slider("Spacing", value: $draft.eyes.spacing, range: 7...40, step: 0.5)
            slider("Scale", value: $draft.eyes.scale, range: 0.6...1.8, step: 0.05)
            if case .failed(let errors) = jsonStatus, let first = errors.first {
                Text(first)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.danger)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { newValue in
                    value.wrappedValue = newValue
                    // The JSON box follows the sliders, so the two never disagree about the draft.
                    syncJSONText()
                }
            ), in: range, step: step)
            .hermeyFocusQuiet()
            Text(String(format: step < 0.1 ? "%.2f" : "%.1f", value.wrappedValue))
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError {
                Text(saveError)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let savedNote {
                Text(savedNote)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }
            HStack(spacing: 10) {
                Button(saving ? "Saving…" : "Save avatar") { commit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(saving || resetting || !dirty)
                    .hermeyFocusQuiet()
                if stored != nil || face != nil {
                    Button(resetting ? "Resetting…" : "Reset to the previous face") { reset() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(saving || resetting)
                        .hermeyFocusQuiet()
                }
            }
        }
    }

    // MARK: - Behaviour

    private func adopt(_ preset: BotAvatarDefinition) {
        draft = preset
        // A preset is a drawn avatar: the draft is now in the custom family, and Save will clear
        // whatever classic face the bot had.
        family = .custom
        jsonStatus = .ok
        syncJSONText()
        savedNote = nil
    }

    /// A tap on a Classic swatch. It changes the draft, not the bot: Save is still the write, which
    /// is what keeps a stray tap from replacing a face somebody spent time on.
    private func chooseClassic(_ classic: BotAvatarClassicFace) {
        classicChoice = classic.choice
        family = .classic
        jsonStatus = .ok
        savedNote = nil
    }

    /// The Random button: a shape, a material and a colour, all three at once.
    ///
    /// The pick comes from `OpenBotAvatarRandom`, so every part of it is already storable: the shape
    /// is a validated preset, the material is a row of the table (hence a value the host accepts) and
    /// the colour is a `BotAvatarPalette` hex. Applying it goes through `adopt`, so the JSON box
    /// follows the preview and any error the box was showing is cleared — the editor cannot be left
    /// describing a draft it no longer has. `lastRandomPick` is what makes the next press different.
    private func randomise() {
        guard let pick = OpenBotAvatarRandom.pick(avoiding: lastRandomPick) else { return }
        lastRandomPick = pick.combination
        material = pick.material
        colorHex = pick.colorHex
        adopt(pick.definition)
        saveError = nil
    }

    /// Both boxes describe one draft, so a control change writes the JSON back.
    private func syncJSONText() {
        if let text = try? draft.jsonText(), text != jsonText { jsonText = text }
    }

    private func validateJSONPreview() {
        do {
            _ = try BotAvatarDefinition.decode(json: jsonText)
            jsonStatus = .ok
        } catch let failure as BotAvatarValidationFailure {
            jsonStatus = .failed(failure.errors)
        } catch {
            jsonStatus = .failed([error.localizedDescription])
        }
    }

    private func applyJSON() {
        do {
            let imported = try BotAvatarDefinition.decode(json: jsonText)
            draft = imported
            // An imported definition is a drawn avatar too.
            family = .custom
            jsonStatus = .ok
            savedNote = "Imported \(imported.name)."
        } catch let failure as BotAvatarValidationFailure {
            jsonStatus = .failed(failure.errors)
        } catch {
            jsonStatus = .failed([error.localizedDescription])
        }
    }

    /// Saves the family the draft is in — and only that one, because the store clears the other half
    /// in the same request (`BotAvatarSelection`).
    private func commit() {
        saveError = nil
        savedNote = nil
        switch family {
        case .classic:
            // No validation and no JSON: this half of the editor is one string, and a half-typed
            // definition in the box below must not be able to block a Classic save.
            guard let choice = classicChoice else {
                saveError = "Pick one of the Classic faces first."
                return
            }
            let selection = BotAvatarSelection.classic(choice)
            saving = true
            Task {
                do {
                    try await save(selection)
                    savedNote = "Saved for \(botName): a Classic face."
                } catch {
                    saveError = error.localizedDescription
                }
                saving = false
            }
        case .custom:
            do {
                let validated = try draft.validated()
                draft = validated
            } catch let failure as BotAvatarValidationFailure {
                jsonStatus = .failed(failure.errors)
                saveError = "Not saved: \(failure.summary)"
                return
            } catch {
                saveError = "Not saved: \(error.localizedDescription)"
                return
            }
            let selection = BotAvatarSelection.custom(BotAvatarDocument(definition: draft,
                                                                        color: colorHex,
                                                                        material: material))
            saving = true
            Task {
                do {
                    try await save(selection)
                    savedNote = "Saved for \(botName)."
                } catch {
                    saveError = error.localizedDescription
                }
                saving = false
            }
        }
    }

    private func reset() {
        saveError = nil
        savedNote = nil
        resetting = true
        Task {
            do {
                // Both halves: the drawn avatar and the classic face. What is left is the face the
                // bot's id derives, which is what it wore before either existed.
                try await save(nil)
                savedNote = "Reset to the face \(botName) wore before."
            } catch {
                saveError = error.localizedDescription
            }
            resetting = false
        }
    }
}

// MARK: - An example state

/// One state of a host's own, small enough to read in the editor.
///
/// `AvatarStateDefinition` is an id and a pose — nothing else — so a state of your own is a few lines
/// rather than a new case in an enum we ship. It works wherever a name does: `OpenBotAvatarView`'s
/// `state:` takes either. The editor draws this one as its ninth chip, which is the point — the API
/// can be seen rather than only described.
///
/// The pose starts from the calm one (`ctx.rest(1)`: the body breathes and looks about as `idle`
/// does) and adds one thing, a slow lean. `ctx.wave(period, phase)` is a sine on the avatar's own
/// clock, so two avatars in this state do not move in step, and it returns 0 under Reduce Motion —
/// which is why nothing here has to test for it.
public enum OpenBotAvatarExampleState {

    /// A slow lean with the eyes travelling across the face. Two definitions with one id are the same
    /// state, so this id — `example` — is what names it everywhere.
    public static let definition = AvatarStateDefinition(id: "example") { ctx in
        var pose = ctx.rest(1)  // the calm pose, then only what differs
        pose.roll = -5 * ctx.wave(2.8, 0)  // a lean, once every 2.8 s
        pose.gazeX = 0.7 * ctx.wave(4.2, .pi / 3)  // the eyes drift with it
        return pose
    }
}
