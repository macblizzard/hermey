#!/usr/bin/env python3
"""Build the Hermey documentation site.

The docs are static HTML with one shared shell: a sidebar, a content column and an on-this-page list.
Rather than hand-maintain a dozen near-identical pages, this script owns the shell, the navigation, the
search index and the prev/next links, and each page supplies only its body.

    python3 Tools/site/build_docs.py <output-dir>

`<output-dir>` is the `docs/` directory of the published site (the gh-pages worktree), so the output
is committed as plain files and GitHub Pages serves them without a build step.

**Pages that mirror a document render that document.** `docs/PREREQUISITES.md`, `docs/INSTALL.md`,
`docs/APPS.md`, `docs/FOR-AGENTS.md`, `docs/TROUBLESHOOTING.md`, `docs/SECURITY.md`,
`docs/INTEGRATIONS.md`, `docs/CREDENTIALS.md` and `docs/IMPORT-FROM-ANOTHER-PLATFORM.md` are read here
at build time and converted to the site's own markup — headings keep GitHub's anchors, tables become the
cream table cards, fenced commands become the mono block with its copy button, quotes become notes. No
section of those documents is typed into this file, so a section added to a doc cannot be missing from
the site. `Tools/site/check_drift.py` compares the two and `Tests/test_docs_site_sections.py` pins it.

Pages with no document behind them — the overview, local computer use, the reference — are written in
this file, and the reference's route table is generated from `hermeyd/src/main.rs` for the same reason.
"""
from __future__ import annotations

import hashlib
import html
import json
import pathlib
import re
import sys

from markdown_it import MarkdownIt

BRAND = "Hermey"
REPO = "https://github.com/macblizzard/hermey"
SITE = "../"  # docs/ lives one level under the landing page
DOCS = pathlib.Path(__file__).resolve().parents[2] / "docs"

# The independence statement. It is the same sentence in the page footer, on the landing page and in the
# README, because a project that names someone else's trademark owes that in every place it is introduced.
DISCLAIMER = ("Hermey is an independent project — not affiliated with, endorsed by, or supported by the "
              "Hermes project or its maintainers. “Hermes” is named only to say what Hermey connects to.")


def code_block(body: str, label: str = "", button: bool = True) -> str:
    """A mono block around already-escaped HTML, with a copy button unless the block is not a command.

    `label` is the aria-label, so a screen reader says what the button copies.
    """
    btn = (f'<button class="copy" type="button" aria-label="Copy {html.escape(label or "the command")}">'
           f'Copy</button>') if button else ""
    klass = "code" if button else "code plain"
    return f'<div class="{klass}"><pre><code>{body}</code></pre>{btn}</div>'


def code(text: str, label: str = "") -> str:
    """A mono block with a copy button. The label is the aria-label, so each button says what it copies."""
    return code_block(html.escape(text.strip("\n")), label)


