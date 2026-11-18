#!/usr/bin/env python3
"""Build the Hermey documentation site.

The docs are static HTML with one shared shell: a sidebar, a content column and an on-this-page list.
Rather than hand-maintain eight near-identical pages, this script owns the shell, the navigation, the
search index and the prev/next links, and each page below supplies only its body.

    python3 Tools/site/build_docs.py <output-dir>

`<output-dir>` is the `docs/` directory of the published site (the gh-pages worktree), so the output
is committed as plain files and GitHub Pages serves them without a build step.

Facts in here are copied from docs/INSTALL.md, docs/APPS.md, docs/TROUBLESHOOTING.md,
docs/FOR-AGENTS.md and docs/SECURITY.md. When those change, change this too — the source docs remain
the authority for the repo.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import sys

BRAND = "Hermey"
REPO = "https://github.com/macblizzard/hermey"
SITE = "../"  # docs/ lives one level under the landing page


def code(text: str, label: str = "") -> str:
    """A mono block with a copy button. The label is the aria-label, so each button says what it copies."""
    body = html.escape(text.strip("\n"))
    name = html.escape(label or "the command")
    return (f'<div class="code"><pre><code>{body}</code></pre>'
            f'<button class="copy" type="button" aria-label="Copy {name}">Copy</button></div>')


def table(head: list[str], rows: list[list[str]], cls: str = "") -> str:
    klass = f' class="table-wrap {cls}"'.strip()
    out = [f'<div {klass}><table><thead><tr>']
    out += [f"<th>{h}</th>" for h in head]
    out.append("</tr></thead><tbody>")
    for row in rows:
        out.append("<tr>" + "".join(f"<td>{c}</td>" for c in row) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def note(kind: str, title: str, body: str) -> str:
    return f'<div class="note {kind}"><p><strong>{title}</strong> {body}</p></div>'


# ── pages ────────────────────────────────────────────────────────────────────────────────────────────
# Each entry: slug, nav label, group, title, lede, body HTML.

PAGES: list[dict] = []

PAGES.append(dict(
    slug="index",
    nav="Overview",
    group="Getting started",
    title="Hermey documentation",
    lede="A native iOS and macOS client for a Hermes agent you run yourself — and the one command "
         "that installs the host it talks to.",
    body=f"""
<p>Hermey is two pieces that meet at a tailnet address. A small <strong>bridge</strong> runs on the
machine that already runs Hermes. The <strong>apps</strong> on your phone and Mac talk to that bridge
over HTTPS with a real certificate, and nothing else is in the path — no account, no relay, no
service of ours.</p>

<h2 id="quick-start">Quick start</h2>
<p>Three steps. The first needs root on the Hermes host; the others happen on the device.</p>
<ol class="steps-list">
  <li><strong>Install the host.</strong> One command, safe to re-run as an upgrade.
    {code("curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash", "the host install command")}
  </li>
  <li><strong>Mint a pairing code</strong> on that host, with the phone in your hand — codes expire.
    {code("hermey pair", "the pairing command")}
  </li>
  <li><strong>Install the app and paste the code.</strong> iOS through AltStore or SideStore, macOS
    from the disk image. <a href="apps.html">Both are unsigned</a> — that is the stated trade-off.</li>
</ol>

<h2 id="start-here">Start here</h2>
<div class="cards">
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
  ["Host", "Linux with systemd, Python 3.11+, a working <code>hermes</code> install, and Tailscale "
           "(or your own TLS proxy in front of loopback)"],
  ["iPhone / iPad", "iOS 17 or later, plus AltStore, SideStore or another signer"],
  ["Mac", "macOS 14 or later"],
])}

