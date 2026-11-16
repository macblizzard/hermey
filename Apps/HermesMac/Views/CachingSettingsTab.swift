import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// What this Mac keeps, in Settings.
///
/// The same three switches, the same three-size limit and the same measured Usage numbers as the
/// phone's Caching screen — deliberately the same words (`CacheCopy`), because the state is
/// `AppModel`'s and the two platforms describing it differently would read as two different caches.
/// Turning a section off deletes what it kept on this Mac; nothing on the host changes.
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
        .confirmationDialog(CacheCopy.resetConfirmTitle,
                            isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button(CacheCopy.resetTitle, role: .destructive) {
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
            Text(CacheCopy.sectionsHeader)
        } footer: {
            Text(CacheCopy.sectionsFooter)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Limit

    /// The same three sizes as the phone, with the current one checked in the menu — not a stepper,
    /// which could only ever be a different number from the one the other platform shows.
    private var limit: some View {
        Section {
            Picker(CacheCopy.limitTitle, selection: limitBinding) {
                ForEach(CacheChatLimit.options, id: \.self) { option in
                    Text(CacheChatLimit.label(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .font(TypeScale.font(Tokens.textMD))
            .accessibilityLabel(CacheCopy.limitTitle)
            .accessibilityIdentifier("caching.chatLimit")
        } header: {
            Text(CacheCopy.limitTitle)
        } footer: {
            Text(CacheCopy.limitFooter)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
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
            Text(CacheCopy.usageHeader)
        } footer: {
            Text(CacheCopy.usageFooter)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
        }
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
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Reset

    private var reset: some View {
        Section {
            Button(CacheCopy.resetTitle, role: .destructive) { confirmReset = true }
                .disabled(model.cacheBusy)
                .accessibilityIdentifier("caching.reset")
        } footer: {
            Text(CacheCopy.resetFooter)
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

    /// Only the three offered sizes can be chosen; the store normalises anything else anyway.
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
