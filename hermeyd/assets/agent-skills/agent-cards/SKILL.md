---
name: agent-cards
description: Cards for questions, approvals, tasks (Hermey + Desktop).
managed_by: hermey-bridge
version: 1.1.0
author: Hermes Bot Kit
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [desktop, cards, approval, task, email, infographic]
  hermes-bot-kit:
    skill: agent-cards
---

# Agent Cards

In a card-capable chat you show a card instead of describing things in prose: a question with buttons,
an approval to confirm before you act, a task whose progress updates in place, or a short answer with a
picture. Hermes Desktop draws them, and so do the native Hermey apps (macOS/iOS); Slack, Telegram, the
CLI, the TUI and the rest do not — there you write plain text.

## Cards first — the standing rule

**The owner's rule, in his words:** *"all bots always use cards wherever possible, any multiple choice
question it asks me should use a card. any sensitive entries it needs from me like an api or something
should come to me as a secure entry card."* It holds on every turn, for every bot. You never wait to be
asked for a card, and you never ask whether he wants one.

- **R1 — A multiple-choice question is a card, never prose.** Two or more options never go in a
  sentence, a bullet list **or a numbered list**. It is one `approval` card whose buttons *are* the
  options: two or three of them, the recommended one first with `"style": "primary"`. The exact JSON is
  §1 of this file — nowhere else describes it.
- **R2 — An approval is a card, never a printed question.** Send, post, publish, delete, pay, book,
  restart, recreate — anything outward or irreversible — is an `approval` card (§2) and then a wait. A
  sentence ending in "shall I?", "want me to?" or "confirm?" is the failure this rule exists to stop.
- **R3 — Plain text only where nothing can draw.** Messaging adapters, the CLI/TUI, `api_server`, cron
  and subagent runs have no renderer: there, ask in one plain line. The table below is how you tell
  which chat you are in — read it instead of guessing.
- **R4 — Secrets never come through chat (SECURE-ENTRY).** An API key, token, password, PIN, card
  number or any login is asked for with the credential card, never in a message, and a secret pasted
  into chat is refused and never repeated or echoed. See §"Secure entries".

## Which chat am I in? (can a card draw here?)

Your system prompt carries a `Platform:` line. It names the surface you are answering on, and it decides
this:

| `Platform:` line | Cards draw? | What you do |
|---|---|---|
| `desktop` (Hermes Desktop) | yes — `::card` draws, and `clarify` draws | card |
| a bot-chat surface (`bot_chat`, `bot_room` — the native Hermey apps, bot-to-bot rooms) | `::card` draws; **`clarify` draws nothing** | `::card` only |
| `tui`, `cli` | no | plain text |
| a messaging adapter — `telegram`, `discord`, `slack`, `whatsapp`, `signal`, `matrix`, `email`, `sms`, `api_server`, `webhook`, `qqbot`, `feishu`, … | no | plain text |
| `cron` | no, and nobody is present to answer | do not ask; decide and report |
| `subagent` | no | plain text; the decision belongs in your report to the parent |
| a name you do not recognise | assume `::card`-only | post the `::card` line anyway — a host without the route shows the prose around it — and never leave a question resting only on a tap |

Two failure modes this prevents: posting a `::card` into Telegram (the owner sees `::card{…}` as literal
text), and calling `clarify` in a native app (nothing draws, the turn dies waiting). When he says the card
is not there, stop posting cards in that thread and ask the same question in one plain line — §"Other
channels" below.

## When to show a card

1. Any choice or yes/no confirmation: an `approval` card whose buttons are the options (R1). `clarify` is
   an additional shortcut on Hermes Desktop only — never the only route.
2. Before anything outward or irreversible (sending, posting, paying, booking, deleting, restarting): an
   approval card, then wait (R2).
3. A job that takes more than about a minute: one task card, kept up to date.
4. A credential, key, token or login: the credential card (§"Secure entries", R4).
5. Everything else: plain text.

## 1. A question with options is always a card

**Rule: whenever you ask the owner to choose between two or more options, ask it with a card — not as a
line of prose, and not with `clarify` on a native client.**

`clarify` only renders in Hermes Desktop. In Hermey (the native Mac/iOS app) it draws nothing, so a
question asked that way is invisible and the turn dies waiting. The card file below works in both, and
the answer arrives as an ordinary message you can act on.

The shape: one `approval` card whose actions are the options.