<h2 id="two-halves">The two halves</h2>
{table(["", "Where it runs", "What it is"], [
  ["<strong>Bridge</strong>", "Your Hermes host, bound to <code>127.0.0.1:8787</code>",
   "FastAPI service that adapts the Hermes dashboard to the apps' protocol. It holds the device "
   "registry, mints single-use tickets and audits every call."],
  ["<strong>Apps</strong>", "iPhone, iPad, Mac",
   "SwiftUI clients. They hold a device key, never a host secret, and can only answer the questions "
   "the agent asks."],
  ["<strong>Front door</strong>", "<code>tailscale serve --bg --https=8443</code>",
   "Terminates TLS with a real certificate. The apps refuse self-signed, so this is not optional."],
])}

<p class="next-hint">New to this? Read <a href="install.html">Install the host</a>, then
<a href="apps.html">the apps</a>.</p>
""",
))

PAGES.append(dict(
    slug="install",
    nav="Install the host",
    group="Getting started",
    title="Install the host",
    lede="One command on the machine that already runs Hermes. It adds a loopback service and exposes "
         "it over your tailnet — nothing else on the host changes.",
    body=f"""
<h2 id="one-command">The one command</h2>
{code("curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash", "the host install command")}
<p>Re-running it is an <strong>upgrade</strong>: same units, same state, package reinstalled and the
services restarted.</p>

<h2 id="what-it-does">What it does, in order</h2>
<ol class="steps-list">
  <li><strong>Preflight.</strong> Python 3.11+, systemd, and a <code>hermes</code> binary it can find.
    It stops with a clear message rather than half-installing.</li>
  <li><strong>Service account.</strong> The bridge runs as the owner of the Hermes home — the account
    that can already read your bots' profiles. <code>HERMEY_USER</code> names a different one if you
    prefer; it then needs read access to the profiles directory. State lives in
    <code>/var/lib/hermey</code>.</li>
  <li><strong>Bridge.</strong> Installed into <code>/opt/hermey/venv</code>, run as
    <code>hermey-bridge.service</code>, bound to <code>127.0.0.1:8787</code>.</li>
  <li><strong>Gateway.</strong> Hermes allows one machine-level dashboard per host, so the installer
    <em>reuses</em> the one already running, reading its port and token from the process environment.
    Only when there is none does it create <code>hermey-gateway.service</code>.</li>
  <li><strong>TLS and reachability.</strong>
    <code>tailscale serve --bg --https=8443 http://127.0.0.1:8787</code> — a real certificate, tailnet
    only, no public listener. It then verifies the HTTPS endpoint answers.</li>
  <li><strong>The CLI.</strong> <code>hermey</code> in <code>/usr/local/bin</code>:
    <code>status</code>, <code>pair</code>, <code>logs</code>, <code>doctor</code>,
    <code>update</code>, <code>uninstall</code>.</li>
</ol>

{note("warn", "Never name a unit <code>hermes-gateway.service</code>.", "That is Hermes' own "
      "<em>messaging</em> gateway. The collision is silent until the next restart, when messaging does "
      "not come back. Hermey's units are <code>hermey-bridge.service</code> and, only when needed, "
      "<code>hermey-gateway.service</code>.")}

<h2 id="pairing">Pairing</h2>
{code("hermey pair", "the pairing command")}
<p>It prints a code, a <code>hermes://pair?host=…&amp;code=…</code> link and — when the
<code>qrcode</code> package could be installed — a QR. The <strong>link carries the address</strong>,
so it is the one to paste on a Mac that has never paired. The eight digits work on their own only once
the app already knows the host.</p>
<p>Codes are single-use and short-lived. Mint one when the phone is in your hand. Pair as many devices
as you like; each is individually revocable.</p>

