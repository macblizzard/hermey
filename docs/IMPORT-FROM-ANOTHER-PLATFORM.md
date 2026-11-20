# Importing bots from another platform

Hermey's Import reads one shape: `hermey-bots.zip`, containing `backup.json` in this host's own format. A file
from another product is refused rather than half-read, because a guess produces bots that look imported and are
empty.

So the way to bring bots from elsewhere is to have *that* platform's bot write the file for you. **Settings →
Back up your bots → Prompt for another platform** copies the exact prompt; the host serves it, so it always
describes the schema this host accepts.

## How to use it

1. Open Hermey → Settings → Back up your bots → **Prompt for another platform…**
2. Paste the prompt into the other platform's main bot and let it work.
3. It returns a `hermey-bots.zip`. Import it in Hermey, read the preview, choose how to treat bots that already
   exist here.

If the other platform cannot write a zip, `backup.json` alone is accepted too.

## What the prompt asks for

- `kind` must be `hermey-bot-backup`, and `version` must match this host — the app copies the version, you do not
  have to know it.
- One object per bot: `profile` (its identity, `[a-z0-9][a-z0-9_-]{0,63}`), `name`, `description`, `soul`,
  `memory.memory`, `memory.user`, `notes`, `categories`, `enabled`, optional `icon`, and `routines`.
- Routines keep their `id` so importing twice does not double a schedule.
- Categories are matched **by name**, because an id from another machine means nothing here.
- No conversations, no transcripts, no keys or passwords: they are not in this format, and a file carrying them
  is not imported.

## What cannot come across

Whatever the other platform has no equivalent for — model settings, proprietary memory structures, tool
definitions. The prompt asks that bot to tell you what it dropped rather than inventing a substitution.
