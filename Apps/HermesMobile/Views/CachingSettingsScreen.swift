import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// What this device keeps, on the phone.
///
/// The screen answers three questions and refuses to answer a fourth: *what* is cached (three
/// switches, one per section), *how much* of it (a limit in chats), and *what it costs* (real bytes,
/// not an estimate). Each switch deletes its own section the moment it goes off — the promise in the
/// footer is not a promise about the next launch. Nothing here touches the host: a cache is this
/// device's copy, and the host stays the source of truth.
///
/// The copy is shared with the Mac's Caching tab through `CacheSection` and `CacheFormat`, so the two
/// platforms cannot describe the same state with different words.
struct CachingSettingsScreen: View {
    @ObservedObject var model: AppModel

    @State private var confirmReset = false

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
        .navigationTitle("Caching")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadCacheState() }
        .confirmationDialog("Reset the cache?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Cache", role: .destructive) {
                Haptics.impact()
                Task { await model.resetCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this device's copy is deleted. Nothing is removed from the host.")
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
            header("Cached On This Device")
        } footer: {
            Text("Turning a section off deletes what this device kept for it. Nothing is removed from the host.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    // MARK: - Limit

    private var limit: some View {
        Section {
            Stepper(value: limitBinding,
                    in: HermesCacheStore.chatLimitRange,
                    step: 10) {
                HStack(spacing: 8) {
                    Text("Limit")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Spacer(minLength: 8)
                    Text(countText(model.cachePreferences.chatLimit))
                        .font(.system(size: TypeScale.caption, design: .monospaced))
                        .foregroundStyle(Tokens.textGroupedSecondary)
                        .monospacedDigit()
                }
            }
            .listRowBackground(Tokens.surface)
            .accessibilityIdentifier("caching.chatLimit")
        } header: {
            header("Limit")
        } footer: {
            Text("A good balance for daily use.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    private func countText(_ value: Int) -> String {
        value == 1 ? "1 chat" : "\(value) chats"
    }

    // MARK: - Usage

    private var usage: some View {
        Section {
            usageRow("Total on this device",
                     value: CacheFormat.size(model.cacheUsage.totalBytes),
                     emphasised: true)
            ForEach(CacheSection.allCases, id: \.self) { section in
                usageRow(section.title, value: detail(for: section))
            }
        } header: {
            header("Usage")
        } footer: {
            Text("Older items are dropped first once the limit is reached.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    /// "18 bots · 412 KB" — the count and the size, both measured from the files.
    private func detail(for section: CacheSection) -> String {
        let use = model.cacheUsage.use(section)
        return "\(CacheFormat.count(use.count, section)) · \(CacheFormat.size(use.bytes))"
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
                Text("Reset Cache")
                    .font(TypeScale.font(TypeScale.md))
            }
            .disabled(model.cacheBusy)
            .listRowBackground(Tokens.surface)
            .accessibilityIdentifier("caching.reset")
        } footer: {
            Text("Deletes every cached item on this device. Bots and their conversations stay on the host and load again from it.")
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
    /// shows in the Usage numbers (and the log) rather than by snapping the switch back.
    private func binding(for section: CacheSection) -> Binding<Bool> {
        Binding(get: { model.cachePreferences.isEnabled(section) },
                set: { isOn in
                    Haptics.selection()
                    Task { await model.setCacheSection(section, enabled: isOn) }
                })
    }

    private var limitBinding: Binding<Int> {
        Binding(get: { model.cachePreferences.chatLimit },
                set: { chats in
                    Haptics.selection()
                    Task { await model.setCacheChatLimit(chats) }
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
