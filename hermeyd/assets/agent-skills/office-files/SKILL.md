---
name: office-files
description: Read the PDF/DOCX/XLSX you were sent, and hand files back.
managed_by: hermey-bridge
version: 1.0.0
author: Hermes
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [files, pdf, docx, xlsx, workspace, attachments]
  hermes-bot-kit:
    skill: office-files
---

# Documents: reading them, and handing them back

The host reads documents so you do not have to. When the owner (or another bot) attaches a PDF, Word
document or spreadsheet to a message, its **text is already in your prompt**, in a labelled block:

```
--- attachment: budget.xlsx (sheet: Q4, 812 rows, 6 columns) ---
Region | Units | Revenue
North | 42 | 12500
…
```

Two things follow from that, and one rule applies to both.

- **Do not try to open the file again** with a shell tool to "check" it. The block is the document; a
  second reader would disagree with the transcript the owner is looking at.
- **Say what was cut.** Bounds are 50 PDF pages, 2 000 Word paragraphs, 12 sheets × 500 rows, 24 000
  characters per document — and a block ends with a line like `[... 5 more rows not shown]` when one
  bit. If the owner needs the rest, ask for the specific part, not the whole file again.
- **A scan has no text.** A PDF block that says *no text layer* is a picture of a document; say so
  rather than inventing its contents.

## Reading a document yourself

If you need a document that is *not* in your prompt — one you just wrote, or one sitting in the
owner's Library — ask the host for its text instead of extracting it by hand:

```bash
curl -s --data-binary @report.docx \
  -H "x-hermey-filename: report.docx" \
  -H "Authorization: Bearer $(cat @@TOKEN_FILE@@)" \
  @@API@@/v1/office/extract
```

The answer carries `block` (paste it into your reasoning), `text`, and `notes` if anything was cut.
Accepted: PDF, DOCX, XLSX, CSV, plain text — up to 8 MiB. A `.doc`/`.xls`/`.pptx` is refused with a
message naming the file; ask the owner to save it as the modern format.

## Sending a document to another bot

Put it in the message you hand over — the host extracts it and the other bot receives the text, the
same way you did. This route takes no credential: it is the host's own loopback command, for a bot on
this machine speaking to another bot's chat.

```bash
python3 - <<'PY'
import base64, json, subprocess
body = {
    "text": "the forecast is attached",
    "from": "cody", "from_profile": "cody",
    "attachments": [{"name": "forecast.xlsx",
                     "data_base64": base64.b64encode(open("forecast.xlsx", "rb").read()).decode()}],
}
subprocess.run(["curl", "-s", "-X", "POST", "@@API@@/v1/bots/ops/message",
                "-H", "content-type: application/json", "-d", json.dumps(body)], check=True)
PY
```

Build the JSON in code, never by hand: a base64 blob pasted into a shell string is a quoting bug
waiting to happen. At most four attachments per message, 8 MiB each; the answer lists what was read
(`attachments: [{name, kind, chars, truncated}]`), and the reply is in `reply` (null when the other
bot is still busy).

`ask` takes no attachments — it is one question and one answer. If you need the other bot to read a
document, send it with `message`.

## Handing a file back to the owner

A file you create lands in **your workspace** — your own working directory:

```
<engine home>/profiles/<your profile>/workspace/
```

Write it there (`workspace/reports/q4.xlsx`, not `/tmp/q4.xlsx`), then announce it in your reply with
a markdown link to the host's download route:

```markdown
Here is the forecast: [Q4-forecast.xlsx](/v1/workspace/ops/file?source=workspace&path=reports/q4-forecast.xlsx)
```

- `source=workspace` for a file you wrote; `source=attachments` for one the owner sent you.
- `path` is relative to that folder, `/`-separated, and **percent-encoded** — a space is `%20`, and a
  `#` or `&` in a filename must be encoded or the link breaks.
- The apps turn that link into a tappable file chip; tapping it downloads from the host with the
  right content type. No upload step, no second copy: the file is already where the route reads.
- A link to anything outside your workspace is refused (`422 invalid path`, `404 no such file`) —
  which is the point: a file you did not write is not yours to hand out.

If the file is one the owner should read *in* the app rather than download, keep it to `md`, `txt`,
`csv` or `pdf`: those preview in the Library. `docx`/`xlsx` download.

## Requirements

The service is at `@@API@@`; the bearer is `$HERMEYD_LOCAL_TOKEN`, or the contents of
`@@TOKEN_FILE@@` when that is unset. If it is unreachable or answers 401, say so plainly — do not
retry in a loop and do not claim a file was delivered.
