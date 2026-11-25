"""The `infographic` card kind, pinned at the source.

A short query — a place, a product — is answered with one card: a real picture, the title, the
number that matters, three to eight facts, one link and a source line. There is no Swift compiler
on this box, so this file is the guard for the parts a later tidy-up could quietly break:

* the host validates the kind and refuses a bad field *by name*, before the read is snapshotted;
* a picture is http(s) or nothing — never `file:`, `data:`, `javascript:`;
* one shared layout in `HermesCards` draws it for both apps, with no per-app copy and no second
  image pipeline;
* a picture that fails to load leaves the caption alone: no broken-image glyph, no placeholder;
* a card with no picture still lays out;
* the bot-facing docs and the repo spec both name the kind.

The behaviour itself is pinned by the Rust cases in `hermeyd/src/cards.rs` and the XCTest cases in
`Tests/HermesCardsTests/CardKindsTests.swift`, which this file also checks for the load-bearing
scenarios so they cannot be dropped.
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGET = ROOT / "Sources/HermesCards"

RUST = (ROOT / "hermeyd/src/cards.rs").read_text()
MODEL = (TARGET / "CardModel.swift").read_text()
VIEW = (TARGET / "CardView.swift").read_text()
LAYOUT = (TARGET / "InfographicCard.swift").read_text()
LOADER = (TARGET / "CardImageLoader.swift").read_text()

MAC = (ROOT / "Apps/HermesMac/Conversation/TranscriptRowView.swift").read_text()
IOS = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text()

SKILL = (ROOT / "hermeyd/assets/agent-skills/agent-cards/SKILL.md").read_text()
SPEC = (ROOT / "docs/agent-cards.md").read_text()
LLMS = (ROOT / "llms.txt").read_text()
ARCHITECTURE = (ROOT / "docs/ARCHITECTURE.md").read_text()

KINDS_TESTS = (ROOT / "Tests/HermesCardsTests/CardKindsTests.swift").read_text()


def slice_between(source: str, start: str, end: str) -> str:
    """The text from `start` up to the next `end`, so a claim cannot pass from a neighbour.

    Brace counting would be fooled by the `{` inside `format!("… {{label}}")`, so the end marker is
    the next declaration instead.
    """
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


class HostValidationTests(unittest.TestCase):
    """The route, not the client, is what a bot's file meets first."""

    def test_only_the_infographic_kind_is_validated_here(self) -> None:
        # The other three kinds predate the route and are validated by `CardModel`; this one is
        # checked on arrival because it names a remote URL.
        self.assertIn('Some("infographic") => validate_infographic(card)', RUST)
        self.assertIn("fn validate_kind(card: &Value)", RUST)
        self.assertIn("fn validate_infographic(card: &Value)", RUST)

    def test_the_validation_runs_before_the_read_counts_as_good(self) -> None:
        # `read_card` is what the route snapshots. A card validated after that would keep drawing
        # from its snapshot after the bot fixed the file.
        read = slice_between(RUST, "fn read_card(", "#[cfg(unix)]")
        self.assertIn("validate_kind(&card).map_err(CardError::BadField)?", read)
        self.assertLess(
            read.index("validate_kind(&card)"),
            read.index("Ok((card, mtime))"),
            "the check must precede the successful read",
        )

    def test_a_bad_field_is_422_bad_card_with_the_field_in_the_detail(self) -> None:
        self.assertIn("BadField(String)", RUST)
        self.assertIn("CardError::BadCard | CardError::BadField(_) => \"bad_card\"", RUST)
        self.assertIn(
            "CardError::BadCard | CardError::BadField(_) => StatusCode::UNPROCESSABLE_ENTITY",
            RUST,
        )
        # The refusal a bot reads: the field it has to change, under the kind's own name.
        self.assertIn('CardError::BadField(field) => format!("infographic card: {field}")', RUST)

    def test_every_bound_names_its_field(self) -> None:
        for error in (
            '"title must be 1-{MAX_INFO_TITLE} characters"',
            '"subtitle must be a string of at most {MAX_INFO_SUBTITLE} characters"',
            '"facts must hold {MIN_INFO_FACTS}-{MAX_INFO_FACTS} entries, not {}"',
            '"facts[{index}].label must be 1-{MAX_INFO_FACT_LABEL} characters"',
            '"facts[{index}].value must be 1-{MAX_INFO_FACT_VALUE} characters"',
            '"highlight.value must be 1-{MAX_INFO_HIGHLIGHT} characters"',
            '"image must be an http(s) URL"',
            '"imageCaption needs an image"',
            '"link.url must be an http(s) URL"',
            '"source must be at most {MAX_INFO_SOURCE} characters"',
        ):
            self.assertIn(error, RUST, error)

    def test_the_bounds_are_the_ones_the_spec_states(self) -> None:
        for bound in (
            "const MIN_INFO_FACTS: usize = 3;",
            "const MAX_INFO_FACTS: usize = 8;",
            "const MAX_INFO_TITLE: usize = 120;",
            "const MAX_INFO_FACT_VALUE: usize = 80;",
            "const MAX_INFO_ASIDE: usize = 60;",
            "const MAX_CARD_URL: usize = 2048;",
        ):
            self.assertIn(bound, RUST, bound)
        # The whole-document ceiling is unchanged: an infographic is still a card, not an upload.
        self.assertIn("pub const MAX_CARD_BYTES: u64 = 32 * 1024;", RUST)

    def test_a_url_is_http_or_https_and_nothing_else(self) -> None:
        url = slice_between(RUST, "fn is_http_url(", "fn bounded_text(")
        self.assertIn('eq_ignore_ascii_case("https://")', url)
        self.assertIn('eq_ignore_ascii_case("http://")', url)
        # A URL is a string, never a path: no scheme is followed, nothing is opened.
        for forbidden in ("std::fs", "Command::new", "reqwest", "canonicalize"):
            self.assertNotIn(forbidden, url, forbidden)

    def test_the_rust_cases_are_pinned(self) -> None:
        for name in (
            "an_infographic_is_served_and_is_already_final",
            "an_infographic_with_no_image_still_serves",
            "a_field_outside_its_bound_is_refused_by_name",
            "an_image_that_is_not_http_is_refused",
            "a_caption_without_an_image_is_refused",
            "a_product_infographic_carries_price_seller_and_availability",
            "another_kind_is_not_held_to_the_infographic_schema",
            "a_refused_infographic_is_never_snapshotted",
            "http_urls_are_the_only_scheme_an_image_may_name",
        ):
            self.assertIn(name, RUST, name)

    def test_the_rust_fixtures_stay_textual(self) -> None:
        fixtures = slice_between(RUST, "/// An `infographic` document:", "fn serve(")
        # A card fixture is JSON in a string: no test opens a socket for a picture.
        self.assertNotIn("reqwest", fixtures)
        self.assertNotIn("await reqwest", fixtures)
        self.assertIn("never fetched", fixtures)