<h2 id="options">Options</h2>
<p>Every flag is also readable as an environment variable, which matters when you pipe the script into
a shell.</p>
{table(["Flag", "Env", "Default", "Meaning"], [
  ["<code>--port N</code>", "<code>HERMEY_PORT</code>", "<code>8787</code>", "bridge port (loopback)"],
  ["<code>--https-port N</code>", "<code>HERMEY_HTTPS_PORT</code>", "<code>8443</code>", "tailnet port for <code>tailscale serve</code>"],
  ["<code>--ref R</code>", "<code>HERMEY_REF</code>", "<code>main</code>", "git ref to install; a release tag pins a build"],
  ["<code>--local DIR</code>", "<code>HERMEY_LOCAL_SRC</code>", "—", "install from a checkout instead of GitHub"],
  ["<code>--no-serve</code>", "<code>HERMEY_SERVE=no</code>", "auto", "do not touch <code>tailscale serve</code>"],
  ["<code>--uninstall</code>", "—", "—", "remove the units and the serve mapping, keep state"],
  ["<code>--purge</code>", "—", "—", "with <code>--uninstall</code>: also delete state, config and the service user"],
])}
<p>Paths are overridable too: <code>HERMEY_PREFIX</code> (<code>/opt/hermey</code>),
<code>HERMEY_STATE</code> (<code>/var/lib/hermey</code>), <code>HERMEY_CONF</code>
(<code>/etc/hermey</code>), <code>HERMEY_BINDIR</code>, <code>HERMEY_USER</code> and
<code>HERMEY_UNIT_PREFIX</code>. The last two exist so a second isolated instance can run for
testing.</p>

<h2 id="on-disk">What is on disk</h2>
{table(["Path", "What"], [
  ["<code>/opt/hermey/venv</code>", "the installed bridge"],
  ["<code>/var/lib/hermey/bridge.db</code>", "devices, tickets, room attachment index"],
  ["<code>/var/lib/hermey/room-attachments/</code>", "uploaded files"],
  ["<code>/etc/hermey/gateway.env</code>", "the loopback gateway token, <code>0600</code>, read as an <code>EnvironmentFile</code> so the token never sits in a world-readable unit file"],
  ["<code>/etc/hermey/providers.env</code>", "optional: the same for voice provider keys"],
  ["<code>/etc/systemd/system/hermey-bridge.service</code>", "the service"],
  ["<code>/etc/systemd/system/hermey-gateway.service</code>", "only created when this host had no dashboard"],
])}

<h2 id="without-tailscale">Without Tailscale</h2>
<p>The bridge refuses to listen on anything but loopback — that is a design invariant, not a default.
If the host has no tailnet, put your own TLS proxy in front of <code>127.0.0.1:8787</code> (Caddy with
a real certificate is the least work) and pass <code>--no-serve</code>.</p>
{code("sudo bash install.sh --no-serve", "install without tailscale serve")}
{note("warn", "A self-signed certificate will not work.", "The apps follow App Transport Security and "
      "refuse it. In this arrangement <code>hermey pair</code> prints the code alone, because there is "
      "no address to put in a link — add your public address in the app first, then enter the code.")}

<h2 id="uninstall">Uninstall</h2>
{code("curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash -s -- --uninstall", "the uninstall command")}
<p>Stops and removes the units, turns the <code>tailscale serve</code> mapping off, and keeps your
state and paired devices. Add <code>--purge</code> to delete <code>/opt/hermey</code>,
<code>/var/lib/hermey</code> and <code>/etc/hermey</code> as well.</p>
""",
))

PAGES.append(dict(
    slug="apps",
    nav="The apps",
    group="Getting started",
    title="The apps",
    lede="iOS and macOS, both unsigned. That is a deliberate trade-off: a few extra taps on first "
         "install, and no account anywhere.",
    body=f"""
<h2 id="ios">iOS and iPadOS</h2>
<ol class="steps-list">
  <li>Install <a href="https://altstore.io">AltStore</a> or <a href="https://sidestore.io">SideStore</a>
    following their setup for your device.</li>
  <li>Add this source in the app:
    {code("https://github.com/macblizzard/hermey/releases/latest/download/altstore.json", "the AltStore source URL")}
    It is a release asset on purpose: the latest release always serves the newest build, with no host
    of our own in the loop.</li>
  <li>Install <strong>Hermey</strong> from the source.</li>
