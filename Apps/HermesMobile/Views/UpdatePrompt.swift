import SwiftUI
import UIKit
import HermesAppKit
import HermeyUI

/// The update card: what is available, and the three things the user can do about it.
///
/// ## Why a sheet and not a gate
///
/// An install must never become unusable because an update exists (`hermes-updater-spec-20261116`
/// §7.1). So this is a plain sheet over whatever was on screen: nothing underneath is disabled, no
/// feature is hidden behind it, and every way out is honoured — the buttons, Escape on a hardware
/// keyboard, and the system's own swipe-down. Dismissal is deliberately never forbidden here, and
/// there is no full-screen cover: either would turn "an update exists" into "you may not use the app".
///
/// ## Why the primary action opens a URL
///
/// iOS cannot replace its own bundle, so the most a sideloaded app can do is hand the IPA's URL to
/// the system. Safari offers it to AltStore, which does the installing. Nothing is downloaded by
/// this app, and nothing installs itself.
/// A sideloading app that can take an IPA from a deep link.
///
/// Three are in use here and each invented its own URL: AltStore and SideStore share
/// `scheme://install?url=<ipa>`, Feather uses `scheme://install/<ipa>` where the IPA is a path.
/// The card offers only the apps the phone actually has: `canOpenURL` answers that, and every
/// scheme must also be listed in the Info.plist's `LSApplicationQueriesSchemes` — iOS answers "no"
/// silently for an undeclared one, so the two lists have to agree.
///
/// Adding a store is one entry here plus its scheme in `project.yml`. FlareStore's link is not in
/// its public documentation — it was read out of FlareStore 1.5.0 itself (see `flareLink`).
struct SideloadingApp: Identifiable {
    let name: String
    /// The scheme, exactly as the app registers it.
    let scheme: String
    /// The deep link that asks this app to install `ipa`, or nil if the URL cannot be built.
    let installURL: (URL) -> URL?

    var id: String { scheme }

    static let all: [SideloadingApp] = [
        SideloadingApp(name: "AltStore", scheme: "altstore") {
            UpdatePrompt.queryLink(scheme: "altstore", ipa: $0)
        },
        SideloadingApp(name: "SideStore", scheme: "sidestore") {
            UpdatePrompt.queryLink(scheme: "sidestore", ipa: $0)
        },
        SideloadingApp(name: "Feather", scheme: "feather") {
            UpdatePrompt.pathLink(scheme: "feather", ipa: $0)
        },
        SideloadingApp(name: "FlareStore", scheme: "flarestore") {
            UpdatePrompt.flareLink(ipa: $0)
        },
    ]
}

struct UpdatePrompt: View {
    let update: AvailableUpdate
    let currentVersion: String
    let currentBuild: Int

    /// Opening the IPA in Safari, and closing the card once the system has it.
    let download: () -> Void
    /// Reporting "not now" — the one path that remembers the build.
    let notNow: () -> Void

    /// The sideloading apps this phone has, in the order the card offers them.
    ///
    /// Probed once, when the card appears: `canOpenURL` is a synchronous query against the system's
    /// registered schemes and not something to call per draw. Empty is the normal case for a phone
    /// with no sideloader installed, and Download still works — Safari hands the IPA to whatever
    /// can open it.
    @State private var installedApps: [SideloadingApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // What is available, and what changed. This scrolls: release notes can be long.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update available")
                        .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)

                    Text("\(update.version) is ready. You're on \(currentVersion) (build \(currentBuild)).")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if update.size > 0 {
                        Text(byteCount(update.size))
                            .font(.system(size: TypeScale.caption, design: .monospaced))
                            .foregroundStyle(Tokens.textMuted)
                            .monospacedDigit()
                    }