class ModelTests(unittest.TestCase):
    def test_the_kind_is_shared_by_both_apps(self) -> None:
        # One enum on the shared model, not an entry per app.
        self.assertIn("case infographic", MODEL)
        for app in (MAC, IOS):
            self.assertNotIn("case infographic", app, "the kind belongs to the shared model")

    def test_every_field_is_decoded(self) -> None:
        for field in ("var subtitle: String?", "var image: String?", "var imageCaption: String?",
                      "var facts: [Failable<RawRow>]?", "var highlight: Failable<RawHighlight>?",
                      "var link: Failable<RawLink>?", "var source: String?"):
            self.assertIn(field, MODEL, field)
        for field in ("public let subtitle: String?", "public let imageURL: URL?",
                      "public let imageCaption: String?", "public let highlight: Highlight?",
                      "public let facts: [Row]", "public let link: Link?", "public let source: String?"):
            self.assertIn(field, MODEL, field)

    def test_an_infographic_needs_no_status(self) -> None:
        # The skill writes no status for this kind; a missing one is its normal shape, and the
        # layout draws no chip. Every other kind still requires one.
        self.assertIn("} else if kind == .infographic {", MODEL)
        self.assertIn("state = .done", MODEL)
        self.assertIn("StatusState(rawValue: rawState) else { return failure }", MODEL)

    def test_a_picture_is_http_or_no_picture(self) -> None:
        gate = slice_between(MODEL, "static func httpURL(", "/// The flat `infographic` fields")
        self.assertIn('scheme == "http" || scheme == "https"', gate)
        self.assertIn("let host = url.host, !host.isEmpty", gate)
        self.assertIn("url.user == nil, url.password == nil", gate)
        self.assertIn("text.count <= 2048", gate)

    def test_a_caption_never_outlives_its_picture(self) -> None:
        self.assertIn("imageCaption: image == nil ? nil : text(raw.imageCaption)", MODEL)
        self.assertIn("an image that is not an http(s) URL is no", MODEL)

    def test_the_model_cases_are_pinned(self) -> None:
        for name in (
            "testAnInfographicDecodesItsPictureFactsAndHighlight",
            "testAnInfographicNeedsNoStatus",
            "testAnInfographicWithoutAPictureStillDecodes",
            "testAnImageThatIsNotHTTPIsNoImageAndTakesItsCaption",
            "testAFactWithNoValueOrLabelIsDroppedAndTheRestSurvive",
            "testAnInfographicLinkThatCannotBeOpenedIsNotDrawn",
        ):
            self.assertIn(name, KINDS_TESTS, name)