def table(head: list[str], rows: list[list[str]], cls: str = "") -> str:
    klass = " ".join(part for part in ("table-wrap", cls) if part)
    if not rows:
        return ""
    out = [f'<div class="{klass}"><table><thead><tr>']
    out += [f"<th>{h}</th>" for h in head]
    out.append("</tr></thead><tbody>")
    for row in rows:
        out.append("<tr>" + "".join(f"<td>{c}</td>" for c in row) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def note(kind: str, title: str, body: str) -> str:
    return f'<div class="note {kind}"><p><strong>{title}</strong> {body}</p></div>'


# ── markdown → the site's markup ─────────────────────────────────────────────────────────────────────
# A doc section and a page section have to say the same thing, so the page is generated from the doc. The
# only work left is presentation: keep the site's palette and type, and make the doc's own anchors work.

# doc -> the page that mirrors it. Doubles as the link rewriter, because a relative link in a doc has to
# land somewhere a visitor can click.
DOC_PAGE = {
    "PREREQUISITES.md": "prerequisites.html",
    "INSTALL.md": "install.html",
    "APPS.md": "apps.html",
    "FOR-AGENTS.md": "agents.html",
    "TROUBLESHOOTING.md": "troubleshooting.html",
    "SECURITY.md": "security.html",
    "INTEGRATIONS.md": "integrations.html",
    "CREDENTIALS.md": "credentials.html",
    "IMPORT-FROM-ANOTHER-PLATFORM.md": "importing.html",
}

# The docs are CommonMark as GitHub renders it — a fence indented inside a list item is a code block, not
# a paragraph. The older `markdown` package read those as paragraphs and printed a literal ``` on the page,
# so this uses a CommonMark parser.
MD = MarkdownIt("commonmark", {"html": True})
MD.enable("table").enable("strikethrough")

HERMEYD_ROUTER = pathlib.Path(__file__).resolve().parents[2] / "hermeyd" / "src" / "main.rs"


def doc_text(source: str) -> str:
    """One document, without its title line: the page template supplies the title."""
    path = DOCS / source
    if not path.exists():
        raise SystemExit(f"{source} is missing — {DOC_PAGE.get(source, 'a site page')} mirrors it")
    return re.sub(r"\A#\s+.*\n", "", path.read_text(encoding="utf-8"), count=1)


def doc_block(source: str, heading: str) -> str:
    """The first fenced block inside one `##` section, as text.

    For a page that quotes a command without mirroring the whole document: the command still comes out of
    the doc, so it cannot go stale on the site alone.
    """
    text = doc_text(source)
    match = re.search(rf"^## {re.escape(heading)}\s*$(.*?)(?=^## |\Z)", text, flags=re.M | re.S)
    fence = re.search(r"```[a-z]*\n(.*?)```", match.group(1), flags=re.S) if match else None
    if not fence:
        raise SystemExit(f"{source} has no fenced block under “{heading}”")
    return fence.group(1).rstrip("\n")


def _slug(text: str) -> str:
    """GitHub's heading anchor, so an in-doc link like `#2-verify-…` still lands after rendering.

    Same rule as GitHub's slugger: lower-case, drop everything that is not a word character or a hyphen,
    then spaces become hyphens. Reproducing it exactly is what makes an anchor copied out of the rendered
    page match the one in the doc.
    """
    return re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-") or "section"


def _anchor_headings(page: str) -> str:
    used: set[str] = set()

    def one(match: re.Match) -> str:
        level, inner = match.group(1), match.group(2)
        base = _slug(re.sub(r"<[^>]+>", "", inner))
        name, n = base, 1
        while name in used:
            name, n = f"{base}-{n}", n + 1
        used.add(name)
        return f'<h{level} id="{name}">{inner}</h{level}>'

    return re.sub(r"<h([2-4])>(.*?)</h\1>", one, page, flags=re.S)


def _wrap_code(page: str) -> str:
    """<pre> → the site's mono block; a fence with a language is a command, so it gets the copy button."""
    def one(match: re.Match) -> str:
        lang = (match.group(1) or "").strip()
        # A fence's text ends in the newline before the closing ```; the copy button must not copy it.
        return code_block(match.group(2).rstrip("\n"), "the command" if lang else "", button=bool(lang))

    return re.sub(r'<pre><code(?: class="language-([\w+-]+)")?>(.*?)</code></pre>', one, page, flags=re.S)


def _wrap_tables(page: str) -> str:
    def one(match: re.Match) -> str:
        mark = match.group(0)
        head = re.search(r"<thead>.*?</thead>", mark, flags=re.S)
        # `| | |` is a two-column table with no header text; a strip of empty cream cells reads as a bug.
        if head and not any(cell.strip() for cell in re.findall(r"<th>(.*?)</th>", head.group(0), flags=re.S)):
            mark = mark.replace(head.group(0), "")
        return f'<div class="table-wrap">{mark}</div>'

    return re.sub(r"<table>.*?</table>", one, page, flags=re.S)


def _wrap_quotes(page: str) -> str:
    """A doc's blockquote is the site's note — the disclaimer and the "already served" aside both are."""
    return re.sub(r"<blockquote>(.*?)</blockquote>",
                  lambda m: f'<div class="note info">{m.group(1).strip()}</div>', page, flags=re.S)


def _wrap_tasks(page: str) -> str:
    """GitHub's `- [ ]` checkboxes: the checklist style the definition-of-done section already used."""
    def one(match: re.Match) -> str:
        block = match.group(0)
        items = re.findall(r"<li>(.*?)</li>", block, flags=re.S)
        if not items or not all(re.match(r"\[[ xX]\]\s", i) for i in items):
            return block
        return '<ul class="checklist">' + re.sub(r"<li>\[[ xX]\]\s*", "<li>", block[len("<ul>"):])

    return re.sub(r"<ul>.*?</ul>", one, page, flags=re.S)


def _rewrite_links(page: str) -> str:
    """A relative `.md` link in a doc points at a file; on the site it has to point at a page."""
    def one(match: re.Match) -> str:
        target, sep, fragment = match.group(1).partition("#")
        name = pathlib.PurePosixPath(target).name
        if "/" not in target.strip("./") and name in DOC_PAGE:
            return f'href="{DOC_PAGE[name]}{sep}{fragment}"'
        resolved = pathlib.PurePosixPath("docs", target)
        return f'href="{REPO}/blob/main/{resolved}"'

    return re.sub(r'href="([^"\s]+\.md(?:#[^"]*)?)"', one, page)


def render_markdown(text: str) -> str:
    """Markdown in, the site's own markup out."""
    page = MD.render(text)
    for step in (_anchor_headings, _wrap_code, _wrap_tables, _wrap_quotes, _wrap_tasks, _rewrite_links):
        page = step(page)
    # The site's numbered lists are the circled steps; every `<ol>` in a doc is a sequence too.
    return page.replace("<ol>", '<ol class="steps-list">')


def _split_intro(page: str, fallback: str) -> tuple[str, str]:
    """The doc's opening paragraph becomes the page's standfirst, when it opens with a real paragraph.

    Keeping it in the body as well would print the same sentence twice; dropping it would lose the doc's
    own introduction behind a hand-written one.
    """
    match = re.match(r"<p>(.*?)</p>\s*", page, flags=re.S)
    if not match:
        return fallback, page
    length = len(re.sub(r"<[^>]+>", "", match.group(1)).strip())
    if length < 60 and fallback:
        return fallback, page
    return match.group(1), page[match.end():]


def doc_title(source: str) -> str:
    """The doc's own H1 — the page's title, so the heading a reader sees is the one the file carries."""
    first = (DOCS / source).read_text(encoding="utf-8").lstrip().splitlines()[0]
    return first[2:].strip() if first.startswith("# ") else source.removesuffix(".md").replace("-", " ")


def markdown_page(slug: str, nav: str, group: str, lede: str, source: str) -> dict:
    """A page rendered from a docs/*.md file, not hand-copied into this script."""
    body = render_markdown(doc_text(source))
    intro, body = _split_intro(body, lede)
    body += (f'\n<p class="doc-source">This page is <a href="{REPO}/blob/main/docs/{source}">'
             f'docs/{source}</a>, rendered at build time. Corrections belong in that file.</p>')
    return dict(slug=slug, nav=nav, group=group, title=doc_title(source), lede=intro, body=body)


def mounted_routes() -> list[tuple[str, str]]:
    """(path, methods) for every route hermeyd mounts, read from its router at build time.

    The reference page has to list what the service actually serves. Typing 96 paths by hand is the same
    mistake as typing a doc section, and it is the one `check_drift.py` found 89 times on the old page.
    """
    text = HERMEYD_ROUTER.read_text(encoding="utf-8") if HERMEYD_ROUTER.exists() else ""
    routes: dict[str, set[str]] = {}
    for match in re.finditer(r'\.route\(\s*"(/v1/[^"]+)"', text):
        after = text[match.end():match.end() + 240]
        method = re.search(r"\b(get|post|put|patch|delete)\(", after)
        routes.setdefault(match.group(1), set()).add(method.group(1).upper() if method else "—")
    return sorted((path, ", ".join(sorted(m))) for path, m in routes.items())


def route_table() -> str:
    return table(["Method", "Path"],
                 [[methods, f"<code>{html.escape(path)}</code>"] for path, methods in mounted_routes()])


# ── pages ────────────────────────────────────────────────────────────────────────────────────────────
# Each entry: slug, nav label, group, title, lede, body HTML.

PAGES: list[dict] = []

# Built here, appended after the overview: the sidebar reads PAGES in order.
_PREREQUISITES = markdown_page(
    slug="prerequisites",
    nav="Getting Hermey running",
    group="Getting started",
    lede="",
    source="PREREQUISITES.md")

PAGES.append(dict(
    slug="index",
    nav="Overview",
    group="Getting started",
    title="Hermey documentation",
    lede="A native iOS and macOS client for a Hermes agent you run yourself — and the one command "
         "that installs the host it talks to.",
    body=f"""
<p>Hermey is two pieces that meet at a tailnet address. <strong>hermeyd</strong>, one Rust binary, runs
on the machine that already runs Hermes. The <strong>apps</strong> on your phone and Mac talk to it over
HTTPS with a real certificate, and nothing else is in the path — no account, no relay, no service of
ours.</p>

<div class="start">
  <a class="start-btn" href="prerequisites.html">Get started</a>
  <span>From nothing to a paired app — four steps, about five minutes after Hermes is up.</span>
</div>

<h2 id="quick-start">Quick start</h2>
<p>Three steps. The first needs root on the Hermes host; the others happen on the device.</p>
<ol class="steps-list">
  <li><strong>Install the host.</strong> One command, safe to re-run as an upgrade.
    {code(doc_block("INSTALL.md", "The one command"), "the host install command")}
  </li>
  <li><strong>Pair a device</strong> on that host, with the phone in your hand — codes expire.
    {code("sudo hermeyd pair", "the pairing command")}
    It prints a six-digit code, a <code>https://&lt;host&gt;/?code=…</code> URL and a QR the app can scan.
  </li>
  <li><strong>Install the app and paste the code.</strong> iOS through AltStore or SideStore, macOS
    from the disk image. <a href="apps.html">Both are unsigned</a> — that is the stated trade-off.</li>
</ol>

<h2 id="start-here">Start here</h2>
<div class="cards">
  <a class="card" href="prerequisites.html"><span class="card-kicker">Start</span><strong>Getting started</strong>
    <span>What Hermes has to be doing first, then install, reach it, pair.</span></a>
  <a class="card" href="install.html"><span class="card-kicker">Host</span><strong>Install the host</strong>
    <span>The command, what it writes, the flags, and how to undo it.</span></a>
  <a class="card" href="apps.html"><span class="card-kicker">Devices</span><strong>The apps</strong>
    <span>Sideloading, first launch, quarantine, notifications, revocation.</span></a>
  <a class="card" href="computer-use.html"><span class="card-kicker">Capability</span><strong>Local computer use</strong>
    <span>Let bots drive the Mac you are sitting at — without SSH.</span></a>
  <a class="card" href="agents.html"><span class="card-kicker">Automation</span><strong>For agents</strong>
    <span>The install runbook written for an executor, with its verification gates.</span></a>
  <a class="card" href="troubleshooting.html"><span class="card-kicker">Repair</span><strong>Troubleshooting</strong>
    <span>Symptom, cause, fix — with the real log strings.</span></a>
  <a class="card" href="security.html"><span class="card-kicker">Model</span><strong>Security</strong>
    <span>Trust boundaries, invariants, and what is deliberately absent.</span></a>
</div>

<h2 id="requirements">Requirements</h2>
{table(["Piece", "Needs"], [
  ["Host", "Linux with systemd or macOS with launchd, <code>sudo</code> (it writes under <code>/opt</code>, "
           "<code>/etc</code> and <code>/var/lib</code>), and a working <code>hermes</code> install with an "
           "engine home. Tailscale is optional but recommended — without it the service is reachable only "
           "from the host itself"],
  ["iPhone / iPad", "iOS 17 or later, plus AltStore, SideStore or another signer"],
  ["Mac", "macOS 14 or later"],
])}

<h2 id="two-halves">The two halves</h2>
{table(["", "Where it runs", "What it is"], [
  ["<strong>Host service</strong>", "<code>hermeyd</code> on <code>127.0.0.1:8788</code>, with the browser channel on <code>8790</code>",
   "Rust service that adapts the Hermes engine to the apps' protocol. It holds the device registry, "
   "mints single-use 30-second tickets, relays the engine's WebSocket, and issues the local bearer at "
   "<code>/var/lib/hermeyd/local.token</code> that host-side scripts send."],
  ["<strong>Apps</strong>", "iPhone, iPad, Mac",
   "SwiftUI clients. They hold a device key, never a host secret, and can only answer the questions "
   "the agent asks."],
  ["<strong>Front door</strong>", "<code>tailscale serve --bg http://127.0.0.1:8788</code>",
   "Terminates TLS with a real certificate at serve-root, so pairing URLs carry no port. It is the only "
   "front door: hermeyd refuses any bind but loopback, and the apps refuse a self-signed certificate."],
])}

<p class="next-hint">New to this? Start with <a href="prerequisites.html">Getting Hermey running</a>,
then read <a href="install.html">Install the host</a>.</p>
""",
))


PAGES.append(_PREREQUISITES)

PAGES.append(markdown_page(
    slug="install",
    nav="Install the host",
    group="Getting started",
    lede="",
    source="INSTALL.md"))

PAGES.append(markdown_page(
    slug="apps",
    nav="The apps",
    group="Getting started",
    lede="",
    source="APPS.md"))

PAGES.append(markdown_page(
    slug="agents",
    nav="For agents",
    group="Automation",
    lede="",
    source="FOR-AGENTS.md"))

PAGES.append(markdown_page(
    slug="troubleshooting",
    nav="Troubleshooting",
    group="Reference",
    lede="Symptom, cause and fix — with the strings you will actually see.",
    source="TROUBLESHOOTING.md"))

PAGES.append(dict(
    slug="computer-use",
    nav="Local computer use",
    group="Using it",
    title="Local computer use",
    lede="Let bots use the Mac you are sitting at — screen, mouse, keyboard, files — over the app's own "
         "outbound link. No SSH, no Remote Login, no inbound port.",
    body=f"""
<h2 id="how-it-works">How it works</h2>
<p>The Mac app is the <strong>executor</strong>. Your host sends a command; the app performs it under
your account and returns the result. The Mac dials out and keeps the socket open, so nothing listens on
it and Remote Login stays off.</p>
<p>With the switch on, that socket comes up when the app launches and redials itself after a drop.
Opening Settings is never what switches it on.</p>
{note("tip", "It starts switched off.", "Nothing is queried until you turn on "
      "<strong>Settings → Computer → Let bots use this computer</strong>.")}

<h2 id="capabilities">What bots can do</h2>
<ul>
  <li>Run one-shot commands — including local builds — with a working directory you choose.</li>
  <li>Capture the screen with active-window metadata, then click, type, use keys, scroll or focus an
    app.</li>
  <li>Read, write and list files in one shared workspace, including downloads from the private browser
    surface.</li>
  <li>Open URLs and inspect a page snapshot without leaving the conversation.</li>
</ul>

<h2 id="permissions">macOS permissions</h2>
<p>Each grant has its own status row and its own link into System Settings. Nothing is requested just
by opening Settings — the probes run only when you press a button.</p>
{table(["Grant", "What it is for"], [
  ["Accessibility", "clicks and keystrokes"],
  ["Screen Recording", "captures"],
  ["Input Monitoring", "detecting physical input so a bot can be taken over"],
  ["Automation", "driving an app through AppleScript"],
])}

<h2 id="containment">How it stays contained</h2>
<ul>
  <li>Computer use starts switched off, and revoking the Mac closes its link immediately.</li>
  <li>One sorted queue drives the desktop, so two bots cannot interleave actions — and every action is
    attributed to the bot that asked.</li>
  <li>Physical input pauses the batch: touching the machine takes control back, and the bot resumes
    only when you hand it back.</li>
  <li>The app must be running. When it closes, computer use reports the Mac as offline.</li>
  <li>The host pings the Mac and drops a socket that stops answering, so a slept machine reads as
    absent instead of hanging a caller.</li>
</ul>

<h2 id="workspace">The workspace</h2>
<p>File tools are confined to one shared folder under
<code>~/Library/Application Support/Hermey/Computer/Workspace/</code>. Every bot sees the same folder;
paths that climb out of it are refused and audited.</p>

<h2 id="from-a-bot">How a bot reaches it</h2>
<p>There is no shell command to learn. The host exposes the paired Mac to the agent as the
<code>computer</code> tools — observe, act, files, browser — over the same authenticated socket, and the
shared <code>mac-local-computer</code> skill teaches a bot the call shape. Nothing is reachable until the
Mac has paired and the switch is on.</p>
""",
))

PAGES.append(markdown_page(
    slug="security",
    nav="Security",
    group="Reference",
    lede="",
    source="SECURITY.md"))

PAGES.append(dict(
    slug="reference",
    nav="Reference",
    group="Reference",
    title="Reference",
    lede="The facts a script, an agent or a tired human needs: commands, ports, paths and URLs.",
    body=f"""
<h2 id="cli">Commands</h2>
<p>A Hermey host installs a service, not a CLI of its own — the <code>hermey</code> wrapper belonged to the
retired Python bridge. These are the commands a host actually runs; each one is also in
<a href="install.html">Install the host</a>.</p>
{table(["Command", "What it does"], [
  ["<code>…install.sh | sudo sh</code>", "install or upgrade <code>hermeyd</code>; the same command both times"],
  ["<code>sudo setup/install.sh --from-source</code>", "build it in a checkout instead of downloading a binary"],
  ["<code>…install.sh | sudo sh -s -- --uninstall</code>", "remove the service, binary, config and plugin; state is kept (<code>--purge</code> deletes it)"],
  ["<code>hermeyd --gateway-check</code>", "exits <code>75</code> when another gateway owns this <code>HERMES_HOME</code>; it never kills anything"],
  ["<code>hermeyd --version</code>", "the build installed at <code>/opt/hermey/bin/hermeyd</code>"],
  ["<code>systemctl status hermeyd</code>", "unit state (macOS: <code>launchctl print system/com.hermeyd</code>)"],
  ["<code>curl -fsS http://127.0.0.1:8788/v1/health</code>", "liveness — the one route that answers without the bearer"],
  ["<code>tailscale serve --bg http://127.0.0.1:8788</code>", "publish at serve-root with a real certificate"],
])}

<h2 id="ports">Ports and units</h2>
{table(["", ""], [
  ["Host service", "<code>hermeyd</code> on <code>127.0.0.1:8788</code> (<code>HERMEYD_PORT</code>) — loopback only, by design"],
  ["Browser channel", "<code>127.0.0.1:8790</code> (<code>HERMEYD_BROWSER_PORT</code>) — carries no credential; never published"],
  ["Bearer", "<code>/var/lib/hermeyd/local.token</code> (<code>0600</code>, reminted every boot) — what a host-side script sends on <code>8788</code>"],
  ["Tailnet", "serve-root via <code>tailscale serve</code>, real certificate — pairing URLs carry no port"],
  ["Units", "<code>hermeyd.service</code> on Linux; <code>com.hermeyd</code> in launchd on macOS"],
  ["Never", "a unit named <code>hermes-gateway.service</code> — that is Hermes' messaging gateway"],
])}

<h2 id="paths">Paths</h2>
{table(["Path", "What"], [
  ["<code>/opt/hermey/bin/hermeyd</code>", "the service binary"],
  ["<code>/var/lib/hermeyd</code>", "state (<code>0700</code>): <code>bridge.db</code>, <code>bridge.salt</code>, <code>local.token</code>, <code>attachments/</code>"],
  ["<code>/etc/hermey/hermeyd.env</code>", "configuration, <code>0640</code>, read as an <code>EnvironmentFile</code>"],
  ["<code>/etc/systemd/system/hermeyd.service</code>", "the unit (macOS: <code>/etc/hermey/com.hermeyd.plist</code>)"],
  ["<code>&lt;engine&gt;/plugins/hermes-genui/</code>", "the card plugin, with its <code>desktop/plugin.js</code> bundle"],
  ["<code>~/Library/Application Support/Hermey/Computer/Workspace/</code>", "the Mac's shared workspace for computer use"],
])}

<h2 id="health">Endpoints</h2>
<p>The routes worth knowing by name. The rest are below, generated rather than listed by hand.</p>
{table(["URL", "Answers"], [
  ["<code>GET /v1/health</code>", '<code>{"status":"ok","protocol_version":…,"ws":true}</code> on loopback or through the tailnet front door'],
  ["<code>/v1/pair/start</code>", "mints a short single-use code; loopback only"],
  ["<code>/v1/pair/claim</code>", "the app presents the code and its public key; a device is registered"],
  ["<code>/v1/ws</code>", "the device websocket (single-use 30 s ticket, then a session)"],
  ["<code>/v1/local-computers/ws</code>", "the Mac's own outbound socket for computer use — the host pings it and drops a silent one"],
  ["<code>/v1/browser/ws</code>", "the sign-in extension's loopback socket; the host sends it a login card's fill, so values never reach the bot"],
  ["<code>GET /v1/cards/{card_id}</code>", "an agent card (<code>card.v1</code>) a bot wrote, resolved from its id and snapshotted per message. <strong>In progress</strong> — the route is here, the native renderer ships in the next client, and no release carries it yet"],
])}

<h2 id="every-route">Every route</h2>
<p>Each path <code>hermeyd</code> mounts, read from the <code>.route(…)</code> table in
<code>hermeyd/src/main.rs</code> when this page is built — {len(mounted_routes())} of them, so this list
cannot fall behind the service. <code>/v1/health</code> and <code>/v1/pair/start</code> answer without the
local bearer; everything else answers <code>401</code> without it.</p>
{route_table()}

<h2 id="versions">Versions</h2>
<p>Two numbers, moving for different reasons.</p>
{table(["", "Number"], [
  ["Apps", "<code>0.1.&lt;run&gt;</code> — the marketing version defaults to the CI run number; a release tag is <code>v0.1.N</code>. The Mac's About panel and Settings show it as <em>version · build</em>"],
  ["Host service", "<code>hermeyd</code> carries its own <code>version</code> in <code>hermeyd/Cargo.toml</code>, released separately as tag <code>hermeyd-vX.Y.Z</code>"],
  ["When it moves", "<code>hermeyd</code>'s version moves only when <code>hermeyd/src/</code> or its bundled skills change. A client release does not bump it, and a CI job (<code>Tools/check_hermeyd_version_bump.py</code>) refuses a source change that leaves it alone"],
  ["Which build is running", "<code>hermeyd --version</code> on the host; the landing page reads its build line from the published feed"],
])}

<h2 id="downloads">Download URLs</h2>
{table(["", "URL"], [
  ["iOS source", "<code>https://github.com/macblizzard/hermey/releases/latest/download/altstore.json</code>"],
  ["macOS download", "<code>https://macblizzard.github.io/hermey-downloads/</code>"],
  ["Latest release", "<code>https://github.com/macblizzard/hermey/releases/latest</code>"],
])}

<h2 id="updates">How updates arrive</h2>
<ul>
  <li><strong>Host:</strong> re-run the install command; it is an upgrade and keeps state.</li>
  <li><strong>macOS:</strong> Sparkle reads an appcast and offers the new build in the app.</li>
  <li><strong>iOS:</strong> the sideloading app refreshes from the AltStore source.</li>
</ul>
""",
))

# ── shell ────────────────────────────────────────────────────────────────────────────────────────────

NAV_GROUPS = ["Getting started", "Using it", "Automation", "Reference"]

CSS = """
:root {
  color-scheme: light;
  --paper: #faf9f5; --paper-2: #f5f4ed; --card: #f0eee6;
  --line: #e3dacc; --line-soft: #ece8dd;
  --ink: #141413; --body: #3d3d3a; --muted: #6c6a64; --faint: #8f8d85;
  --clay: #d97757; --clay-deep: #b8603f;
  --serif: ui-serif, "Iowan Old Style", "Palatino Linotype", Palatino, "Book Antiqua", Georgia, "Times New Roman", serif;
  --sans: -apple-system, BlinkMacSystemFont, "Seravek", "Avenir Next", "Segoe UI", system-ui, sans-serif;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --head: 57px;
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
@media (prefers-reduced-motion: no-preference) { html { scroll-behavior: smooth; } }
body {
  margin: 0; background: var(--paper); color: var(--ink);
  font-family: var(--sans); font-size: 16px; line-height: 1.68;
  -webkit-font-smoothing: antialiased;
}
a { color: var(--clay-deep); text-decoration: none; border-bottom: 1px solid rgba(217,119,87,.35); }
a:hover { border-bottom-color: var(--clay-deep); }
a:focus-visible, button:focus-visible, input:focus-visible { outline: 2px solid var(--clay); outline-offset: 2px; border-radius: 3px; }
.skip { position: absolute; left: -9999px; top: 0; background: var(--ink); color: #fff; padding: .6rem .9rem; border-radius: 6px; z-index: 40; }
.skip:focus { left: 1rem; top: .6rem; }

/* top bar */
.top {
  position: sticky; top: 0; z-index: 30; height: var(--head);
  display: flex; align-items: center; gap: 1rem;
  padding: 0 clamp(1rem, 3vw, 1.75rem);
  background: rgba(250,249,245,.92); border-bottom: 1px solid var(--line-soft);
}
@supports (backdrop-filter: blur(1px)) { .top { backdrop-filter: saturate(140%) blur(10px); } }
.brand { font-family: var(--serif); font-size: 1.2rem; letter-spacing: -.02em; color: var(--ink); border: 0; }
.brand .dot { color: var(--clay); }
.top-sep { color: var(--line); }
.top-link { font-size: .88rem; color: var(--muted); border: 0; }
.top-link:hover { color: var(--ink); }
.search { margin-left: auto; position: relative; flex: 0 1 320px; }
.search input {
  width: 100%; height: 36px; padding: 0 .75rem 0 2rem;
  border: 1px solid var(--line); border-radius: 8px; background: var(--paper-2);
  font: inherit; font-size: .88rem; color: var(--ink);
}
.search input::placeholder { color: var(--faint); }
.search::before {
  content: ""; position: absolute; left: .7rem; top: 50%; width: 10px; height: 10px;
  margin-top: -6px; border: 1.5px solid var(--faint); border-radius: 50%;
}
.search::after {
  content: ""; position: absolute; left: 1.28rem; top: 50%; width: 5px; height: 1.5px;
  margin-top: 3px; background: var(--faint); transform: rotate(45deg);
}
@media (max-width: 640px) { .search { flex: 1 1 auto; } .top-link.gh { display: none; } }
.results {
  position: absolute; left: 0; right: 0; top: calc(100% + 6px);
  background: #fff; border: 1px solid var(--line); border-radius: 10px;
  box-shadow: 0 24px 40px -30px rgba(20,20,19,.6); overflow: hidden; display: none;
}
.results[open] { display: block; }
.results a { display: block; padding: .55rem .75rem; border: 0; border-bottom: 1px solid var(--line-soft); font-size: .88rem; }
.results a:last-child { border-bottom: 0; }
.results a[aria-selected="true"], .results a:hover { background: var(--paper-2); }
.results .r-page { display: block; color: var(--faint); font-size: .7rem; letter-spacing: .1em; text-transform: uppercase; margin-bottom: .1rem; }
.results .empty { padding: .7rem .75rem; color: var(--faint); font-size: .86rem; }

/* shell */
.shell { display: grid; grid-template-columns: 264px minmax(0, 1fr); gap: 0; }
.shell > * { min-width: 0; }
@media (min-width: 1240px) { .shell { grid-template-columns: 264px minmax(0, 1fr) 208px; } }
@media (max-width: 1024px) { .shell { grid-template-columns: minmax(0, 1fr); } }

/* sidebar */
.side { border-right: 1px solid var(--line-soft); padding: 1.5rem 1rem 3rem; }
@media (min-width: 1025px) {
  .side { position: sticky; top: var(--head); height: calc(100vh - var(--head)); overflow-y: auto; }
}
@media (min-width: 1025px) {
  /* the sidebar is a <details> so mobile can collapse it; on desktop it is always open, and the
     summary that toggles it is not shown */
  .side > summary { display: none; }
  .side:not([open]) .side-inner { display: block; }
}
@media (max-width: 1024px) {
  .side { border-right: 0; border-bottom: 1px solid var(--line-soft); padding: 0; }
  .side > summary { cursor: pointer; list-style: none; padding: .9rem 1.25rem; font-size: .9rem; font-weight: 500; }
  .side > summary::-webkit-details-marker { display: none; }
  .side > summary::after { content: "+"; float: right; color: var(--clay); font-family: var(--mono); }
  .side[open] > summary::after { content: "–"; }
  .side-inner { padding: 0 1.25rem 1.25rem; }
}
.side-group { margin: 0 0 1.4rem; }
.side-group h2 {
  font-family: var(--sans); font-size: .7rem; font-weight: 600; letter-spacing: .13em;
  text-transform: uppercase; color: var(--faint); margin: 0 0 .5rem; padding: 0 .6rem;
}
.side-group ul { list-style: none; margin: 0; padding: 0; }
.side-group a {
  display: block; padding: .38rem .6rem; border-radius: 6px; border: 0;
  font-size: .9rem; color: var(--body);
}
.side-group a:hover { background: var(--paper-2); color: var(--ink); }
.side-group a[aria-current="page"] { background: var(--card); color: var(--ink); font-weight: 500; }

/* content */
.content { padding: clamp(1.75rem, 4vw, 3rem) clamp(1.25rem, 4vw, 3rem) 4rem; max-width: 820px; }
.crumbs { font-size: .78rem; letter-spacing: .1em; text-transform: uppercase; color: var(--faint); margin: 0 0 .9rem; }
.crumbs a { border: 0; color: var(--faint); }
.crumbs a:hover { color: var(--clay-deep); }
h1 { font-family: var(--serif); font-weight: 400; letter-spacing: -.028em; font-size: clamp(2rem, 4vw, 2.7rem); line-height: 1.1; margin: 0 0 1rem; }
.lede { font-family: var(--serif); font-size: clamp(1.08rem, 1.8vw, 1.22rem); line-height: 1.55; color: var(--body); margin: 0 0 2rem; max-width: 46ch; }
h2 {
  font-family: var(--serif); font-weight: 400; letter-spacing: -.02em;
  font-size: 1.55rem; line-height: 1.25; margin: 2.6rem 0 .75rem;
  padding-top: 1.6rem; border-top: 1px solid var(--line-soft);
}
h2:first-of-type { border-top: 0; padding-top: 0; }
h3 { font-family: var(--serif); font-weight: 400; font-size: 1.18rem; margin: 1.8rem 0 .5rem; }
p, li { color: var(--body); }
p { margin: 0 0 1rem; }
ul, ol { margin: 0 0 1.1rem; padding-left: 1.25rem; }
li { margin: .3rem 0; }
li::marker { color: var(--faint); }
strong { color: var(--ink); font-weight: 600; }
code {
  font-family: var(--mono); font-size: .86em; background: var(--paper-2);
  border: 1px solid var(--line-soft); border-radius: 4px; padding: .08em .26em; color: #45443f;
}
h2 code, p code, li code, td code { white-space: nowrap; }
@media (max-width: 640px) { h2 code, p code, li code { white-space: normal; } }

/* code blocks — long commands wrap rather than hide behind a scrollbar: the install one-liner is the
   single most important string on the site, and a clipped command is worse than a wrapped one. A
   negative text-indent offsets the first line, so wrapped continuations sit one step in and cannot be
   mistaken for a second command. The copy button still yields the exact text. */
.code { position: relative; margin: 0 0 1.2rem; border: 1px solid var(--line); border-radius: 8px; background: var(--paper-2); overflow: hidden; }
.code pre { margin: 0; padding: .85rem 4.6rem .85rem .95rem; overflow-x: auto; }
.code code { display: block; background: none; border: 0; padding: 0 0 0 1.15rem; text-indent: -1.15rem;
             font-size: .8rem; line-height: 1.7; color: #35342f; white-space: pre-wrap; overflow-wrap: anywhere; }
.copy {
  position: absolute; top: .5rem; right: .5rem; min-height: 30px; padding: 0 .55rem;
  border: 1px solid var(--line); border-radius: 6px; background: var(--paper);
  font: inherit; font-size: .72rem; letter-spacing: .06em; text-transform: uppercase;
  color: var(--muted); cursor: pointer;
}
.copy:hover { color: var(--ink); border-color: var(--ink); }
.copy[data-done="1"] { color: var(--clay-deep); border-color: var(--clay); }

/* tables */
.table-wrap { overflow-x: auto; margin: 0 0 1.4rem; border: 1px solid var(--line); border-radius: 8px; }
table { border-collapse: collapse; width: 100%; font-size: .9rem; }
th, td { text-align: left; padding: .6rem .8rem; border-bottom: 1px solid var(--line-soft); vertical-align: top; }
th { font-size: .72rem; letter-spacing: .1em; text-transform: uppercase; color: var(--faint); font-weight: 600; background: var(--paper-2); }
tbody tr:last-child td { border-bottom: 0; }
td code { white-space: normal; }

/* notes */
.note { border-left: 2px solid var(--clay); background: var(--paper-2); padding: .85rem 1rem; margin: 0 0 1.3rem; border-radius: 0 8px 8px 0; }
.note p { margin: 0; font-size: .92rem; }
.note.warn { border-left-color: var(--clay-deep); background: #f7efe9; }
.note.tip { border-left-color: #7a9a6b; background: #f1f3ec; }

/* lists that carry steps / rules / checks */
.steps-list { counter-reset: step; list-style: none; padding: 0; margin: 0 0 1.2rem; }
.steps-list > li { counter-increment: step; position: relative; padding-left: 2.2rem; margin: 0 0 1.2rem; }
.steps-list > li::before {
  content: counter(step); position: absolute; left: 0; top: .1rem;
  width: 1.5rem; height: 1.5rem; border-radius: 50%; border: 1px solid var(--line);
  display: grid; place-items: center; font-family: var(--mono); font-size: .72rem; color: var(--clay-deep);
}
.rules { list-style: none; padding: 0; }
.rules li { position: relative; padding-left: 1.4rem; }
.rules li::before { content: "—"; position: absolute; left: 0; color: var(--clay); font-family: var(--mono); }
.checklist { list-style: none; padding: 0; }
.checklist li { position: relative; padding-left: 1.7rem; }
.checklist li::before {
  content: ""; position: absolute; left: 0; top: .45em; width: .95rem; height: .95rem;
  border: 1px solid var(--line); border-radius: 3px;
}

/* cards */
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: .9rem; margin: 0 0 1.6rem; }
.card { display: block; border: 1px solid var(--line); border-radius: 10px; padding: .95rem 1rem; background: var(--paper-2); }
.card:hover { border-color: var(--clay); background: #fff; }
.card-kicker { display: block; font-size: .68rem; letter-spacing: .13em; text-transform: uppercase; color: var(--faint); margin-bottom: .25rem; }
.card strong { display: block; font-family: var(--serif); font-weight: 400; font-size: 1.05rem; margin-bottom: .2rem; }
.card span { display: block; font-size: .86rem; color: var(--muted); line-height: 1.5; }
.next-hint { margin-top: 2rem; font-size: .92rem; color: var(--muted); }

/* the docs' own start cue — the first page a new reader should open */
.start { display: flex; flex-wrap: wrap; align-items: center; gap: .8rem; margin: 0 0 1.8rem; }
.start-btn {
  display: inline-flex; align-items: center; min-height: 42px; padding: 0 1.1rem;
  border: 0; border-radius: 8px; background: var(--ink); color: var(--paper);
  font-size: .92rem; font-weight: 500;
}
.start-btn:hover { background: #26261f; }
.start span { font-size: .9rem; color: var(--muted); max-width: 40ch; line-height: 1.5; }

/* rendered docs: the provenance line, and a quote block that is not a command */
.doc-source { font-size: .82rem; color: var(--faint); margin: 2.4rem 0 0; padding-top: 1rem; border-top: 1px solid var(--line-soft); }
.doc-source a { color: var(--muted); border-bottom-color: var(--line); }
.code.plain pre { padding-right: .95rem; }
/* a diagram, not a command: wrapping one breaks its alignment, so it scrolls instead */
.code.plain code { white-space: pre; overflow-wrap: normal; }
.note > p:last-child { margin-bottom: 0; }
.lede code { font-size: .82em; }

/* on this page */
.toc { display: none; padding: 2.4rem 1rem 3rem 0; font-size: .84rem; }
@media (min-width: 1240px) { .toc { display: block; position: sticky; top: var(--head); height: calc(100vh - var(--head)); overflow-y: auto; } }
.toc h2 { font-family: var(--sans); font-size: .68rem; letter-spacing: .13em; text-transform: uppercase; color: var(--faint); border: 0; padding: 0; margin: 0 0 .6rem; }
.toc ul { list-style: none; margin: 0; padding: 0; }
.toc a { display: block; padding: .22rem 0 .22rem .7rem; border: 0; border-left: 2px solid var(--line-soft); color: var(--muted); }
.toc a:hover { color: var(--ink); border-left-color: var(--line); }
.toc a.active { color: var(--ink); border-left-color: var(--clay); }

/* prev / next */
.pager { display: flex; gap: 1rem; justify-content: space-between; margin: 3rem 0 0; padding-top: 1.4rem; border-top: 1px solid var(--line-soft); }
.pager a { flex: 1 1 0; border: 1px solid var(--line); border-radius: 10px; padding: .8rem 1rem; background: var(--paper-2); }
.pager a:hover { border-color: var(--clay); }
.pager span { display: block; font-size: .7rem; letter-spacing: .12em; text-transform: uppercase; color: var(--faint); margin-bottom: .2rem; }
.pager strong { font-family: var(--serif); font-weight: 400; font-size: 1rem; color: var(--ink); }
.pager .next { text-align: right; margin-left: auto; }

footer.docfoot { border-top: 1px solid var(--line-soft); padding: 1.5rem 0 3rem; font-size: .82rem; color: var(--faint); }
footer.docfoot .wrap { max-width: 820px; padding: 0 clamp(1.25rem, 4vw, 3rem); }
footer.docfoot a { border: 0; color: var(--muted); }
footer.docfoot .disclaimer { color: var(--muted); margin: 0 0 .9rem; max-width: 74ch; }
"""

JS = """
// Sidebar: open on wide screens, collapsed on narrow ones. The CSS already shows it on desktop if
// this never runs, so the navigation cannot be lost to a script error.
(function () {
  var side = document.querySelector('details.side');
  if (!side || !window.matchMedia) return;
  var wide = window.matchMedia('(min-width: 1025px)');
  var sync = function () { side.open = wide.matches; };
  sync();
  if (wide.addEventListener) wide.addEventListener('change', sync);
  else if (wide.addListener) wide.addListener(sync);
})();

// Search: a tiny client-side index over the page headings. `/` or cmd/ctrl-K focuses it.
(function () {
  var input = document.querySelector('.search input');
  var panel = document.querySelector('.results');
  if (!input || !panel) return;
  var index = [], current = -1;

  fetch('assets/search.json').then(function (r) { return r.json(); }).then(function (data) {
    index = data;
  }).catch(function () { /* offline or file://: search simply stays empty */ });

  function render(items) {
    if (!items.length) {
      panel.innerHTML = '<div class="empty">No match. Try “pair”, “tailscale”, “permissions”.</div>';
      panel.setAttribute('open', '');
      current = -1;
      return;
    }
    panel.innerHTML = items.map(function (it, i) {
      return '<a href="' + it.u + '" aria-selected="' + (i === current) + '">' +
        '<span class="r-page">' + it.p + '</span>' + it.h + '</a>';
    }).join('');
    panel.setAttribute('open', '');
  }

  function search(term) {
    term = term.trim().toLowerCase();
    if (!term) { panel.removeAttribute('open'); return; }
    var hits = index.filter(function (it) {
      return (it.h + ' ' + it.p + ' ' + (it.b || '')).toLowerCase().indexOf(term) >= 0;
    }).slice(0, 10);
    current = hits.length ? 0 : -1;
    render(hits);
  }

  input.addEventListener('input', function () { search(input.value); });
  input.addEventListener('keydown', function (e) {
    var links = panel.querySelectorAll('a');
    if (e.key === 'Escape') { panel.removeAttribute('open'); input.blur(); return; }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (!links.length) return;
      current = (current + (e.key === 'ArrowDown' ? 1 : -1) + links.length) % links.length;
      links.forEach(function (a, i) { a.setAttribute('aria-selected', i === current); });
      return;
    }
    if (e.key === 'Enter' && links.length) { window.location.href = links[Math.max(current, 0)].href; }
  });
  document.addEventListener('keydown', function (e) {
    var typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName);
    if ((e.key === '/' && !typing) || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k')) {
      e.preventDefault(); input.focus(); input.select();
    }
  });
  document.addEventListener('click', function (e) {
    if (!panel.contains(e.target) && e.target !== input) panel.removeAttribute('open');
  });
})();

// Copy buttons: report what actually happened.
document.querySelectorAll('.copy').forEach(function (button) {
  button.addEventListener('click', function () {
    var code = button.parentElement.querySelector('code');
    if (!code) return;
    var text = code.textContent;
    var done = function (label) {
      button.textContent = label; button.dataset.done = '1';
      setTimeout(function () { button.textContent = 'Copy'; delete button.dataset.done; }, 1600);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { done('Copied'); }, function () { done('Select it'); });
    } else { done('Select it'); }
  });
});

// On this page: mark the section you are reading.
(function () {
  var links = Array.prototype.slice.call(document.querySelectorAll('.toc a'));
  if (!links.length || !('IntersectionObserver' in window)) return;
  var map = {};
  links.forEach(function (a) { map[a.getAttribute('href').slice(1)] = a; });
  var seen = [];
  var obs = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      seen = seen.filter(function (id) { return id !== e.target.id; });
      if (e.isIntersecting) seen.push(e.target.id);
    });
    links.forEach(function (a) { a.classList.remove('active'); });
    if (seen.length && map[seen[0]]) map[seen[0]].classList.add('active');
  }, { rootMargin: '-10% 0px -70% 0px' });
  Object.keys(map).forEach(function (id) {
    var el = document.getElementById(id);
    if (el) obs.observe(el);
  });
})();
"""






PAGES.append(markdown_page(
    slug="importing",
    nav="Importing bots",
    group="Using it",
    lede="Bring bots in from another platform: paste one prompt into its bot, import the zip it writes.",
    source="IMPORT-FROM-ANOTHER-PLATFORM.md"))

PAGES.append(markdown_page(
    slug="credentials",
    nav="Sign-in cards",
    group="Using it",
    lede="How a bot signs you in to a site without ever being given the password.",
    source="CREDENTIALS.md"))

PAGES.append(markdown_page(
    slug="agent-cards",
    nav="Agent cards",
    group="Using it",
    lede="A bot draws an approval, a task or an email draft as a card instead of a paragraph.",
    source="agent-cards.md"))

PAGES.append(markdown_page(
    slug="integrations",
    nav="Integrations",
    group="Using it",
    lede="Connect your own Google account so a bot can act in it — mail, calendar, files, maps.",
    source="INTEGRATIONS.md"))

# The pager must read in the sidebar's order, not the order these sections happened to be written in:
# `.append` above mixes groups, so Reference used to be followed by "Next: Importing bots". Sorting by
# NAV_GROUPS (stable, so each group keeps its authored order) makes Reference last, and the final page
# has no Next at all.
PAGES.sort(key=lambda page: NAV_GROUPS.index(page["group"]))


def sections(body: str) -> list[tuple[str, str, str]]:
    """(id, heading, that section's own text) — one entry per h2.

    Search has to be scoped to the section, not the page: matching against the whole page makes every
    heading of a page hit on any word in it, which is the same as not searching.
    """
    out: list[tuple[str, str, str]] = []
    for part in re.split(r'(?=<h2 id=")', body)[1:]:
        match = re.match(r'<h2 id="([^"]+)">(.*?)</h2>', part, flags=re.S)
        if not match:
            continue
        heading = re.sub(r"<[^>]+>", "", match.group(2)).strip()
        out.append((match.group(1), heading, plain(part)[:320]))
    return out


def headings(body: str) -> list[tuple[str, str]]:
    """(id, text) for every h2, in order — drives the on-this-page list."""
    return [(hid, text) for hid, text, _ in sections(body)]


def plain(fragment: str) -> str:
    text = re.sub(r"<[^>]+>", " ", fragment)
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def page_html(index: int, version: str = "") -> str:
    page = PAGES[index]
    slug = page["slug"]
    prev_page = PAGES[index - 1] if index > 0 else None
    next_page = PAGES[index + 1] if index < len(PAGES) - 1 else None

    nav = []
    for group in NAV_GROUPS:
        items = [p for p in PAGES if p["group"] == group]
        if not items:
            continue
        nav.append(f'<div class="side-group"><h2>{group}</h2><ul>')
        for item in items:
            here = ' aria-current="page"' if item["slug"] == slug else ""
            nav.append(f'<li><a href="{item["slug"]}.html"{here}>{item["nav"]}</a></li>')
        nav.append("</ul></div>")

    toc = "".join(f'<li><a href="#{hid}">{text}</a></li>' for hid, text in headings(page["body"]))

    pager = '<nav class="pager" aria-label="Pages">'
    if prev_page:
        pager += (f'<a href="{prev_page["slug"]}.html"><span>Previous</span>'
                  f'<strong>{prev_page["nav"]}</strong></a>')
    if next_page:
        pager += (f'<a class="next" href="{next_page["slug"]}.html"><span>Next</span>'
                  f'<strong>{next_page["nav"]}</strong></a>')
    pager += "</nav>"

    title = page["title"] if slug == "index" else f'{page["title"]} · Hermey docs'

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(plain(page["lede"]))}">
<meta name="theme-color" content="#faf9f5">
<link rel="canonical" href="https://macblizzard.github.io/hermey/docs/{'' if slug == 'index' else slug + '.html'}">
<meta property="og:type" content="article">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(plain(page["lede"]))}">
<link rel="icon" href="../icon-512.png">
<link rel="stylesheet" href="assets/docs.css?v={version}">
</head>
<body>
<a class="skip" href="#content">Skip to content</a>