</ol>
<p>Any signing tool that accepts an unsigned IPA works (Sideloadly, Feather, or Xcode with a free Apple
ID).</p>
{note("warn", "A free Apple ID signs for about seven days.", "Then the app stops launching until it is "
      "re-signed. AltStore and SideStore re-sign in the background while you are on the same network as "
      "their server; a paid developer account extends that to a year. The app itself needs no account.")}

<h2 id="macos">macOS</h2>
<ol class="steps-list">
  <li>Download the disk image from
    <a href="https://macblizzard.github.io/hermey-downloads/">macblizzard.github.io/hermey-downloads</a>
    — a direct link, with no release-CDN redirect in front of it. The newest build is published as
    <code>Hermey-macOS-&lt;version&gt;.dmg</code>, so the filename tells you which build you have. Open
    the image and drag Hermey onto the Applications shortcut.</li>
  <li>The build is unsigned, so macOS quarantines it once. Either right-click → <strong>Open</strong> →
    <strong>Open</strong>, or run:
    {code("xattr -dr com.apple.quarantine /Applications/Hermey.app", "the quarantine removal command")}
    macOS remembers the choice. Moving or re-downloading the app brings the mark back with the new
    copy.</li>
  <li>Pair the same way as the phone: run <code>hermey pair</code> on the host and paste the code or
    the whole link into <strong>Pairing code or link</strong> — the Mac has no camera. A hand-issued
    device token still works under <strong>Advanced</strong>.</li>
</ol>
<p>macOS 14 or later is required.</p>

<h2 id="first-run">First run</h2>
<ul>
  <li>Add a server: paste <code>https://&lt;host&gt;.&lt;tailnet&gt;.ts.net:8443</code> or scan the QR.</li>
  <li>Enter the code from <code>hermey pair</code>.</li>
  <li>The bot list is the home screen. Tap a bot for its endless conversation; the room list is behind
    the three-dot menu.</li>
</ul>

<h2 id="notifications">Notifications and badges</h2>
<p>A bot's reply earns a notification when <em>that bot is not the one on screen</em> — a chat you are
reading has already told you. Both apps put the total waiting on the Dock tile or the app icon.</p>
{table(["Platform", "How it behaves"], [
  ["macOS", "Delivers a banner as soon as the host reports the reply, even in the background; clicking "
            "it opens that conversation."],
  ["iOS, app open", "Delivers while the app is running."],
  ["iOS, app closed", "Falls back to a background refresh iOS schedules — expect delays in the tens of "
                      "minutes, and only while the phone is awake."],
])}
<p><strong>The relay closes that gap, and it is the only way a sideloaded build can.</strong> Push needs
a credential for the team that signed the app, which a personal install does not have — so the host
posts the banner to an app that already holds one. Install <strong>Bark</strong> (free), copy the
address it shows, and paste it into <strong>Settings → Replies</strong> (iOS) or
<strong>Settings → Notifications</strong> (macOS). <strong>Send a test</strong> proves it.</p>
<p>Settings has one switch and a per-bot quiet list. A quieted bot still counts on its row and in the
badge; it just never buzzes. Reactions, drafts, pins and the switch are per-device; unread counts come
from the host and survive a reinstall.</p>

<h2 id="revocation">Unpairing and revocation</h2>
<p>Removing a device in the app deletes its key. Revoking from the host closes that device's link
immediately and refuses the next connection — the token it held is spent. Neither touches your bots,
your profiles or anything else on the host.</p>
""",
))

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

<h2 id="cli">From a bot's shell</h2>
{code('hermey computer observe\nhermey computer act \'[{"kind":"click","x":120,"y":80}]\'', "the computer CLI")}
<p>The same commands are documented for agents in the shared <code>mac-local-computer</code> skill that
the bridge installs for every bot on the host.</p>
""",
))