```json
{
  "schema": "card.v1",
  "kind": "approval",
  "title": "Which night works?",
  "status": { "state": "awaiting-approval" },
  "body": [ { "type": "text", "text": "Pick one and I will book it." } ],
  "actions": [
    { "label": "Thursday", "send": "Thursday", "style": "primary" },
    { "label": "Friday", "send": "Friday" },
    { "label": "Saturday", "send": "Saturday" }
  ],
  "resolved": null
}
```

Then write the file under `cards/<id>.json` in this chat's working directory and put the marker on its
own line in your reply:

    ::card{id="q-1" kind="approval" file="cards/q-1.json"}

Rules that keep this usable:

- **Two to three options** (the card draws at most three buttons). A fourth is a conversation, not a card.
- **The recommended option goes first and carries `"style": "primary"`.**
- The `send` string is what the owner's tap becomes: a short, unambiguous phrase you can act on
  ("Thursday", not "the option labelled Thursday"). Put the whole question in `title` so the card reads
  on its own.
- **Never ask in prose as well.** One card, one question, then stop and wait.
- Somebody who wants to answer in their own words simply types a message; do not add an "Other" button.

Use `clarify` only in Hermes Desktop, where it is the shortest route to the same question. In the CLI or a
chat transport with no renderer (Telegram, Slack) ask in one plain line — a `::card` line there is literal
text, not a question.

## 1b. Question cards on Desktop: the `clarify` tool

You need no files for these. Call `clarify` with one to five questions:

```json
{ "questions": [ { "question": "Which night works?", "choices": ["Thursday", "Friday", "Saturday"] } ] }
```

- Up to four `choices` per question (each a short label). The card always adds a row where the user can
  type their own answer.
- `"multi_select": true` lets the user pick several.
- Leave out `choices` to ask an open question.
- Put your suggestion first and the card marks it recommended.

The answer comes back as the tool's result. Continue from it; do not ask the same thing again in text.

## 2. Approval, task, email and infographic cards: a card file plus one line

These cards live in a JSON file in your working directory for this chat. Your reply only points at it.

### The card file

Write the file with your file tool at a **relative** path, by convention `cards/<id>.json`. The id is
`c-` plus a short slug, unique in this chat (`c-7f3a`). The whole file must stay under 32 KB.

```json
{
  "schema": "card.v1",
  "kind": "approval",
  "title": "Book the lake cabin",
  "status": { "state": "awaiting-approval" },
  "body": [
    { "type": "kv", "rows": [["Night", "Friday"], ["Guests", "2"], ["Total", "$180"]] }
  ],
  "actions": [
    { "label": "Book it", "style": "primary", "send": "APPROVE c-9b book the cabin" },
    { "label": "Not yet", "send": "HOLD c-9b" }
  ]
}
```

Fields (anything else is ignored; a file that breaks a required rule shows "Card not available"):

| Field | Rule |
|---|---|
| `schema` | Required. Exactly `"card.v1"`. |
| `kind` | Required. `"approval"`, `"task"`, `"draft-email"` or `"infographic"`. |
| `title` | Required, not empty. The card's bold heading. For `infographic`, at most 120 characters. |
| `status.state` | Required for `approval`, `task` and `draft-email`. `"pending"`, `"running"`, `"done"`, `"error"` or `"awaiting-approval"`. Leave it out of an `infographic` — that card is finished when you write it. |
| `status.label` | Optional. Replaces the state's own wording in the status chip. |
| `body` | Optional list of blocks, drawn in order (see below). Not used by `infographic`. |
| `email` | For `draft-email`: `{ "to", "cc", "subject", "bodyText" }`, all strings. |
| `actions` | Optional. At most 3 buttons: `{ "label", "send", "style"? }`. Not used by `infographic`. |
| `resolved` | Optional. `null`, or `{ "action": "<clicked label>", "at": "<ISO-8601 time>" }` once you have acted. |
| `subtitle` | For `infographic`: one short line under the title (at most 160 characters). |
| `image` | For `infographic`: the picture's **http(s)** URL. No URL, or any other scheme (`file:`, `data:`), means the card draws no picture at all. |
| `imageCaption` | For `infographic`: what the picture shows, at most 120 characters. It is dropped with the picture if there is no picture. |
| `facts` | For `infographic`: 3 to 8 `{ "label", "value" }` objects. Label at most 40 characters, value at most 80. |
| `highlight` | For `infographic`: `{ "value", "label"?, "seller"?, "availability"? }` — the one number that matters (a price, a length), plus the seller and stock line for a product. |
| `link` | For `infographic`: `{ "label", "url" }` with an **http(s)** URL — the one row that leaves the app. |
| `source` | For `infographic`: where the facts came from, at most 80 characters, e.g. `"Wikipedia"` or `"amazon.de · checked just now"`. |

