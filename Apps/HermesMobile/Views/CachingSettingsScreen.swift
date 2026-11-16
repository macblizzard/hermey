import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// What this device keeps, on the phone.
///
/// The screen answers three questions and refuses to answer a fourth: *what* is cached (three
/// switches, one per section), *how much* of it (a limit in chats, chosen from three sizes), and
/// *what it costs* (real bytes, not an estimate). Each switch deletes its own section the moment it
/// goes off — the promise in the footer is not a promise about the next launch. Nothing here
/// touches the host: a cache is this device's copy, and the host stays the source of truth.
///
/// The copy is shared with the Mac's Caching tab through `CacheCopy`, `CacheChatLimit` and
/// `CacheFormat`, so the two platforms cannot describe the same state with different words.
struct CachingSettingsScreen: View {
    @ObservedObject var model: AppModel

    @State private var confirmReset = false
    /// The switch position and the limit the user just chose, held until the store answers.
    ///
    /// `AppModel.cachePreferences` is the store's copy, and it only changes when the actor call
    /// returns. A `Toggle` bound straight to it therefore renders the *old* value for the length of
    /// a disk write — the switch snaps back under the finger and the row reads as inert. These two
    /// keep the control where the user put it; each is cleared as soon as the store has answered,
    /// because from that moment the store's value is the truth (and the only thing that can correct
    /// a write that did not land).
    @State private var pendingSection: [CacheSection: Bool] = [:]
    @State private var pendingLimit: Int?

    var body: some View {
        List {
            sections
            limit
            usage
            reset
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle(CacheCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadCacheState() }
        .confirmationDialog(CacheCopy.resetConfirmTitle,
                            isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button(CacheCopy.resetTitle, role: .destructive) {
                Haptics.impact()
                Task { await model.resetCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CacheCopy.resetConfirmMessage)
        }
    }

    // MARK: - Sections

    private var sections: some View {
        Section {
            ForEach(CacheSection.allCases, id: \.self) { section in
                Toggle(isOn: binding(for: section)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textPrimary)
                        Text(section.explanation)
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.textGroupedSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Tokens.success)
                .listRowBackground(Tokens.surface)
                .accessibilityIdentifier("caching.\(section.rawValue)")
            }
        } header: {
            header(CacheCopy.sectionsHeader)
        } footer: {
            Text(CacheCopy.sectionsFooter)
                .font(TypeScale.font(TypeScale.label))
        }
    }

    // MARK: - Limit

    /// Three sizes, not a dial.
    ///
    /// The menu shows the current size checked and offers only what the store enforces, so the
    /// number on this row is always a number the cache can actually keep. The value is stored by
    /// the store (`CacheChatLimit.nearest` guards it), and lowering it evicts before the Usage
    /// numbers below are drawn.
    private var limit: some View {
        Section {
            Picker(CacheCopy.limitTitle, selection: limitBinding) {
                ForEach(CacheChatLimit.options, id: \.self) { option in
                    Text(CacheChatLimit.label(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .listRowBackground(Tokens.surface)
            .accessibilityIdentifier("caching.chatLimit")
        } header: {
            header(CacheCopy.limitTitle)
        } footer: {
            Text(CacheCopy.limitFooter)
                .font(TypeScale.font(TypeScale.label))
        }
    }

    // MARK: - Usage

    private var usage: some View {
        Section {
            usageRow(CacheCopy.totalRow,
                     value: CacheFormat.size(model.cacheUsage.totalBytes),
                     emphasised: true)
            ForEach(CacheSection.allCases, id: \.self) { section in
                usageRow(section.title, value: CacheFormat.detail(for: section, in: model.cacheUsage))
            }
        } header: {
            header(CacheCopy.usageHeader)
        } footer: {
            Text(CacheCopy.usageFooter)
                .font(TypeScale.font(TypeScale.label))
        }
    }

    private func usageRow(_ title: String, value: String, emphasised: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TypeScale.font(TypeScale.md, weight: emphasised ? .medium : .regular))
                .foregroundStyle(Tokens.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: TypeScale.caption, design: .monospaced))
                .foregroundStyle(emphasised ? Tokens.textPrimary : Tokens.textGroupedSecondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .listRowBackground(Tokens.surface)
    }

    // MARK: - Reset

    private var reset: some View {
        Section {
            Button(role: .destructive) {
                Haptics.selection()
                confirmReset = true
            } label: {
                Text(CacheCopy.resetTitle)
                    .font(TypeScale.font(TypeScale.md))
            }
            .disabled(model.cacheBusy)
            .listRowBackground(Tokens.surface)
            .accessibilityIdentifier("caching.reset")
        } footer: {
            Text(CacheCopy.resetFooter)
                .font(TypeScale.font(TypeScale.label))
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.font(TypeScale.label))
            .foregroundStyle(Tokens.textGroupedSecondary)
            .textCase(nil)
    }

    // MARK: - Bindings

    /// Optimistic on purpose: the switch moves under the finger, the store catches up, and a failure
    /// shows in the Usage numbers (and the log) rather than by snapping the switch back. The pending
    /// value is dropped once the store has answered, so the switch is still the store's state and
    /// not a local opinion that could outlive the screen.
    private func binding(for section: CacheSection) -> Binding<Bool> {
        Binding(get: { pendingSection[section] ?? model.cachePreferences.isEnabled(section) },
                set: { isOn in
                    Haptics.selection()
                    pendingSection[section] = isOn
                    Task { @MainActor in
                        await model.setCacheSection(section, enabled: isOn)
                        // Only the write that is still the user's last word clears the override:
                        // two quick flips leave the later one in charge.
                        if pendingSection[section] == isOn { pendingSection[section] = nil }
                    }
                })
    }

    /// The picker can only offer the three options, so the value it writes is always one of them;
    /// the store normalises anyway, because a stale `AppModel` must not be able to store a fourth.
    private var limitBinding: Binding<Int> {
        Binding(get: { pendingLimit ?? model.cachePreferences.chatLimit },
                set: { chats in
                    Haptics.selection()
                    pendingLimit = chats
                    Task { @MainActor in
                        await model.setCacheChatLimit(chats)
                        pendingLimit = nil
                    }
                })
    }
}

#if DEBUG
private struct CachingSettingsPreview: View {
    @StateObject private var model = AppModel(client: PreviewGatewayClient())

    var body: some View {
        NavigationStack {
            CachingSettingsScreen(model: model)
        }
    }
}

#Preview("Caching") {
    CachingSettingsPreview()
}
#endif