class OneSharedRendererTests(unittest.TestCase):
    def test_the_layout_lives_in_one_file(self) -> None:
        owners = [path.name for path in TARGET.glob("*.swift") if "struct InfographicCard" in path.read_text()]
        self.assertEqual(owners, ["InfographicCard.swift"])

    def test_each_app_only_calls_the_shared_card_view(self) -> None:
        for name, app in (("macOS", MAC), ("iOS", IOS)):
            self.assertIn("CardView(model: model, theme: cardTheme)", app, name)
            # A per-app layout is the drift this kind must never have.
            self.assertNotIn("InfographicCard", app, name)
            self.assertNotIn("CardImageLoader", app, name)
            self.assertNotIn("struct Infographic", app, name)

    def test_the_card_view_dispatches_the_kind_and_nothing_else(self) -> None:
        self.assertIn("case .infographic:", VIEW)
        self.assertIn("InfographicCard(card: card, theme: theme)", VIEW)
        # The view still owns no transport: the picture is the loader's job.
        for word in ("URLSession", "URLRequest", "AsyncImage"):
            self.assertNotIn(word, VIEW, word)

    def test_there_is_one_image_path_in_the_target(self) -> None:
        readers = [path.name for path in TARGET.glob("*.swift") if "URLSession" in path.read_text()]
        self.assertEqual(readers, ["CardImageLoader.swift"], "one loader, not one per kind")
        # …and it reuses the pictures' own cache rather than growing a second one.
        self.assertIn("AttachmentImageStore.data(named: key)", LOADER)
        self.assertIn("AttachmentImageStore.save(data, as: key)", LOADER)
        self.assertNotIn("FileManager", LOADER)


class LayoutTests(unittest.TestCase):
    def body(self) -> str:
        return slice_between(LAYOUT, "var body: some View", "    // MARK: - The number that matters")

    def test_the_hero_comes_first(self) -> None:
        body = self.body()
        self.assertLess(body.index("CardHeroImage("), body.index("Text(card.heading)"))
        self.assertIn("if let url = info.imageURL {", body)
        # No picture, no hero: the title starts the card instead of an empty frame.
        self.assertNotIn("Image(systemName:", body)

    def test_the_title_and_the_optional_subtitle(self) -> None:
        body = self.body()
        self.assertIn("Text(card.heading)", body)
        self.assertIn("if let subtitle = info.subtitle {", body)

    def test_the_highlight_is_a_tinted_block_with_seller_and_availability(self) -> None:
        block = slice_between(LAYOUT, "private func highlightBlock(", "/// One small labelled line")
        self.assertIn("theme.accent.opacity(0.10)", block)
        self.assertIn("Text(highlight.value)", block)
        self.assertIn('asideRow("Seller", seller)', block)
        self.assertIn('asideRow("Availability", availability)', block)
        # The big value wraps; it is never cut off.
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", block)

    def test_facts_are_right_aligned_rows_that_wrap(self) -> None:
        row = slice_between(LAYOUT, "private func factRow(", "// MARK: - Link and source")
        self.assertIn("Text(fact.label)", row)
        self.assertIn("Text(fact.value)", row)
        self.assertIn(".multilineTextAlignment(.trailing)", row)
        self.assertIn(".frame(maxWidth: narrow ? 170 : 240, alignment: .trailing)", row)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", row)
        self.assertNotIn("lineLimit", row, "a fact that is long must wrap, not end in an ellipsis")

    def test_the_link_is_one_button_like_row_and_the_source_is_quiet(self) -> None:
        link = slice_between(LAYOUT, "private func linkRow(", "/// The picture at the top")
        self.assertIn("SwiftUI.Link(destination: link.url)", link)
        self.assertIn("strokeBorder(theme.border, lineWidth: 1)", link)
        body = self.body()
        source = body[body.index("if let source = info.source {"):]
        self.assertIn("Text(source)", source)
        self.assertIn("theme.mutedInk", source)

    def test_the_layout_adapts_to_a_phone(self) -> None:
        self.assertIn("@Environment(\\.horizontalSizeClass) private var sizeClass", LAYOUT)
        self.assertIn("private var narrow: Bool { sizeClass == .compact }", LAYOUT)
        self.assertIn("private var heroHeight: CGFloat { narrow ? 148 : 176 }", LAYOUT)
        self.assertIn(".padding(narrow ? 12 : 14)", self.body())