Body blocks:

- `{ "type": "text", "text": "..." }`: a paragraph. A card whose whole body is one short line (under 200
  characters, no line breaks) shows that line as the question under the title.
- `{ "type": "kv", "rows": [["Label", "Value"], ...] }`: label and value rows.
- `{ "type": "fields", "items": [{ "label": "...", "value": "..." }, ...] }`: the same, as objects.

Actions:

- `label` is the button text; `send` is the message the chat sends back to you, hidden from the
  transcript, when the button is clicked. Keep `send` under 500 characters and start it with a word and
  the card id (`APPROVE c-9b`, `HOLD c-9b`, `STOP c-8t`) so you can match it. When `send` differs
  from `label`, the row shows the `send` text as a smaller second line, so the user sees what a click
  sends.
- `style` is `"primary"` or `"danger"`; leave it out for a plain button.
- After one click, or once the file has `resolved`, the buttons stop working and the chosen one is ticked.

How each kind is drawn:

- `approval`: title, body and the buttons. No status chip.
- `task`: title, a status chip for `running` (with a spinner), `done` and `error`, then the body and any
  buttons (for example a `Stop` button with `"style": "danger"`).
- `draft-email`: the subject as the heading (the title when there is no subject), To and Cc rows, the
  body text, then the buttons.
- `infographic`: the picture on top with its caption under it, then the title and subtitle, the
  highlight as a big value in a tinted block (with the seller and availability under it when you
  wrote them), the facts as label/value rows, the link as one button-like row, and the source as the
  quiet last line.

### Infographics: a short answer, as a glance

When the owner asks a question with a short answer that has a picture — "where is the Golden Gate
Bridge", "what does this product cost on amazon.de", "how tall is the Eiffel Tower" — answer with an
`infographic` card instead of a paragraph. It is a **summary**: one picture, the number that matters,
three to eight facts, one link, one source. If you are writing a second paragraph of prose, the card
is the wrong shape.

A place:

```json
{
  "schema": "card.v1",
  "kind": "infographic",
  "title": "Golden Gate Bridge",
  "subtitle": "San Francisco, California",
  "image": "https://upload.wikimedia.org/wikipedia/commons/0/0c/GoldenGateBridge-001.jpg",
  "imageCaption": "The bridge from Fort Point",
  "highlight": { "label": "Main span", "value": "1,280 m" },
  "facts": [
    { "label": "Opened", "value": "27 May 1937" },
    { "label": "Total length", "value": "2,737 m" },
    { "label": "Clearance", "value": "67 m" },
    { "label": "Colour", "value": "International Orange" }
  ],
  "link": { "label": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Golden_Gate_Bridge" },
  "source": "Wikipedia"
}
```

A product: the price is the highlight, and the seller and the stock line ride with it.

```json
{
  "schema": "card.v1",
  "kind": "infographic",
  "title": "Anker 737 Power Bank",
  "subtitle": "24,000 mAh, 140 W",
  "image": "https://m.media-amazon.com/images/I/<the-image-id-from-the-page>.jpg",
  "highlight": {
    "label": "Price",
    "value": "€ 129.99",
    "seller": "Sold by Anker Direct DE",
    "availability": "In stock"
  },
  "facts": [
    { "label": "Capacity", "value": "24,000 mAh" },
    { "label": "Output", "value": "140 W" },
    { "label": "Ports", "value": "2 × USB-C, 1 × USB-A" }
  ],
  "link": { "label": "Open on amazon.de", "url": "https://www.amazon.de/dp/<the-asin-from-the-page>" },
  "source": "amazon.de · checked just now"
}
```

`<…>` is the part you copy from the page you just read — the image's own id, the product's own ASIN.
The bridge's URL above is a real Commons file; the product's are templates, because a made-up image
URL is exactly the failure this card exists to avoid.

The rules that matter, in the owner's words:

- **The picture must be real.** Use the picture the page itself serves (the product's own image URL,
  a Commons photograph). Never write a URL you did not see, never a placeholder, never "an image of
  X" from an unrelated page. If you could not find a picture, leave `image` out — the card still
  lays out, and a card with no picture is honest where a made-up one is not.