<header class="top">
  <a class="brand" href="{SITE}">Hermey<span class="dot">.</span></a>
  <span class="top-sep" aria-hidden="true">/</span>
  <a class="top-link" href="index.html">Docs</a>
  <div class="search">
    <input type="search" id="q" placeholder="Search the docs  ( / )" aria-label="Search the documentation" autocomplete="off">
    <div class="results" role="listbox" aria-label="Search results"></div>
  </div>
  <a class="top-link gh" href="{REPO}">GitHub</a>
</header>

<div class="shell">
  <details class="side">
    <summary>Documentation</summary>
    <div class="side-inner">
      {''.join(nav)}
    </div>
  </details>

  <main class="content" id="content">
    <p class="crumbs"><a href="index.html">Docs</a> / {html.escape(page["nav"])}</p>
    <h1>{page["title"]}</h1>
    <p class="lede">{page["lede"]}</p>
    {page["body"]}
    {pager}
  </main>

  <nav class="toc" aria-label="On this page">
    <h2>On this page</h2>
    <ul>{toc}</ul>
  </nav>
</div>

<footer class="docfoot">
  <div class="wrap">
    <p class="disclaimer">{DISCLAIMER} <a href="prerequisites.html">Getting Hermey running</a></p>
    <p>MIT licensed · the source docs in <a href="{REPO}/tree/main/docs">github.com/macblizzard/hermey/docs</a>
      are the authority for this site. Found a mistake? <a href="{REPO}/issues">Open an issue</a>.</p>
  </div>
