import SwiftUI

/// The one `infographic` layout.
///
/// A short query — "where is the Golden Gate Bridge", "find me this on amazon.de" — is answered by a
/// glance, not a document: one real picture, the title, the one number that matters, three to eight
/// facts, one link and a source line. Both apps reach this view through `CardView`, so the picture,
/// the highlight and the rows cannot drift between the Mac and the phone; only the widths and two
/// type sizes adapt.
///
/// Nothing here invents content. The picture is drawn from the card's own URL or not at all, the
/// facts are the card's own rows, and a value that is long wraps onto a second line instead of being
/// cut off with an ellipsis — a truncated fact is a wrong fact.
struct InfographicCard: View {
    private let card: Card
    private let theme: CardTheme

    /// `nil` on the Mac, `.regular` on an iPad and `.compact` on a phone: the one signal both
    /// platforms share for "this card is narrower than a desk".
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(card: Card, theme: CardTheme = .hermey) {
        self.card = card
        self.theme = theme
    }

    private var info: Card.Infographic { card.infographic ?? Card.Infographic() }

    private var narrow: Bool { sizeClass == .compact }

    private var heroHeight: CGFloat { narrow ? 148 : 176 }

    var body: some View {
        VStack(alignment: .leading, spacing: narrow ? 9 : 10) {
            if let url = info.imageURL {
                CardHeroImage(url: url,
                              caption: info.imageCaption,
                              theme: theme,
                              height: heroHeight,
                              compact: narrow)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(card.heading)
                    .font(.system(size: narrow ? 14.5 : 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let subtitle = info.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let highlight = info.highlight {
                highlightBlock(highlight)
            }

            if !info.facts.isEmpty {
                factsBlock(info.facts)
            }

            if let link = info.link {
                linkRow(link)
            }

            if let source = info.source {
                Text(source)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(narrow ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        // One element with children, like every other card: VoiceOver reads a card, not eight
        // unrelated labels.
        .accessibilityElement(children: .contain)
    }

    // MARK: - The number that matters

    /// The price of the product, the span of the bridge: one big value on a tinted block, with the
    /// seller and the availability as the two small rows a buyer actually looks for.
    private func highlightBlock(_ highlight: Card.Infographic.Highlight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = highlight.label {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(highlight.value)
                .font(.system(size: narrow ? 20 : 23, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.ink)
                // A long value wraps: a price that ends in "…" is not a price.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let seller = highlight.seller {
                asideRow("Seller", seller)
            }
            if let availability = highlight.availability {
                asideRow("Availability", availability)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .fill(theme.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// One small labelled line under the highlight — "Seller  Anker Direct DE".
    private func asideRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.mutedInk)

            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Facts

    private func factsBlock(_ facts: [Card.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(facts.indices, id: \.self) { index in
                factRow(facts[index])
            }
        }
    }

    /// Label on the left, value flush right. Both wrap; neither truncates.
    private func factRow(_ fact: Card.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(fact.label)
                .font(.system(size: 12))
                .foregroundStyle(theme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer(minLength: 8)

            Text(fact.value)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: narrow ? 170 : 240, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Link and source

    /// One button-like row: the only thing in the card that leaves the app.
    private func linkRow(_ link: Card.Infographic.Link) -> some View {
        SwiftUI.Link(destination: link.url) {
            HStack(spacing: 6) {
                Text(link.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .fill(theme.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(link.label)
    }
}

/// The picture at the top of an infographic, and the caption that belongs to it.
///
/// Three states, and none of them is a broken image:
///
/// * **loading** — a calm skeleton in the picture's own place. No spinner, no glyph, nothing that
///   says "something is wrong" while nothing is;
/// * **loaded** — the picture fills a rounded frame, cropped rather than letterboxed, with the
///   caption muted underneath;
/// * **failed** — the caption alone. A torn-paper glyph filling half the card would be a louder
///   claim than the absence it is reporting, and an invented placeholder would be a lie.
struct CardHeroImage: View {
    let url: URL
    let caption: String?
    let theme: CardTheme
    let height: CGFloat
    let compact: Bool

    @State private var image: CardImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                image.image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 1)
                    )
                    .accessibilityLabel(caption ?? "Picture")
                    .accessibilityAddTraits(.isImage)
            } else if !failed {
                RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .fill(theme.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .accessibilityHidden(true)
            }

            if let caption, !caption.isEmpty {
                // On success this is the caption; on failure it is all that is left, and it is
                // still true — the picture was meant to be here.
                Text(caption)
                    .font(.system(size: compact ? 10 : 10.5))
                    .foregroundStyle(theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: url.absoluteString) {
            // A different URL is a different picture: the old one, or the old failure, does not
            // carry over. The host rewrites a card file in place, so this view can outlive its URL.
            image = nil
            failed = false
            if let hit = CardImageLoader.cached(for: url) {
                image = hit
                return
            }
            let loaded = await CardImageLoader.image(for: url)
            image = loaded
            failed = loaded == nil
        }
    }
}