- **It is a summary.** Values are short by design: the host refuses a title over 120 characters, more
  than 8 facts, and a fact value over 80. If a value does not fit, it belongs in your prose.
- **One link.** The product page or the place's own page — not a list.
- **The source line is where you say how fresh it is** (`amazon.de · checked just now`). A price with
  no date is a price the owner cannot judge.
- A card that breaks a bound is refused with `422 bad_card` and a `detail` naming the field, so fix
  that field and write the file again.

### The line in your reply

Put this on its own line in your reply (nothing else on that line):

```
::card{id="c-9b" kind="approval" file="cards/c-9b.json"}
```

- `file` is required and must be relative to your working directory: never an absolute path, a `~`
  path, a URL or a path with `..`.
- `id` and `kind` should match the file; `kind` is also the label shown if the file cannot be read.
- **Writing the file is not showing the card.** The `::card{…}` line in your reply is the only delivery
  mechanism: a turn that writes `cards/<id>.json` and then says "it's on the card above", "the card is up" or
  links the file name shows the owner **nothing**, and he answers "where's the card". Every card turn carries
  the tag, on its own line, in the same reply as the sentence you write about it.
- Keep the line out of code blocks and backticks, or it is shown as text.
- One line per card. Text before and after it in the same reply is shown around the card.

### Live updates

While the chat is open, a card in one of the chat's last eight messages re-reads its file every three
seconds, for up to 30 minutes, and stops as soon as the file is final (`resolved` set, or `status.state`
`done` or `error`). To update a card, **rewrite the same file**. Never post a second `::card` line for the
same card: the attributes of a line already sent cannot change.

### Previews

`::preview{file="page.html"}` on its own line shows a workspace HTML file in a sandboxed frame. The
frame has **no network**: no requests, no remote scripts, styles, fonts or images (its policy is
`default-src 'none'`, with inline script and style, and `data:` / `blob:` images, fonts and media). Write
a self-contained page: inline `<style>` and `<script>`, images as `data:` URLs. A page can call
`window.hermes.send("...")` (or use `data-hermes-send="..."` on a button); it is sent at once only when the
user has just clicked into the frame. Otherwise the user sees the exact text under the frame with
**Send** and **Dismiss**, and nothing is sent until they click Send.

## Secure entries — never ask for a secret in chat (`SECURE-ENTRY`)

**Requirement, named `SECURE-ENTRY`.** Any value that is a credential — an API key, access token,
password, PIN, one-time code, card number, or the details of a login — is asked for with a card the app
fills in, never with a chat message and never with `clarify`. The owner types it into the card; the value
is never echoed into the transcript, never quoted from a tool result, never written to a file, a memory or
a summary. It is handed over once, used, and dropped.

Two states — know which one you are in:

- **Shipped today: the credential card.** hermeyd serves `/v1/credentials/cards` and the bot drives it
  through `hermey_signin.py`, whose exact commands, kinds (`secret`, `choice`, `confirm`) and flags live in
  the **`signin` skill**. That skill — not this one — carries the exact call; load it before asking for
  anything sensitive and never hand-build the request. For a bare secret it is
  `hermey_signin.py ask --site <name> --kind secret --fields "api key" --note "<why>"`.
- **Named, not yet a `card.v1` kind: `secure-entry`.** The intended addition to `card.v1` is a
  `secure-entry` card (masked fields, one submit, the value handed over once). Until the apps and hermeyd
  ship it the kind is **unknown to the renderer**: do not write `"kind": "secure-entry"` into a card file,
  because a build that cannot read it shows "Card not available" and the owner is left without a question.
  When it lands, its JSON is documented in this section *and* in `signin`, updated together — no third
  file describes the schema, so the rule and the contract cannot drift.

Either way the rule is the same: **a secret is never asked for in prose.** "Paste your API key here" is
the one instruction you never give, on any surface — including Telegram and the CLI where no card can
draw. There, say where the key belongs (the secrets store, a `chmod 600` file, an env var), have the owner
put it there himself, and read it from the file rather than the chat. On a host with no Hermey app the
vault is the route (`web-login-1password-otp`, `browser_vault`), and still never chat. A secret that
arrives in chat anyway is not used as proof of anything: say it is exposed, tell him to rotate it, and do
not repeat it back.

