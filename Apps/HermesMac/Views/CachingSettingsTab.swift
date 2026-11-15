import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// What this Mac keeps, in Settings.
///
/// The same three switches, the same limit and the same measured Usage numbers as the phone's
/// Caching screen — deliberately the same words, because the state is `AppModel`'s and the two
/// platforms describing it differently would read as two different caches. Turning a section off
/// deletes what it kept on this Mac; nothing on the host changes.
struct CachingSettingsTab: View {
    @ObservedObject var store: WorkspaceStore

    @State private var confirmReset = false

    private var model: AppModel { store.model }

    var body: some View {
        Form {
            sections
            limit
            usage
            reset
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .task { await model.loadCacheState() }
        .confirmationDialog("Reset the cache?",
                            isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Reset Cache", role: .destructive) {
                Task { await model.resetCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this Mac's copy is deleted. Nothing is removed from the host.")
        }
    }

    // MARK: - Sections

    private var sections: some View {
        Section {
            ForEach(CacheSection.allCases, id: \.self) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(section.title, isOn: binding(for: section))
                        .toggleStyle(.switch)
                        .tint(Tokens.success)
                        .accessibilityIdentifier("caching.\(section.rawValue)")
                    Text(section.explanation)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Cached On This Device")
        } footer: {
            Text("Turning a section off deletes what this Mac kept for it. Nothing is removed from the host.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Limit

    private var limit: some View {
        Section {
            HStack(spacing: 8) {
                Text("Limit")
                    .foregroundStyle(Tokens.textPrimary)
                Spacer(minLength: 8)
                Text(countText(model.cachePreferences.chatLimit))
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textMuted)
                    .monospacedDigit()
                Stepper("",
                        value: limitBinding,
                        in: HermesCacheStore.chatLimitRange,
                        step: 10)
                    .labelsHidden()
                    .accessibilityLabel("Chats kept in the cache")
                    .accessibilityIdentifier("caching.chatLimit")
            }
            .font(TypeScale.font(Tokens.textMD))
        } header: {
            Text("Limit")
        } footer: {
            Text("A good balance for daily use.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
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
            Text("Usage")
        } footer: {
            Text("Older items are dropped first once the limit is reached.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
        }
    }

    private func detail(for section: CacheSection) -> String {
        let use = model.cacheUsage.use(section)
        return "\(CacheFormat.count(use.count, section)) · \(CacheFormat.size(use.bytes))"
    }

    private func usageRow(_ title: String, value: String, emphasised: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TypeScale.font(Tokens.textMD, weight: emphasised ? .medium : .regular))
                .foregroundStyle(Tokens.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(Tokens.mono)
                .foregroundStyle(emphasised ? Tokens.textPrimary : Tokens.textMuted)
                .monospacedDigit()
        }
    }

    // MARK: - Reset

    private var reset: some View {
        Section {
            Button("Reset Cache", role: .destructive) { confirmReset = true }
                .disabled(model.cacheBusy)
                .accessibilityIdentifier("caching.reset")
        } footer: {
            Text("Deletes every cached item on this Mac. Bots and their conversations stay on the host and load again from it.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bindings

    private func binding(for section: CacheSection) -> Binding<Bool> {
        Binding(get: { model.cachePreferences.isEnabled(section) },
                set: { isOn in Task { await model.setCacheSection(section, enabled: isOn) } })
    }

    private var limitBinding: Binding<Int> {
        Binding(get: { model.cachePreferences.chatLimit },
                set: { chats in Task { await model.setCacheChatLimit(chats) } })
    }
}

#if DEBUG
private struct CachingSettingsTabPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        CachingSettingsTab(store: store)
            .frame(width: 620, height: 500)
            .preferredColorScheme(.dark)
    }
}

#Preview("Caching") {
    CachingSettingsTabPreview()
}
#endif