PAGES.append(dict(
    slug="agents",
    nav="For agents",
    group="Automation",
    title="For agents",
    lede="The installation procedure written for an executor rather than a reader: preflight, install, "
         "two hard verification gates, then the pairing handoff.",
    body=f"""
<p>If you are an agent with a root shell on the user's Hermes host, this page is your runbook. The
authoritative long form lives in <a href="{REPO}/blob/main/docs/FOR-AGENTS.md">docs/FOR-AGENTS.md</a>;
it is also packaged as a skill in <a href="{REPO}/blob/main/setup/SKILL.md">setup/SKILL.md</a>.</p>

<h2 id="who-does-what">Who does what</h2>
{table(["Actor", "Owns"], [
  ["You (agent)", "Preflight, install, verification, pairing code, handover of both app links."],
  ["The human", "The phone or Mac, and the decision to pair it."],
  ["Never you", "Their profiles, their bots, their other services, their tailnet configuration."],
])}

<h2 id="runbook">Runbook</h2>
<ol class="steps-list">
  <li><strong>Confirm this is the right host.</strong> Hermes must already run here and have profiles
    the human talks to.</li>
  <li><strong>Install.</strong>
    {code("curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash", "the host install command")}
  </li>
  <li><strong>Verify before you say it works.</strong> Both gates must pass:
    {code("hermey doctor\ncurl -fsS https://<host>.<tailnet>.ts.net:8443/v1/health", "the verification commands")}
    The second answers <code>{{"status":"ok", …}}</code>. If it does not, do not proceed — go to the
    failure playbook.</li>
  <li><strong>Pair the human's device.</strong> Run <code>hermey pair</code> and give them the code or
    the full link. Do not paste a code into a public channel.</li>
  <li><strong>Hand over the apps.</strong> The AltStore source for iOS, the downloads page for macOS,
    and the seven-day re-sign caveat.</li>
</ol>

<h2 id="hard-rules">Hard rules</h2>
<ul class="rules">
  <li>Never bind the bridge to anything but <code>127.0.0.1</code>. <code>tailscale serve</code> is the
    only front door.</li>
  <li>Never create a unit named <code>hermes-gateway.service</code>. That is Hermes' messaging gateway.</li>
  <li>Never add App Transport Security exceptions to the apps. The certificate must be real.</li>
  <li>Never stop or reconfigure an existing tailnet service to free port 8443 — reinstall with
    <code>--https-port 8444</code>.</li>
  <li>Do not touch the user's profiles or bots. Hermey reads them; it does not own them.</li>
  <li>Copy no secrets into chat or logs. Provider keys go in <code>/etc/hermey/providers.env</code>
    (<code>0600</code>).</li>
</ul>

<h2 id="failure-playbook">Failure playbook</h2>
{table(["Symptom", "Cause", "Fix"], [
  ["<code>the bridge did not answer on 127.0.0.1:8787</code>", "port taken, venv broken, or a crash on start",
   "<code>hermey logs 80</code>; <code>sudo ss -ltnp | grep 8787</code>; reinstall with <code>--port 8788</code>"],
  ["<code>reusing this host's dashboard: pid …</code>", "a dashboard exists; Hermes allows one", "expected — let it reuse; <code>hermes dashboard --status</code>"],
  ["doctor health FAIL, audit says <code>upstream_error</code> / <code>connect_failed</code>", "the dashboard is not answering, or restarted with a new token", "re-run the installer; it re-reads both"],
  ["<code>tailscale serve</code> refused", "not root, or serve not enabled on the tailnet", "run as root; <code>tailscale serve status</code>"],
  ["HTTPS fails, loopback healthy", "serve mapping points elsewhere, or wrong DNS name", "<code>tailscale serve status</code>; <code>--https-port</code>"],
  ["App connects nowhere, host healthy", "phone not on the tailnet, or ATS rejecting a self-signed cert", "join the tailnet; use the <code>ts.net</code> name"],
  ["Pairing code rejected", "expired — they are short-lived", "<code>hermey pair</code> again"],
  ["iOS app stops launching after ~a week", "free-Apple-ID signature expired", "re-sign through AltStore/SideStore"],
])}

<h2 id="done">Definition of done</h2>
<ul class="checklist">
  <li><code>hermey doctor</code> — unit active, health ok, HTTPS ok</li>
  <li><code>curl</code> against <code>/v1/health</code> answers <code>ok</code></li>
  <li>The human has a pairing code or link</li>
  <li>The human has both app links and knows the iOS re-sign caveat</li>
  <li>You changed nothing else on the host</li>
</ul>

<h2 id="facts">Facts you can rely on</h2>
{table(["", ""], [
  ["Units", "<code>hermey-bridge.service</code> always; <code>hermey-gateway.service</code> only if the host had no dashboard"],
  ["Ports", "bridge <code>127.0.0.1:8787</code> (loopback only), tailnet <code>8443</code>"],
  ["Paths", "<code>/opt/hermey/venv</code>, <code>/var/lib/hermey</code>, <code>/etc/hermey/*.env</code> (0600)"],
  ["CLI", "<code>hermey status | pair | logs [n] | doctor | update | uninstall</code>"],
])}

<h2 id="no-tailnet">No tailnet</h2>
<p>Install with <code>--no-serve</code>, terminate TLS in front of <code>127.0.0.1:8787</code> with a
real certificate, and give the apps that URL. Self-signed certificates are refused — do not work around
that in the app.</p>
""",
))