class ImageFailureTests(unittest.TestCase):
    """The one thing a card must never do: wear a broken-image glyph."""

    def hero(self) -> str:
        return LAYOUT[LAYOUT.index("struct CardHeroImage"):]

    def test_a_loading_picture_is_a_calm_skeleton(self) -> None:
        hero = self.hero()
        self.assertIn("} else if !failed {", hero)
        skeleton = hero[hero.index("} else if !failed {"):hero.index("if let caption")]
        self.assertIn(".fill(theme.canvas)", skeleton)
        self.assertIn(".accessibilityHidden(true)", skeleton)
        for word in ("ProgressView", "exclamationmark", "\"photo\"", "photo.badge"):
            self.assertNotIn(word, hero, word)

    def test_the_picture_fills_a_rounded_frame(self) -> None:
        hero = self.hero()
        self.assertIn(".aspectRatio(contentMode: .fill)", hero)
        self.assertIn(".clipShape(RoundedRectangle(cornerRadius: theme.radiusControl", hero)

    def test_a_failure_leaves_the_caption_and_nothing_else(self) -> None:
        hero = self.hero()
        # The failed branch draws no picture at all, so the caption is the only thing left.
        failed = hero[hero.index("} else if !failed {"):hero.index("if let caption")]
        self.assertIn("RoundedRectangle(cornerRadius: theme.radiusControl", failed)
        self.assertNotIn("Image(", failed, "no broken-image glyph, no placeholder")
        self.assertIn("if let caption, !caption.isEmpty {", hero)
        self.assertIn("on failure it is all that is left", hero)
        self.assertIn("failed = loaded == nil", hero)
        # And the loader answers nil rather than a placeholder.
        self.assertIn("let decoded = CardImage(data: data) else { return nil }", LOADER)
        self.assertIn("init?(data: Data)", LOADER)

    def test_the_loader_handles_a_non_picture_body(self) -> None:
        # An HTML error page served with a 200 and an image content type must not decode.
        self.assertIn("(200..<300).contains(http.statusCode)", LOADER)
        self.assertIn("data.count <= maximumBytes", LOADER)
        self.assertIn("static let maximumBytes = 8 * 1024 * 1024", LOADER)


class DocsTests(unittest.TestCase):
    """The bot-facing schema and the repo spec must both know the kind."""

    def test_the_bundled_skill_names_the_kind(self) -> None:
        self.assertIn('`"approval"`, `"task"`, `"draft-email"` or `"infographic"`', SKILL)
        for field in ("`image`", "`imageCaption`", "`facts`", "`highlight`", "`link`", "`source`"):
            self.assertIn(field, SKILL, field)
        self.assertIn("`infographic`:", SKILL)

    def test_the_repo_spec_names_the_kind(self) -> None:
        self.assertIn("infographic", SPEC)
        self.assertIn("| `kind` | required:", SPEC)
        # The old absolute "no remote images" rule is not true any more; the spec says what replaced
        # it rather than leaving a contradiction in the document.
        self.assertNotIn("no markdown injection, no remote images", SPEC)

    def test_the_one_line_indexes_name_the_kind(self) -> None:
        self.assertIn("infographic", LLMS)
        self.assertIn("infographic", ARCHITECTURE)

    def test_the_docs_do_not_invent_a_second_wire_format(self) -> None:
        # The skill is the bot-facing source; the spec describes the same document. Neither may
        # grow a nested `image: {url, caption}` shape the host would refuse.
        for name, text in (("SKILL.md", SKILL), ("agent-cards.md", SPEC)):
            self.assertNotIn('"image": {', text, name)
            self.assertIn("imageCaption", text, name)


if __name__ == "__main__":
    unittest.main()
