# Integrations

Hermey's Integrations screen connects your own Google account to the agent, so a bot can read your mail,
check a calendar or look something up on a map without you copying anything into the chat.

The connection is yours, not ours: it runs through [Composio](https://composio.dev) with **your** project key,
and the tokens live on the machine that runs your bridge. No account, no relay, no service of ours is in the
path.

## How it works

1. You paste your Composio project key into Hermey — once, on the host. It is stored at
   `/etc/hermey/composio.key` with `0600` permissions, not in a unit file, because a key in a systemd unit is
   visible to anyone who can run `systemctl show`.
2. You press **Connect** on a service. Hermey asks Composio for a fresh connection, and you finish the consent
   on Google's own page.
3. The bot gets a *tool*, not a password. It calls the service; it never sees a token.

Nothing is shared between two people: one bridge, one Composio project, your accounts.

## Connecting a service

Open **Settings → Integrations** in the Mac app or the Integrations tab on the phone. Each service is a card;
press **Connect** on the one you want. The browser opens on Google's consent page, you approve it, and the card
turns to **Connected**.

If the card says it is not configured, the project key is missing or wrong — add it on the host and reload.
A service can be connected but show nothing until it is `ACTIVE` on Composio's side; Hermey reports
`INITIALIZING` as not connected rather than pretending.

## More than one account

Connect the same service again and you get a second account. Give each a name you will recognise — Hermey
fills in the address it finds on the account, and you can rename it later:

```
mnoman1942
dna.mailbox
```

That name is what the bot uses when it acts, so make it the one you would say out loud. Two Gmails with no
names are two identical cards, and "send it from Gmail" then has no safe meaning.

Disconnecting is per account, by id — never "disconnect gmail", which would have to guess which one you meant.

## The services

The list comes from the bridge's own catalogue, so this table cannot drift from the code without a check
failing (`Tools/site/check_drift.py`, `catalog`). Adding a service to `CATALOG` in
`Bridge/hermes_bridge/composio.py` adds it to the app and requires a line here.

| Service | Slug | What it is for |
|---|---|---|
| Gmail | `gmail` | Read, search and send mail |
| Google Calendar | `googlecalendar` | See and change your calendar |
| Google Drive | `googledrive` | Find and open files |
| Google Docs | `googledocs` | Read and write documents |
| Google Sheets | `googlesheets` | Read and edit spreadsheets |
| Google Maps | `googlemaps` | Places, directions and distance |
| Supabase | `supabase` | Query your projects and run SQL |
| GitHub | `github` | Repositories, issues and pull requests |
| Notion | `notion` | Read and write your pages |
| Linear | `linear` | Track issues and projects |
| Stripe | `stripe` | Customers, payments and invoices |
| Cloudflare | `cloudflare` | DNS, cache and Workers |
| Vercel | `vercel` | Deployments, domains and projects |

A toolkit Composio does not support on your plan is reported as unavailable instead of pretending to connect.

Most of these are toolkits where **Composio manages the OAuth app**, so Connect opens a consent page and there
is nothing to set up.

### Services you connect with a key

Cloudflare and Vercel have no Composio-managed OAuth app, so their card asks for a key instead of opening a
browser. **Connect with a key** opens a small form with exactly the fields Composio lists for that service —
never a hard-coded guess:

| Service | What it asks for |
|---|---|
| Cloudflare | Global API Key (stored as a secret) **and** the account email |
| Vercel | Access Token (secret), with an optional team id |

The value goes from the app to your bridge and straight on to Composio. It is not stored on the host, not
returned in any response and not written to the audit log — only the resulting account id and status come back.

**Netlify** is the one that still is not offered: Composio has it only as an MCP toolkit (`netlify_mcp`, 9
tools) rather than a classic toolkit, which would need MCP support before a card could mean anything.

## What a bot can do with it

Once a service is connected, the agent uses it the way it uses any other tool: read the newest message from a
sender, list tomorrow's appointments, look up the code a site just emailed you. The `integrations` skill
documents the calls; the bot does not need new credentials and you do not need to paste anything into the chat.

This is also what makes a login card cheaper: with Gmail connected, a bot can fetch a one-time code itself and
hand it straight to the sign-in flow, so you are asked only for your password.

## Where your data lives

- **Tokens** — on the Composio side, under your project key. Hermey stores the key, not the tokens.
- **The key** — `/etc/hermey/composio.key`, `0600`, on the bridge host.
- **Account names** — in the bridge's own state, alongside the connection ids. They are labels, not
  credentials.
- **Mail, calendars, files** — never copied into Hermey. The bot reads them when it acts, through Composio.

## Troubleshooting

- **"could not reach the host"** on the phone — the pairing is stale; re-pair from the Mac app.
- **A card says Connected but the bot gets nothing** — the account is `INITIALIZING`, or the key lacks that
  toolkit on your Composio plan. Check the Composio dashboard.
- **Every service shows Connected after one connect** — that was a real bug: Composio ignores the toolkit
  filter in its connected-accounts list, so one Gmail lit all six. Hermey now filters locally and only counts
  `ACTIVE` accounts.
- **Two accounts, wrong one used** — rename them. The bot acts on the name you gave, so an unnamed pair is
  ambiguous by construction.

## Keeping this current

Integrations will keep growing, so:

- the app's catalogue, this table and the drift check all come from **one** list
  (`CATALOG` in `Bridge/hermes_bridge/composio.py`);
- `Tools/site/check_drift.py catalog` fails when a catalogue entry is missing from this page, or when this page
  names a service the code no longer has;
- the nightly audit runs the drift checks and reports, without publishing — you are the publisher.