</footer>

<script src="assets/docs.js?v={version}"></script>
</body>
</html>
"""


STAMP_BEGIN = "<!-- build:start -->"
STAMP_END = "<!-- build:end -->"
CTA = ('<a class="btn btn-primary" href="#install">Install Hermey</a>',
       '<a class="btn btn-primary" href="docs/prerequisites.html">Get started</a>')


def stamped(text: str) -> str:
    """The bytes between the release build markers, or "" when the file carries none."""
    start, end = text.find(STAMP_BEGIN), text.find(STAMP_END)
    return text[start:end + len(STAMP_END)] if 0 <= start < end else ""


def update_landing(site_root: pathlib.Path) -> None:
    """Point the landing page's primary call to action at the intro page, and add the disclaimer.

    The landing page is not generated here — the release tools stamp its version line — so this is the only
    edit the docs build makes to it, and it is deliberately narrow: one anchor and one footer sentence,
    applied once, with the `<!-- build:start -->` block asserted unchanged before anything is written.
    """
    page = site_root / "index.html"
    if not page.exists():
        return
    text = page.read_text(encoding="utf-8")
    before = stamped(text)
    updated = text.replace(*CTA, 1) if CTA[0] in text else text

    if "independent project" not in updated:
        colophon = re.search(r'([ \t]*)<p class="colophon"', updated)
        if colophon:
            indent = colophon.group(1)
            updated = (updated[:colophon.start()]
                       + f'{indent}<p class="colophon disclaimer">{DISCLAIMER} '
                         f'<a href="docs/prerequisites.html">Getting Hermey running</a></p>\n'
                       + updated[colophon.start():])

    if updated == text:
        return
    if stamped(updated) != before:
        raise SystemExit("refusing to write index.html: the edit would disturb the build stamp")
    page.write_text(updated, encoding="utf-8")
    print(f"landing: {page} now points its primary button at docs/prerequisites.html")


def looks_generated(text: str) -> bool:
    """True for a page this script wrote: it carries the shared shell, not the hand-written landing page."""
    return 'assets/docs.css' in text or 'class="toc"' in text


def build(out: pathlib.Path) -> None:
    """Write the docs pages into `out`, and nothing else."""
    # The output directory is the site's `docs/`, never the site root. Pointing the build one level too
    # high is not a typo it can recover from: it writes the overview page over index.html — the hand-
    # written landing page — and drops a second copy of every page at the root while the real pages in
    # `docs/` keep their old text. That happened once and the site served the stale copy for a week, so
    # the shape is checked rather than inferred from whether index.html happens to carry a build stamp.
    if out.name != "docs":
        raise SystemExit(f"{out} is not a site docs/ directory. The pages are written to <site>/docs, "
                         f"beside the landing page — building into the site root would replace "
                         f"index.html with the overview page.\n"
                         f"       e.g. build_docs.py ../hermey-pages/docs")

    landing = out / "index.html"
    if landing.exists():
        text = landing.read_text(encoding="utf-8")
        if STAMP_BEGIN in text or not looks_generated(text):
            raise SystemExit(f"{landing} is not a generated docs page — refusing to overwrite it. "
                             f"Pass the site's docs/ directory, not the directory that holds the landing "
                             f"page.")

    (out / "assets").mkdir(parents=True, exist_ok=True)

    css_text = CSS.strip() + "\n"
    js_text = JS.strip() + "\n"
    (out / "assets" / "docs.css").write_text(css_text, encoding="utf-8")
    (out / "assets" / "docs.js").write_text(js_text, encoding="utf-8")

    # GitHub Pages serves assets with a long cache lifetime and the URL never changes, so a stylesheet
    # fix can sit invisible behind a stale browser cache. The query string is a content hash: it
    # changes exactly when the bytes do.
    version = hashlib.sha256((css_text + js_text).encode()).hexdigest()[:10]

    search = []
    for page in PAGES:
        for hid, text, body_text in sections(page["body"]):
            search.append({
                "h": text,
                "p": page["nav"],
                "u": f'{page["slug"]}.html#{hid}',
                "b": body_text,
            })

    (out / "assets" / "search.json").write_text(json.dumps(search, indent=0), encoding="utf-8")

    for i, page in enumerate(PAGES):
        (out / f'{page["slug"]}.html').write_text(page_html(i, version), encoding="utf-8")

    if out.name == "docs":
        update_landing(out.parent)
    print(f"wrote {len(PAGES)} pages + assets to {out}")


def main() -> int:
    if len(sys.argv) < 2:
        # The old default wrote into `docs/` beside the markdown it mirrors, which is the source tree, not
        # the site. Refuse rather than litter the repository.
        raise SystemExit("usage: python3 Tools/site/build_docs.py <site-docs-dir>\n"
                         "       e.g. build_docs.py ../hermey-pages/docs")
    build(pathlib.Path(sys.argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
