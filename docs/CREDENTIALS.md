# Login cards: how a bot logs in without ever seeing your password

The three cards (choice, secret, confirm) are asked, answered, consumed and cancelled by `hermeyd`,
drawn by both apps, and filled either through the sign-in extension's loopback socket or through the
bot screen's DevTools port. The 1Password service-account backend behind the same interface is not
built.

## The problem

A bot asked to "log into my Doctolib account" today has two bad options: be handed the password
(it ends up in a transcript, a log and a model's context), or be given standing access to a vault
(any bot can then read anything). Neither is acceptable, and both are how automation normally does it.

## The idea

The bot **orchestrates** the login. The owner **supplies** the secret. The two are kept apart: the
secret is typed into a card in the Hermey app and flows from the app, through `hermeyd`, into the
page. It never enters the conversation, the bot's context, or a log.

Every secret-bearing interaction is a **card**. There are three kinds.

## Card 1 — choice

Shown when a bot reaches a login page and has to know how the owner wants to sign in.

| field | meaning |
| --- | --- |
| site | the origin being signed into, e.g. `doctolib.de` |
| options | the methods the page actually offers: *Continue with Google*, *Email and password*, *Passkey* |
| note (optional) | one line from the bot: what it is trying to do |

The bot learns **which option was chosen** and nothing else.

## Card 2 — secret

Shown after a choice, or whenever a value must be typed.

| field | meaning |
| --- | --- |
| site | the origin, repeated so a card is never ambiguous |
| fields | one or more masked inputs: `username` + `password`, or a single `one-time code` |
| fills | what the value will be placed into: "the password field on the sign-in form" |
| expires | 15 minutes by default (`ttl_seconds`, clamped to 30 s – 24 h) |
| store | `true` saves the answer in the host's vault instead of filling a page — see below |

Rules:

- Values travel app → `hermeyd` → the fill target. **They are never returned to the bot**, never written
  to the transcript, never logged, and never stored after the fill.
- The app records that a login happened and when. Not what was typed.
- One-time codes are single use and expire with the card.

### `store`: a credential the bot will need again

A login is typed once. An API key is not: it has to live somewhere the bot can use it tomorrow without
the bot ever holding it. That is the same card with `store: true`.

| | fill card (default) | stored card |
| --- | --- | --- |
| where the answer goes | the extension fills it into the page | `hermeyd`'s vault (`<state>/secrets.json`, `0600`) |
| what `consume` returns | `{values}` — once | `{ok: true, stored: [{field, name}]}` — never a value |
| how the bot uses it later | it does not; the card is spent | `fill` with `{"name": "password", "secret": "<name>"}` |
| the app's button | *Fill it in* | *Save to the vault* |

The name is `<site>/<field>` (`doctolib.de/password`, `api.openai.com/api-key`) or whatever the bot
asked for with `save_as`, and it is the only thing that leaves the host. A value larger than 4 KB is
refused with its own code. The vault is never served by a route: the only reader is a fill, whose reply
is the extension's own field names and booleans.

The owner sees the difference, because the sheet says where the value is going: *"Saved to the vault on
this host — the bot gets its name, never the value"* rather than *"Typed straight into the page"*.

## Card 3 — confirm

Shown when a bot wants to use an existing connection instead of a typed secret.

| field | meaning |
| --- | --- |
| site | where the action will happen |
| connection | which saved connection, e.g. "Google — mo@example.com (Composio)" |
| action | one line: "sign in to doctolib.de with this account" |

The bot learns **yes or no**. It never sees the token behind the connection.

## The rules that make it safe

1. **Secrets bypass the model.** A value entered in a secret card must never be delivered to the bot
   as a message. If it arrives in the conversation, the whole design has failed.
2. **A bot cannot read the field after the fill.** Screenshots are acceptable — password inputs render
   as dots — but page script execution during a login is not. Either scripts are refused while a
   secret card is open, or the fill goes through a channel the bot cannot query.
3. **Every card names the site**, and a card is only issued for the page the bot is currently on. This
   is what stops a bot — or something impersonating one — from asking for a secret it has no business
   holding.
4. **Short-lived and single use.** A card expires in 15 minutes by default (`ttl_seconds`, clamped to
   30 s – 24 h), up to 32 can be pending, and each is consumed once.
5. **No secret is ever in a URL, a log line, a screenshot filename or an audit event.** The audit
   records the event, the site and the outcome only.
6. **Cancel is always available and always obeyed.** A cancelled card fills nothing.

## What the bot learns, in full

- the site it is on,
- which sign-in method the owner chose,
- whether the fill succeeded, and the page's own response (wrong password, bad code),
- for a confirm card, yes or no,
- for a stored card, the **name** the value was saved under — and never the value.

That is the complete list. If a future feature needs more, it goes in this document first.

## The vault, and the pane that shows it

A card made with `store: true` writes its answer into the host's vault — `<state>/secrets.json`,
`0600`, a name→value map, atomic write, never served in full by any route. The owner can now see what is
in it from **Settings → Vault** on both the Mac and the phone, and that screen has exactly two verbs:

```
GET    /v1/vault           → {"items": [{name, kind, addedAt, site?, note?}]}
DELETE /v1/vault/{*name}   → {"deleted": "<name>"} | 404 | 422 | 409
```

- **A value has nowhere to travel.** The item type the host serialises (`VaultItem` in
  `hermeyd/src/vault.rs`) has no member a value could occupy, and the module never calls
  `secrets::get`. The app's copy (`VaultItem` in `Sources/HermesKit/VaultItems.swift`) has no such field
  either, so there is no reveal control to build and nothing for one to reveal.
- **Adding has one door.** The pane does not post a value: "Add a secret" asks the host for a
  `store`-mode card (`POST /v1/credentials/cards` with `save_as: <the name>`) and presents the *same*
  masked sheet a bot's card opens. The value goes into that `SecureField`, to the host, and nowhere else.
- **Deleting is the store's own removal.** `secrets::remove` rewrites the map without the name, so the
  value stops existing; the route answers 404 for a name the vault does not have rather than pretending.
- **Labels live beside the store, not in it.** `site`, `note`, `kind` and `addedAt` are kept in the host's
  document store under `vault:index`, keyed by name, written when a stored card is answered. That keeps
  `secrets.json` one format with no migration; an entry with no record (saved before this pane existed) is
  still listed and dated by the file.
- **A broken host is not an empty vault.** An unreachable host, a refused request and an unreadable store
  each produce an error sentence and no list; only a real answer renders the empty state.

## Fill targets

| where the bot works | how the fill lands |
| --- | --- |
| the bot screen's browser | the **Hermey Sign-in extension** (first choice): it holds a loopback socket to `hermeyd` and types the value into the field, replying only "ok" |
| the bot screen's browser, launched by the dock | the DevTools port, as a fallback when no extension is connected |
| the owner's Mac browser | the same extension, installed by hand; later, the Mac app may fill through its own browser surface |
| native app windows | out of scope for this version; a bot must ask the owner to type |

The extension needs no launch flags, so it reaches a browser the owner started themselves — and it is
the same component on the Mac, where launch flags cannot reach at all. It never stores, logs or resends
a value, and its reply is an id and a boolean.

## When it cannot work

| case | behaviour |
| --- | --- |
| the site offers only a passkey | the choice card says so, and the bot asks the owner to complete it on their own device |
| the app is older than this feature | the bot is told plainly to update the app, rather than falling back to asking for a password in chat |
| the owner does not answer | the card expires; the bot reports that it stopped and why |
| wrong password twice | the bot stops and asks, rather than looping |

## Connecting accounts (Composio, and the same pattern later for others)

Connecting happens **in the app**, once: the owner taps Connect, finishes the provider's own sign-in,
and the connection is stored host-side, per owner, not per bot. A bot then only ever gets card 3 to
use it. Revoking is a switch in the app.

The same shape applies to a 1Password service account when the owner has a plan that offers one: the
token is entered in the app, scoped to one vault, held by `hermeyd`, and never by a bot. A bot's only
door is the card.