## Email

When you have the `email_draft_create` tool, every email goes through it (it draws its own draft card with
Send and Discard): never write a `draft-email` card file for an email then. Without that tool, use a
`draft-email` card and the approval flow below.

**Without that tool, do not hand-write the JSON each time.** The `mail-draft-card` skill wraps this exact
contract in two commands — `scripts/draft.py` writes `/root/cards/<id>.json` and prints the `::card{…}` line,
`scripts/send.py <id>` sends the approved card through the owner's own transport and marks it `done`. It
exists so a "draft me a mail" request costs no turn spent re-deriving the schema or re-choosing a sender on
approval; load it before writing a mail card by hand.

A `draft-email` card carries `cc` as well as `to`, and the Cc row is drawn — fill it whenever the owner names
a second address, and check the sent copy actually shows it before reporting.

## Approval flow

1. Write `cards/<id>.json` with `kind` `approval` (or `draft-email` for a message you drafted),
   `status.state` `awaiting-approval` and two actions, for example `APPROVE <id> ...` and `HOLD <id>`.
2. Post the `::card` line and stop. Do not act yet.
3. When a message starting `APPROVE <id>` arrives, do the action. On `HOLD <id>` (or anything else), do
   not.
4. Rewrite the file: set `resolved` to the clicked label and the time, and `status.state` to `done` (or
   `error` if the action failed). Then report the result in a short line of text.

The button does nothing by itself: you perform the action, and only after the approval message arrives.
Never set `resolved` before you have acted.

## Task flow

1. Write one `task` card with `status.state` `running` and a body that says what you are doing, then post
   its `::card` line.
2. As work progresses, rewrite the same file (counts in a `kv` block work well).
3. Finish with `done` or `error` and a final body. If you gave it a `Stop` button and a `STOP <id>`
   message arrives, stop the work and mark the card `error` with a short reason, or `done` if nothing
   was left to do.

## Long text the user will copy

A handoff, a prompt, a spec, or any block over about 15 lines: write it to a `.md` file in your working
directory for this chat, and send it with a line of its own:

```
MEDIA:/absolute/path/to/handoff.md
```

Use the file's absolute path. In the bubble, write one short sentence about what the file is. Do not
paste the text into the reply as a giant code block: the Desktop chat shows the file as a card the user
can open, copy all of, or download.

## Link your sources

When a line of your reply is about a specific message, email, doc, ticket, PR or event you read, end
that line with `[short label](permalink)`: two or three words, such as "Her message", "The email",
"The PR". One link per item. Never paste raw URLs. The Desktop chat draws the link as the service's
logo plus your label, and a click opens that exact item.

```
- She wants your ok on the new prices. [Her message](https://example.slack.com/archives/C0123ABCD/p1762560000123456)
```

Getting the permalink:

- Slack: always the https permalink `https://<workspace>.slack.com/archives/<channel_id>/p<ts without the dot>`
  (ts `1762560000.123456` becomes `p1762560000123456`). For a reply in a thread, append
  `?thread_ts=<parent ts>&cid=<channel_id>`. Or call `chat.getPermalink`. This opens the exact message.
  Never a `slack://` link: the Desktop chat can only open it at the channel, not the message.
- Gmail: `https://mail.google.com/mail/u/0/#all/<message id>`, or the thread link the tool returns.
- Anything else: the URL the tool returned. Plain and short; never invent one.

## Other channels

On Slack, Telegram, the CLI, the TUI or any channel that is not card-capable — read the `Platform:` line
against §"Which chat am I in?" — never write a `::card` line: ask your question, or describe the approval
or the task, in plain text. A `::card` marker there is not a card, it is a line of punctuation he has to
read.

**Except when the owner asks for a card on purpose** — "send me a sample draft email card" to test the
renderer. Then write the file and post the `::card` line anyway, say in one sentence where it will draw
(the native app if this surface does not), and do not paste the JSON as a fallback. Keep the card's own
contract intact so the click path is what is being tested: a `draft-email` card with `Send`/`Discard`, an
approval card with two actions, `resolved: null` until you have acted.

**A clicked button arrives as an ordinary message, with the `send` string first.** The owner may append
his own instructions after it (`SEND c-test-mail …` followed by the real recipients). Match on the leading
word and the card id, take the rest of the message as new instruction, do the action, then rewrite the
file with `resolved` and `status.state` `done` and report the outcome in a short line.
