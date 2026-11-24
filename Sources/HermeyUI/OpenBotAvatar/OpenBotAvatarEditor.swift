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
/// * a **material** choice — the rows of `BotAvatarMaterialSpec.all`, so the list grows with the
///   table and this view never hard-codes two cases;
/// * **twelve presets** to start from (a blob, a box, a mug, a sprout, a cat, an egg, a bottle, a
///   star, a droplet, an hourglass, an open book and a mushroom) and a **Random** button beside
///   them that applies a shape, a material and a colour at once — all three read from the tables
///   this view already draws from (`OpenBotAvatarRandom`), so there is no second palette here and a
///   random face is always one Save can store;
/// * a **JSON box** for a definition copied from upstream's editor, with the contract's own reasons
///   shown inline when it cannot be imported;
/// * **colour and eye placement** — x, y, spacing, scale — which edit the definition live;
/// * **Save** and **Reset**. Reset deletes the stored avatar, so the bot goes back to the face it
///   wore before, which is its picture or its shape-and-palette face.
///
/// **Nothing here writes the bot's config or its soul.** The only thing this view can save is an
/// avatar document; the save closure is handed one and nothing else. That is deliberate: a face is
/// decoration, and decoration must not be able to change how a bot thinks.
public struct OpenBotAvatarEditor: View {
    public let botID: String
    public let botName: String
    /// What the host has stored now, or nil. Seeds the draft, and decides whether Reset is offered.
    public let stored: BotAvatarDocument?
    /// The state the preview shows. A surface that knows what the bot is doing passes it.
    public var previewState: OpenBotAvatarState
    /// Saves a document, or deletes the stored one when given nil. Errors are shown inline.
    public let save: (BotAvatarDocument?) async throws -> Void

    @State private var draft: BotAvatarDefinition
    @State private var colorHex: String?
    @State private var material: BotAvatarMaterial
    @State private var jsonText: String
    @State private var jsonStatus: JSONStatus = .ok
    @State private var saving = false
    @State private var resetting = false
    @State private var saveError: String?
    @State private var savedNote: String?
    @State private var state: OpenBotAvatarState
    /// The last pick the Random button applied, as `OpenBotAvatarRandomPick.combination`, so the
    /// next press cannot land on the same shape + material + colour.
    @State private var lastRandomPick: String?

    private enum JSONStatus: Equatable {
        case ok
        case failed([String])
    }

    /// The draft's colour, falling back to the house colour for the swatch.
    private var draftColor: Color {
        colorHex.flatMap(OpenBotAvatarColor.color(hex:)) ?? OpenBotAvatarRenderer.defaultColor
    }

    private var dirty: Bool {
        guard let stored else { return true }
        return stored.definition != draft || stored.color != colorHex || stored.material != material
    }

    public init(botID: String,
                botName: String,
                stored: BotAvatarDocument?,
                previewState: OpenBotAvatarState = .idle,
                save: @escaping (BotAvatarDocument?) async throws -> Void) {
        self.botID = botID
        self.botName = botName
        self.stored = stored
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
        _state = State(initialValue: previewState)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            preview
            materialRow
            presets
            jsonBox
            controls
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
            OpenBotAvatarView(definition: draft,
                              color: colorHex,
                              material: material,
                              state: state,
                              size: 200,
                              label: "\(botName)'s avatar")
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                        .fill(Tokens.canvas)
                )
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(alignment: .center, spacing: 10) {
                Text(draft.name)
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text("\(Int(draft.eyes.x.rounded())) · \(Int(draft.eyes.y.rounded())) · spacing \(String(format: "%.1f", draft.eyes.spacing)) · ×\(String(format: "%.2f", draft.eyes.scale))")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer(minLength: 0)
                Picker("Preview state", selection: $state) {
                    ForEach(OpenBotAvatarState.allCases, id: \.self) { state in
                        Text(state.rawValue.capitalized).tag(state)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .hermeyFocusQuiet()
            }
            Text("Preview shows the state you pick. Every state edits the same definition — the avatar is one drawing, not eight.")
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                                .fill(preset.id == draft.id ? Tokens.controlActive : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .hermeyFocusQuiet()
                }
            }
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
                if stored != nil {
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
        jsonStatus = .ok
        syncJSONText()
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
            jsonStatus = .ok
            savedNote = "Imported \(imported.name)."
        } catch let failure as BotAvatarValidationFailure {
            jsonStatus = .failed(failure.errors)
        } catch {
            jsonStatus = .failed([error.localizedDescription])
        }
    }

    private func commit() {
        saveError = nil
        savedNote = nil
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
        saving = true
        Task {
            do {
                try await save(BotAvatarDocument(definition: draft, color: colorHex,
                                                 material: material))
                savedNote = "Saved for \(botName)."
            } catch {
                saveError = error.localizedDescription
            }
            saving = false
        }
    }

    private func reset() {
        saveError = nil
        savedNote = nil
        resetting = true
        Task {
            do {
                try await save(nil)
                savedNote = "Reset to the face \(botName) wore before."
            } catch {
                saveError = error.localizedDescription
            }
            resetting = false
        }
    }
}