PAGES.append(dict(
    slug="troubleshooting",
    nav="Troubleshooting",
    group="Reference",
    title="Troubleshooting",
    lede="Symptom, cause and fix — with the strings you will actually see.",
    body=f"""
<h2 id="start-here">Start here</h2>
{code("hermey doctor", "the doctor command")}
<p>It reports the unit state, loopback health, the gateway URL the bridge relays to, Tailscale's state,
and whether the HTTPS endpoint answers through the certificate.</p>

<h2 id="health-fail">Doctor says health FAIL</h2>
<p>The bridge is not answering on <code>127.0.0.1:8787</code>. Read its log; the first line usually
names the cause.</p>
{code("hermey logs 80", "the log command")}
{table(["Log line", "Meaning"], [
  ["<code>address already in use</code>", "something else holds the port — <code>sudo ss -ltnp | grep 8787</code>, then reinstall with <code>--port 8788</code>"],
  ["<code>\"event\": \"upstream_error\"</code> with <code>\"reason\": \"connect_failed\"</code>", "the dashboard it relays to is not answering on the port the unit was given, or restarted with a different token; re-run the installer so it re-reads both"],
  ["<code>No module named hermes_bridge</code>", "the venv is broken; re-run the installer (it reinstalls)"],
])}

<h2 id="dashboard-exists">\"Reusing this host's dashboard: pid …\"</h2>
<p>Expected. Hermes allows one dashboard per host and the installer reuses it. For a second isolated
one while testing, use <code>HERMEY_UNIT_PREFIX</code> and a separate <code>HERMEY_CONF</code>, and
point the second bridge at a dashboard you started with <code>--isolated</code>.</p>

<h2 id="serve-refused">tailscale serve refused</h2>
{code("tailscale status\ntailscale serve status", "the tailscale status commands")}
<p>If another service owns <code>8443</code>, re-run the installer with <code>--https-port 8444</code>.
Do not stop the other service to make room.</p>

<h2 id="https-fails">HTTPS fails but the bridge is healthy</h2>
<p>Tailscale issues the certificate on first use; a fresh domain can take a minute. If it persists:</p>
{code("tailscale cert <host>.<tailnet>.ts.net\ncurl -v https://<host>.<tailnet>.ts.net:8443/v1/health", "the certificate diagnosis")}

<h2 id="app-cannot-reach">The app cannot reach the host</h2>
<ul>
  <li>Is the device on the tailnet, logged into the same one?</li>
  <li>Does the URL in the app exactly match <code>hermey pair</code>'s output, including the port?</li>
  <li><code>curl https://&lt;host&gt;.&lt;tailnet&gt;.ts.net:8443/v1/health</code> from another tailnet
    device — if that fails, the problem is the host, not the app.</li>
</ul>

<h2 id="code-rejected">A pairing code is rejected</h2>
<p>Codes are single-use and expire in minutes. Mint a fresh one with <code>hermey pair</code>. Repeated
failures are rate limited per client, so wait a moment after a handful of attempts.</p>

<h2 id="ios-week">The iOS app stops launching after a week</h2>
<p>That is free-Apple-ID signing, not a bug. Re-sign through AltStore or SideStore, or use a paid
developer account for a one-year profile.</p>

<h2 id="mac-damaged">macOS says the app is damaged</h2>
<p>The build is unsigned. Right-click → Open the first time, or once:</p>
{code("xattr -dr com.apple.quarantine /Applications/Hermey.app", "the quarantine removal command")}

<h2 id="computer-down">Computer use keeps dropping</h2>
<p>The Mac app must be running to hold the link. A machine that sleeps loses its socket; the app
re-verifies on wake, and the host drops a Mac that stops answering so callers fail fast instead of
hanging. If it stays down, open <strong>Settings → Computer</strong> on the Mac and read the status
row, then check <code>hermey doctor</code> on the host.</p>
""",
))