                    // What changed, as the publisher wrote it.
                    if !update.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(update.notes)
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                                .fill(Tokens.surface))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The actions never scroll and never shrink.
            //
            // They used to sit at the end of one stack whose notes view scrolled the whole card, so
            // a `.medium` detent with real release notes put the Download button below the fold —
            // "there is no download button" was a card whose buttons were off-screen, not a missing
            // button. Whatever the notes length, this part is on screen.
            VStack(spacing: 10) {

                Button {
                    Haptics.impact()
                    download()
                } label: {
                    Text("Download")
                        .font(TypeScale.font(TypeScale.md, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)

                // One button per sideloading app actually installed on this phone: AltStore,
                // SideStore and Feather all accept an IPA by deep link but under different URLs,
                // and a phone may well have more than one. Nothing here installs anything — each
                // hands the IPA's URL to the app the user picks.
                ForEach(installedApps) { app in
                    Button {
                        Haptics.impact()
                        if let link = app.installURL(update.url) { UIApplication.shared.open(link) }
                    } label: {
                        Text("Open in \(app.name)")
                            .font(TypeScale.font(TypeScale.md))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Tokens.accentText)
                }

                Button {
                    notNow()
                } label: {
                    Text("Not now")
                        .font(TypeScale.font(TypeScale.md))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textMuted)
                // Escape on a hardware keyboard dismisses, the same as the button and the swipe.
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            installedApps = SideloadingApp.all.filter { app in
                guard let link = app.installURL(update.url) else { return false }
                return UIApplication.shared.canOpenURL(link)
            }
        }
    }

    /// `altstore://install?url=<ipa>`, or nil when the IPA URL cannot be expressed as a query item.
    ///
    /// Built from `URLComponents` rather than string interpolation so the nested URL is escaped
    /// once, by the system, instead of by hand.
    static func altStoreURL(for update: AvailableUpdate) -> URL? {
        queryLink(scheme: "altstore", ipa: update.url)
    }

    /// `scheme://install?url=<ipa>` — AltStore's shape, which SideStore copied.
    static func queryLink(scheme: String, ipa: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        return components.url
    }

    /// `scheme://install/<ipa>` — Feather's shape: the IPA is a path, not a query item.
    static func pathLink(scheme: String, ipa: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "install"
        // `percentEncodedPath`, so the nested URL keeps one layer of escaping instead of two.
        components.percentEncodedPath = "/" + ipa.absoluteString
        return components.url
    }

    /// `flarestore://downloadApp=<ipa>` — FlareStore's shape: no host, one `key=value` after `//`.
    ///
    /// FlareStore documents no install deep link on its site, so this was read from the app itself:
    /// the 1.5.0 build registers `flarestore` and `flare` in `CFBundleURLTypes`, and the links it
    /// ships as examples are compiled into the binary —
    /// `flarestore://downloadApp=https://example.com/app.ipa`, beside `importCert=`, `addRepo=`,
    /// `viewApp=` and a `flare://` alias of the same set.
    ///
    /// Built by concatenation, not `URLComponents`: the value is a whole URL, and a component-built
    /// link would put it in the host, which cannot carry `://`. `URL(string:)` accepts the raw result
    /// and hands the app the same string its own example shows. Spaces are the one character that
    /// would break that parsing, so they are escaped and nothing else is.
    static func flareLink(ipa: URL) -> URL? {
        let target = ipa.absoluteString.replacingOccurrences(of: " ", with: "%20")
        return URL(string: "flarestore://downloadApp=" + target)
    }

    /// Decimal megabytes, because that is the number the download page shows. Arithmetic rather than
    /// `ByteCountFormatter`, which answers in the device's locale ("3.1 MB" here, "3,1 Mo" there) —
    /// a card that is quoted against the page should not change shape with a region.
    private func byteCount(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

// MARK: - Presentation

/// Attaches the update card to a screen, without touching anything underneath it.
///
/// The single control surface is the `isPromptVisible` binding: dismissing by button, Escape or
/// swipe all arrive here as `false`, so "Not now" and a swipe cannot drift apart in what they
/// remember. Nothing else in the tree is conditioned on the card being up.
///
/// The `host` is what makes the card actually appear. A sheet asked for by a view that is covered by
/// another sheet is not presented — it waits for the covering sheet to close. The manual check lives
/// inside the Settings sheet, so a card presented from the app shell behind it was invisible until
/// Settings was dismissed, which read as a dead button. Each presenter therefore serves one host and
/// the other stands down.
struct UpdatePromptPresenter: ViewModifier {
    @ObservedObject var updates: UpdateChecker
    let host: UpdateChecker.PromptHost

    /// Whether this context is the one that should be showing the card.
    ///
    /// `isShellReady` is the boot screen's veto: a check that answers during launch has already
    /// opened the card, and presenting it over the splash would put it behind a logo. The card
    /// appears the moment the launch screen is gone.
    private var isMine: Bool {
        updates.isPromptVisible && updates.promptHost == host && updates.isShellReady
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { isMine },
                                        set: { presented in
                                            // Only the dismissal edge carries information; the
                                            // presentation edge is driven by `check`.
                                            guard !presented, isMine else { return }
                                            updates.dismissPrompt()
                                        })) {
                if let update = updates.available {
                    UpdatePrompt(update: update,
                                 currentVersion: updates.currentVersion,
                                 currentBuild: updates.currentBuild,
                                 download: {
                                     // Exactly the feed's URL, opened by the system. No rewriting,
                                     // no redirect chasing, no scheme substitution.
                                     UIApplication.shared.open(update.url)
                                     updates.promptHandedOff()
                                 },
                                 notNow: { updates.dismissPrompt() })
                        .hermesSheetChrome()
                        // `.large` as well as `.medium`: the notes scroll inside the card, but a
                        // card that can only ever be half-height is one the user cannot grow to
                        // read.
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
    }
}

extension View {
    /// Present the update card over this screen.
    ///
    /// Applied twice by design: once at the app shell (`.root`, for the launch and foreground
    /// checks) and once inside the Settings sheet (`.settings`, for the manual check made there).
    func updatePrompt(_ updates: UpdateChecker,
                      host: UpdateChecker.PromptHost = .root) -> some View {
        modifier(UpdatePromptPresenter(updates: updates, host: host))
    }
}