PAGES.append(dict(
    slug="security",
    nav="Security",
    group="Reference",
    title="Security and threat model",
    lede="The tailnet is the wall, the device is the identity, and the client can only answer the "
         "questions the agent asks — never give itself permission.",
    body=f"""
<p>The full document, including the audit and its residual risks, is
<a href="{REPO}/blob/main/docs/SECURITY.md">docs/SECURITY.md</a>. This page is the shape of it.</p>

<h2 id="boundaries">Trust boundaries</h2>
{table(["Boundary", "Crossing it requires", "What is on the other side"], [
  ["Public internet → tailnet", "Tailscale identity + ACL", "nothing: no public ingress exists"],
  ["Tailnet → bridge", "TLS to <code>tailscale serve</code>, then a single-use 30 s ticket", "pairing, tokens, <code>/v1/ws</code>"],
  ["Bridge → gateway", "loopback plus the gateway token, which is never sent to a device", "full authority over the agent"],
  ["Gateway → app", "a server-to-client request (approval, clarify, sudo, secret)", "a human decision"],
  ["App → gateway", "the client method allow-list", "sessions, prompts, discovery"],
])}

<h2 id="invariants">Invariants</h2>
<ul>
  <li>The bridge listens on loopback only; <code>tailscale serve</code> is the only front door.</li>
  <li>Tickets are single-use and expire in 30 seconds; a device is identified by its own Ed25519 key.</li>
  <li>The device never receives the gateway token — it cannot talk to the agent directly.</li>
  <li>Approvals are the agent's to ask and the human's to answer; a device cannot grant itself
    authority.</li>
  <li>Revocation is immediate and per-device.</li>
</ul>

<h2 id="absent">Deliberately absent</h2>
<ul>
  <li>No account, no analytics, no crash reporting, no relay of ours in the request path.</li>
  <li>No public ingress: if the tailnet is up but the device is not on it, nothing is reachable.</li>
  <li>No per-bot permission system on the Mac. Computer use is one owner-level switch — a small number
    of trusted bots is the stated model.</li>
</ul>

<h2 id="storage">Where the apps keep secrets</h2>
<p>The phone keeps its device key and refresh token in the Keychain, this-device-only. The Mac build
ships unsigned and has no Keychain entitlement, so it keeps the same items in a <code>0600</code> file
under <code>~/Library/Application Support/Hermey/</code>, excluded from backups.</p>

<h2 id="reporting">Reporting a problem</h2>
<p>Open a private advisory at
<a href="{REPO}/security/advisories/new">{REPO}/security/advisories/new</a> rather than a public
issue, and do not paste tokens, hostnames or personal data into either.</p>
""",
))

PAGES.append(dict(
    slug="reference",
    nav="Reference",
    group="Reference",
    title="Reference",
    lede="The facts a script, an agent or a tired human needs: commands, ports, paths and URLs.",
    body=f"""
<h2 id="cli">CLI</h2>
{table(["Command", "What it does"], [
  ["<code>hermey status</code>", "unit, port and health at a glance"],
  ["<code>hermey pair</code>", "mints a code, a <code>hermes://</code> link and a QR when possible"],
  ["<code>hermey logs [n]</code>", "the bridge journal, newest last"],
  ["<code>hermey doctor</code>", "unit, loopback health, gateway URL, Tailscale state, HTTPS through the certificate"],
  ["<code>hermey update</code>", "reinstall from the configured ref"],
  ["<code>hermey uninstall</code>", "remove units and the serve mapping, keep state"],
  ["<code>hermey computer …</code>", "observe / act / files / browser against a paired Mac"],
])}

<h2 id="ports">Ports and units</h2>
{table(["", ""], [
  ["Bridge", "<code>127.0.0.1:8787</code> — loopback only, by design"],
  ["Tailnet", "<code>:8443</code> via <code>tailscale serve</code>, real certificate"],
  ["Units", "<code>hermey-bridge.service</code>; <code>hermey-gateway.service</code> only when the host had no dashboard"],
  ["Never", "a unit named <code>hermes-gateway.service</code> — that is Hermes' messaging gateway"],
])}

<h2 id="paths">Paths</h2>
{table(["Path", "What"], [
  ["<code>/opt/hermey/venv</code>", "the installed bridge"],
  ["<code>/var/lib/hermey/bridge.db</code>", "devices, tickets, attachment index"],
  ["<code>/var/lib/hermey/room-attachments/</code>", "uploaded files"],
  ["<code>/etc/hermey/gateway.env</code>", "gateway token, <code>0600</code>"],
  ["<code>/etc/hermey/providers.env</code>", "optional voice provider keys, <code>0600</code>"],
  ["<code>~/Library/Application Support/Hermey/Computer/Workspace/</code>", "the Mac's shared workspace for computer use"],
])}

<h2 id="health">Endpoints</h2>
{table(["URL", "Answers"], [
  ["<code>GET /v1/health</code>", "<code>{{\"status\":\"ok\"}}</code> on loopback or through the tailnet front door"],
  ["<code>/v1/ws</code>", "the device websocket (single-use 30 s ticket, then a session)"],
  ["<code>/v1/pair/start</code>", "begins a pairing exchange"],
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


def page_html(index: int) -> str:
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
<link rel="stylesheet" href="assets/docs.css">
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
    <p>MIT licensed · the source docs in <a href="{REPO}/tree/main/docs">github.com/macblizzard/hermey/docs</a>
      are the authority for this site. Found a mistake? <a href="{REPO}/issues">Open an issue</a>.</p>
  </div>
</footer>

<script src="assets/docs.js"></script>
</body>
</html>
"""


def main() -> int:
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "docs")
    (out / "assets").mkdir(parents=True, exist_ok=True)

    (out / "assets" / "docs.css").write_text(CSS.strip() + "\n", encoding="utf-8")
    (out / "assets" / "docs.js").write_text(JS.strip() + "\n", encoding="utf-8")

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
        (out / f'{page["slug"]}.html').write_text(page_html(i), encoding="utf-8")

    print(f"wrote {len(PAGES)} pages + assets to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
