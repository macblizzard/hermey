//! Office documents — PDF, DOCX, XLSX, and plain CSV/TXT — read at the host, once.
//!
//! Why here and not in the apps or the engine: a transcript is shared. The phone, the Mac and every
//! bot look at the same conversation, so if each of them decided what a `.xlsx` says they would
//! disagree, and a bot with no PDF library would see a filename where the rest saw a contract. The
//! host owns the difference, so it converts once and everybody gets the same block of text.
//!
//! What this module is *not*: an OCR engine, a spreadsheet calculator, or a Word renderer. It reads
//! what the file declares about itself and bounds it hard:
//!
//! | kind | how it is read | bounds |
//! |---|---|---|
//! | PDF | text layer, page by page (`lopdf`) — no OCR | first 50 pages, 24 000 chars |
//! | DOCX | `word/document.xml`: paragraphs in order, headings marked, tables flattened row by row | 2 000 paragraphs, 2 000 table rows |
//! | XLSX | each sheet's used range, rows as pipe-separated cells | 12 sheets, 500 rows and 40 columns per sheet |
//! | CSV/TXT | UTF-8, quote-aware for CSV | 1 000 rows, 2 MiB read |
//!
//! Every bound that bites is written into the text where a reader (or a model) will meet it, so a
//! truncated document says so rather than quietly pretending to be whole.
//!
//! Trust is decided by **content**, never by the name alone: a `.docx` must really be a zip holding
//! `word/document.xml`, an `.xlsx` one holding `xl/workbook.xml`, a PDF must start `%PDF-`. A file
//! whose name and bytes disagree is refused with a message naming both.

use crate::attachments::{decode_base64, MAX_ATTACHMENT_BYTES};
use crate::routes::{require_device, AppState};
use axum::body::Bytes;
use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use quick_xml::events::Event;
use quick_xml::Reader;
use serde_json::{json, Value};
use std::io::{Cursor, Read};
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;

// ---- bounds ----------------------------------------------------------------------------------

/// Per attachment, the most text that reaches a prompt.
pub const MAX_EXTRACT_CHARS: usize = 24_000;
/// Across one message's attachments. Two full blocks' worth, then the rest are cut short.
pub const MAX_MESSAGE_ATTACHMENT_CHARS: usize = 48_000;
/// A message carries a few documents, not a mailbox.
pub const MAX_ATTACHMENTS_PER_MESSAGE: usize = 4;

const MAX_PDF_PAGES: usize = 50;
const MAX_DOCX_PARAGRAPHS: usize = 2_000;
const MAX_DOCX_TABLE_ROWS: usize = 2_000;
const MAX_XLSX_SHEETS: usize = 12;
const MAX_XLSX_ROWS: usize = 500;
const MAX_XLSX_COLS: usize = 40;
const MAX_TEXT_ROWS: usize = 1_000;
const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;

/// The body ceiling for `POST /v1/office/extract`, and the per-attachment ceiling on a message.
/// The same 8 MiB the relay already allows through `file.attach`: a document is a chat attachment,
/// not a file store. An 8 MiB spreadsheet is a quarter of a million rows — far past the row bound
/// below — so nothing real is turned away by it.
pub const MAX_OFFICE_BYTES: usize = MAX_ATTACHMENT_BYTES;

// ---- kinds -----------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Pdf,
    Docx,
    Xlsx,
    Csv,
    Text,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Pdf => "pdf",
            Kind::Docx => "docx",
            Kind::Xlsx => "xlsx",
            Kind::Csv => "csv",
            Kind::Text => "text",
        }
    }

    pub fn mime(self) -> &'static str {
        match self {
            Kind::Pdf => "application/pdf",
            Kind::Docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            Kind::Xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            Kind::Csv => "text/csv; charset=utf-8",
            Kind::Text => "text/plain; charset=utf-8",
        }
    }

    /// How the kind is named in a refusal, so the message says what was expected.
    fn describe(self) -> &'static str {
        match self {
            Kind::Pdf => "a PDF",
            Kind::Docx => "a Word document (.docx)",
            Kind::Xlsx => "an Excel workbook (.xlsx)",
            Kind::Csv => "a CSV file",
            Kind::Text => "a text file",
        }
    }

    fn from_extension(extension: Option<&str>) -> Option<Kind> {
        match extension? {
            "pdf" => Some(Kind::Pdf),
            "docx" => Some(Kind::Docx),
            "xlsx" => Some(Kind::Xlsx),
            "csv" => Some(Kind::Csv),
            "txt" | "md" | "log" | "text" => Some(Kind::Text),
            _ => None,
        }
    }

    fn is_text(self) -> bool {
        matches!(self, Kind::Csv | Kind::Text)
    }
}

impl std::fmt::Display for Kind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

// ---- refusals --------------------------------------------------------------------------------

/// A refusal that names the file and what was wrong with it. The `detail` string is what both apps
/// show and what a bot's caller reads, so it is written for a person: `budget.xlsx` and *why*.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OfficeError {
    detail: String,
}

impl OfficeError {
    fn new(detail: String) -> Self {
        Self { detail }
    }

    pub fn detail(&self) -> &str {
        &self.detail
    }

    /// The name says one thing and the bytes say another — the only refusal that needs both facts.
    fn mismatch(name: &str, named: Kind, found: &str) -> Self {
        Self::new(format!(
            "{name} is named as {} but its contents are {found}",
            named.describe()
        ))
    }

    fn unsupported(name: &str) -> Self {
        Self::new(format!(
            "{name} is not a document this host can read: PDF, DOCX, XLSX, CSV or plain text only"
        ))
    }
}

impl std::fmt::Display for OfficeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.detail)
    }
}

impl std::error::Error for OfficeError {}

// ---- one extraction --------------------------------------------------------------------------

/// One labelled block: `--- attachment: budget.xlsx (sheet: Q4) ---` and the text under it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Section {
    /// What goes in the parentheses after the file name.
    pub label: String,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Extraction {
    pub name: String,
    pub kind: Kind,
    /// Bounds that bit, in words — empty when the whole document was read.
    pub notes: Vec<String>,
    pub sections: Vec<Section>,
}

impl Extraction {
    pub fn truncated(&self) -> bool {
        !self.notes.is_empty()
    }

    /// Characters of body text across every section: what the caller's budget is spent on.
    pub fn chars(&self) -> usize {
        self.sections.iter().map(|s| s.body.chars().count()).sum()
    }

    /// The block a prompt carries. Each section is labelled with the file's name and what part of it
    /// this is, so the model can tell a table from the paragraph that introduces it, and two files
    /// in one message never run together.
    pub fn block(&self) -> String {
        let mut out = String::new();
        for section in &self.sections {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(&format!(
                "--- attachment: {} ({}) ---\n",
                self.name, section.label
            ));
            out.push_str(section.body.trim_end());
            out.push('\n');
        }
        if self.sections.is_empty() {
            out.push_str(&format!("--- attachment: {} ({}) ---\n", self.name, self.kind));
            out.push_str("(no extractable text)\n");
        }
        out
    }

    /// What a caller gets back: the block (ready to paste into a prompt), the body, and why it is
    /// shorter than the file if it is.
    pub fn to_value(&self) -> Value {
        json!({
            "name": self.name,
            "kind": self.kind.as_str(),
            "mime": self.kind.mime(),
            "chars": self.chars(),
            "truncated": self.truncated(),
            "notes": self.notes,
            "block": self.block(),
            "text": self.sections.iter().map(|s| s.body.clone()).collect::<Vec<_>>().join("\n"),
        })
    }

    /// The one-line summary a message response carries: enough for an app to draw a chip, never the
    /// whole text again.
    pub fn summary(&self) -> Value {
        json!({
            "name": self.name,
            "kind": self.kind.as_str(),
            "chars": self.chars(),
            "truncated": self.truncated(),
        })
    }
}

fn extension(name: &str) -> Option<String> {
    name.rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
        .filter(|ext| !ext.is_empty() && ext.len() <= 12)
}

fn starts_with_pdf(bytes: &[u8]) -> bool {
    // The header must be at the start, but a few readers prepend junk; allow leading whitespace and
    // a UTF-8 BOM and nothing else, which is what a PDF viewer tolerates too.
    let trimmed = bytes
        .strip_prefix(&[0xEF, 0xBB, 0xBF][..])
        .unwrap_or(bytes);
    let start = trimmed
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .unwrap_or(trimmed.len());
    trimmed[start..].starts_with(b"%PDF-")
}

fn looks_like_text(bytes: &[u8]) -> bool {
    // UTF-8 decodable and no NUL in the first 8 KiB. A binary that happens to start with ASCII
    // stops being "text" the moment a NUL shows up, which every one of them has early.
    let head = &bytes[..bytes.len().min(8 * 1024)];
    !head.contains(&0) && std::str::from_utf8(head).is_ok()
}

/// Which Office container this zip is, or `None` for a zip that is neither (a `.zip`, an `.epub`, a
/// packaged app). The marker parts are fixed by the formats themselves, not by a convention of ours.
fn zip_kind(bytes: &[u8]) -> Result<Option<Kind>, OfficeError> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|_| OfficeError::new("this archive could not be opened as a zip".to_string()))?;
    if archive.by_name("word/document.xml").is_ok() {
        return Ok(Some(Kind::Docx));
    }
    if archive.by_name("xl/workbook.xml").is_ok() {
        return Ok(Some(Kind::Xlsx));
    }
    Ok(None)
}

/// Decide what a file is from its bytes, and check that its name does not claim to be something
/// else. Content wins over extension everywhere except in the refusal.
pub fn sniff(name: &str, bytes: &[u8]) -> Result<Kind, OfficeError> {
    if bytes.is_empty() {
        return Err(OfficeError::new(format!("{name} is empty")));
    }
    let named = Kind::from_extension(extension(name).as_deref());

    if starts_with_pdf(bytes) {
        return match named {
            Some(kind) if kind != Kind::Pdf => Err(OfficeError::mismatch(name, kind, "a PDF")),
            _ => Ok(Kind::Pdf),
        };
    }

    if bytes.starts_with(b"PK\x03\x04") {
        return match zip_kind(bytes)? {
            Some(kind) => match named {
                Some(named) if named != kind => {
                    Err(OfficeError::mismatch(name, named, kind.describe()))
                }
                _ => Ok(kind),
            },
            None => Err(OfficeError::new(format!(
                "{name} is a zip archive, but not a Word document or an Excel workbook"
            ))),
        };
    }

    if looks_like_text(bytes) {
        return match named {
            Some(kind) if kind.is_text() => Ok(kind),
            Some(kind) => Err(OfficeError::mismatch(name, kind, "plain text")),
            None => Err(OfficeError::unsupported(name)),
        };
    }

    Err(match named {
        Some(kind) => Err(OfficeError::mismatch(name, kind, "binary data")),
        None => Err(OfficeError::unsupported(name)),
    }?)
}

// ---- extraction ------------------------------------------------------------------------------

/// Read one document at the full per-document budget. The service routes all pass an explicit
/// budget (a message shares one across its attachments), so only the tests read at this default —
/// which is why it carries an allow.
#[allow(dead_code)]
pub fn extract(name: &str, bytes: &[u8]) -> Result<Extraction, OfficeError> {
    extract_with_budget(name, bytes, MAX_EXTRACT_CHARS)
}

pub fn extract_with_budget(
    name: &str,
    bytes: &[u8],
    budget: usize,
) -> Result<Extraction, OfficeError> {
    let kind = sniff(name, bytes)?;
    if bytes.len() > MAX_OFFICE_BYTES {
        return Err(OfficeError::new(format!(
            "{name} is larger than the {} MiB a document attachment may be",
            MAX_OFFICE_BYTES / (1024 * 1024)
        )));
    }
    let mut notes = Vec::new();
    let sections = match kind {
        Kind::Pdf => extract_pdf(bytes, budget, &mut notes)?,
        Kind::Docx => extract_docx(bytes, budget, &mut notes)?,
        Kind::Xlsx => extract_xlsx(bytes, budget, &mut notes)?,
        Kind::Csv | Kind::Text => extract_text(kind, bytes, budget, &mut notes)?,
    };
    let extraction = Extraction {
        name: name.to_string(),
        kind,
        notes,
        sections,
    };
    // A short answer must never look like a whole document: every reader that cut something says
    // so in its text, and the host's own log says it too, so a truncated block is traceable even
    // where the block itself is gone (a discarded reply, a trimmed log line).
    if extraction.truncated() {
        eprintln!(
            "office: {} was truncated: {}",
            extraction.name,
            extraction.notes.join("; ")
        );
    }
    Ok(extraction)
}

/// Line hygiene shared by every reader: no CRs, no control characters a prompt cannot carry, no
/// runs of blank lines, no trailing spaces.
fn tidy(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut blank_run = 0usize;
    for raw in text.replace("\r\n", "\n").replace('\r', "\n").split('\n') {
        let line: String = raw
            .chars()
            .filter(|c| !c.is_control() || *c == '\t')
            .collect::<String>()
            .trim_end()
            .to_string();
        if line.trim().is_empty() {
            blank_run += 1;
            if blank_run > 1 {
                continue;
            }
            out.push('\n');
        } else {
            blank_run = 0;
            out.push_str(&line);
            out.push('\n');
        }
    }
    out.trim().to_string()
}

/// Cut `text` to `budget` characters on a character boundary and say so where the cut happened.
fn cut(text: &str, budget: usize, notes: &mut Vec<String>, what: &str) -> String {
    if text.chars().count() <= budget {
        return text.to_string();
    }
    let kept: String = text.chars().take(budget).collect();
    notes.push(format!("stopped after {budget} characters ({what})"));
    format!("{kept}\n[... truncated at {budget} characters]")
}

fn remaining(budget: usize, spent: usize) -> usize {
    budget.saturating_sub(spent)
}

// ---- PDF -------------------------------------------------------------------------------------

fn extract_pdf(
    bytes: &[u8],
    budget: usize,
    notes: &mut Vec<String>,
) -> Result<Vec<Section>, OfficeError> {
    let doc = lopdf::Document::load_mem(bytes)
        .map_err(|_| OfficeError::new("this PDF could not be opened (it may be damaged or encrypted)".to_string()))?;
    let total = doc.get_pages().len();
    if total == 0 {
        return Ok(vec![Section {
            label: "pdf, no pages".to_string(),
            body: "(this PDF has no pages)".to_string(),
        }]);
    }
    let pages = total.min(MAX_PDF_PAGES);
    let mut body = String::new();
    let mut empty_pages = 0usize;
    for page in 1..=pages as u32 {
        if body.chars().count() >= budget {
            notes.push(format!("stopped at page {page} of {total}"));
            break;
        }
        // One page at a time: a chunk error on page 7 must not cost pages 1-6.
        let text = doc
            .extract_text_chunks(&[page])
            .into_iter()
            .filter_map(|chunk| chunk.ok())
            .collect::<Vec<_>>()
            .join("\n");
        let page_text = tidy(&text);
        if page_text.is_empty() {
            empty_pages += 1;
            continue;
        }
        if !body.is_empty() {
            body.push('\n');
        }
        body.push_str(&format!("[page {page}]\n{page_text}"));
    }

    if total > pages {
        notes.push(format!(
            "pages {}-{total} not extracted (limit {MAX_PDF_PAGES} pages)",
            pages + 1
        ));
    }
    if body.is_empty() {
        notes.push("no text layer: a scanned PDF would need OCR, which this host does not do".to_string());
        body = "(no extractable text — this looks like a scan, not a document with a text layer)".to_string();
    } else if empty_pages > 0 {
        notes.push(format!("{empty_pages} page(s) carried no text"));
    }

    let body = cut(&body, budget, notes, "PDF text");
    let label = if total > pages {
        format!("pdf, pages 1-{pages} of {total}")
    } else if total == 1 {
        "pdf, 1 page".to_string()
    } else {
        format!("pdf, {total} pages")
    };
    Ok(vec![Section { label, body }])
}

// ---- DOCX ------------------------------------------------------------------------------------

/// The attributes an element carries, with any namespace prefix stripped: `w:val` and `val` are the
/// same attribute to us, and a document written by any tool must read the same.
fn attributes(event: &quick_xml::events::BytesStart<'_>) -> Vec<(String, String)> {
    event
        .attributes()
        .flatten()
        .filter_map(|attribute| {
            let key = tag(attribute.key.as_ref()).to_string();
            // `normalized_value` is quick-xml's replacement for the deprecated `unescape_value`:
            // entities resolved, and the XML spec's attribute normalization applied (`\t\r\n`
            // become spaces), which is what a conforming reader does to an attribute anyway.
            let value = attribute
                .normalized_value(quick_xml::XmlVersion::Implicit1_0)
                .map(|v| v.to_string())
                .unwrap_or_default();
            Some((key, value))
        })
        .collect()
}

/// `w:p` and `p` are the same element to us: the namespace prefix is a tool's habit, not content.
fn tag(qualified: &str) -> &str {
    qualified.rsplit(':').next().unwrap_or(qualified)
}

/// quick-xml 0.42 hands `&amp;` and `&#10;` back as their own event (`Event::GeneralRef`) rather
/// than folding them into the text. An entity this does not know is left as written, so a stray
/// one shows up in the prompt instead of vanishing.
fn resolve_reference(reference: &str) -> String {
    match reference {
        "amp" => return "&".to_string(),
        "lt" => return "<".to_string(),
        "gt" => return ">".to_string(),
        "quot" => return "\"".to_string(),
        "apos" => return "'".to_string(),
        _ => {}
    }
    let Some(number) = reference.strip_prefix('#') else {
        return format!("&{reference};");
    };
    let code = match number.strip_prefix(['x', 'X']) {
        Some(hex) => u32::from_str_radix(hex, 16).ok(),
        None => number.parse::<u32>().ok(),
    };
    match code.and_then(char::from_u32) {
        Some(character) => character.to_string(),
        None => format!("&{reference};"),
    }
}

/// A Word paragraph's heading level, from `<w:pStyle w:val="Heading3"/>`.
fn heading_level(style: &str) -> Option<usize> {
    let lower = style.to_ascii_lowercase();
    for prefix in ["heading", "titre", "berschrift", "kop"] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            if let Ok(level) = rest.trim().parse::<usize>() {
                if (1..=6).contains(&level) {
                    return Some(level);
                }
            }
        }
    }
    None
}

fn extract_docx(
    bytes: &[u8],
    budget: usize,
    notes: &mut Vec<String>,
) -> Result<Vec<Section>, OfficeError> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|_| OfficeError::new("this DOCX could not be opened as a zip archive".to_string()))?;
    let mut xml = String::new();
    archive
        .by_name("word/document.xml")
        .map_err(|_| OfficeError::new("this DOCX has no word/document.xml".to_string()))?
        .read_to_string(&mut xml)
        .map_err(|_| OfficeError::new("this DOCX's document part is not readable text".to_string()))?;

    let mut reader = Reader::from_str(&xml);
    reader.config_mut().trim_text(false);

    let mut body = String::new();
    let mut paragraphs = 0usize;
    let mut table_rows = 0usize;
    let mut tables = 0usize;
    let mut stopped = false;

    let mut paragraph = String::new();
    let mut in_text = false;
    let mut heading: Option<usize> = None;
    let mut table_depth = 0usize;
    let mut cell_depth = 0usize;
    let mut row: Vec<String> = Vec::new();
    let mut cell = String::new();
    let mut budget_spent = 0usize;

    loop {
        let event = reader
            .read_event()
            .map_err(|_| OfficeError::new("this DOCX's document part is not valid XML".to_string()))?;
        match event {
            Event::Start(element) => {
                let name = tag(element.name().into_inner()).to_string();
                match name.as_str() {
                    "p" => {
                        paragraph.clear();
                        heading = None;
                    }
                    "pStyle" => {
                        if let Some((_, value)) = attributes(&element).into_iter().find(|(k, _)| k == "val") {
                            heading = heading_level(&value);
                        }
                    }
                    "tbl" => {
                        table_depth += 1;
                        if table_depth == 1 {
                            tables += 1;
                        }
                    }
                    "tr" if table_depth == 1 => row.clear(),
                    "tc" if table_depth == 1 => {
                        cell_depth += 1;
                        cell.clear();
                    }
                    "t" => in_text = true,
                    "tab" => {
                        let target = if cell_depth > 0 { &mut cell } else { &mut paragraph };
                        target.push(' ');
                    }
                    "br" => {
                        let target = if cell_depth > 0 { &mut cell } else { &mut paragraph };
                        target.push('\n');
                    }
                    _ => {}
                }
            }
            Event::Empty(element) => {
                let name = tag(element.name().into_inner()).to_string();
                match name.as_str() {
                    "br" => {
                        let target = if cell_depth > 0 { &mut cell } else { &mut paragraph };
                        target.push('\n');
                    }
                    "tab" => {
                        let target = if cell_depth > 0 { &mut cell } else { &mut paragraph };
                        target.push(' ');
                    }
                    "pStyle" => {
                        if let Some((_, value)) = attributes(&element).into_iter().find(|(k, _)| k == "val") {
                            heading = heading_level(&value);
                        }
                    }
                    _ => {}
                }
            }
            Event::Text(text) => {
                if in_text {
                    let target = if cell_depth > 0 { &mut cell } else { &mut paragraph };
                    target.push_str(&text.into_inner());
                }
            }
            Event::GeneralRef(reference) => {
                if in_text {
                    let value = resolve_reference(&reference.into_inner());
                    let target = if cell_depth > 0 { &mut cell } else { &mut paragraph };
                    target.push_str(&value);
                }
            }
            Event::CData(data) => {
                if in_text {
                    let target = if cell_depth > 0 { &mut cell } else { &mut paragraph };
                    target.push_str(&data.into_inner());
                }
            }
            Event::End(element) => {
                let name = tag(element.name().into_inner()).to_string();
                match name.as_str() {
                    "t" => in_text = false,
                    "p" => {
                        if cell_depth > 0 {
                            if !cell.is_empty() && !cell.ends_with(' ') {
                                cell.push(' ');
                            }
                            cell.push_str(paragraph.trim());
                        } else if !stopped {
                            let line = tidy(&paragraph);
                            if !line.is_empty() {
                                if paragraphs >= MAX_DOCX_PARAGRAPHS
                                    || budget_spent + line.chars().count() > budget
                                {
                                    stopped = true;
                                    notes.push(format!(
                                        "stopped after {paragraphs} paragraphs (limit {MAX_DOCX_PARAGRAPHS}, {budget} characters)"
                                    ));
                                } else {
                                    paragraphs += 1;
                                    budget_spent += line.chars().count() + 1;
                                    match heading {
                                        Some(level) => {
                                            body.push_str(&format!("{} {line}\n\n", "#".repeat(level)))
                                        }
                                        None => body.push_str(&format!("{line}\n\n")),
                                    }
                                }
                            }
                        }
                        paragraph.clear();
                        heading = None;
                    }
                    "tc" if table_depth == 1 => {
                        cell_depth = cell_depth.saturating_sub(1);
                        row.push(tidy(&cell).replace('\n', " "));
                        cell.clear();
                    }
                    "tr" if table_depth == 1 => {
                        if !stopped {
                            if table_rows >= MAX_DOCX_TABLE_ROWS {
                                stopped = true;
                                notes.push(format!(
                                    "stopped after {table_rows} table rows (limit {MAX_DOCX_TABLE_ROWS})"
                                ));
                            } else {
                                table_rows += 1;
                                budget_spent += row.iter().map(|c| c.chars().count() + 3).sum::<usize>();
                                body.push_str(&format!("| {} |\n", row.join(" | ")));
                            }
                        }
                        row.clear();
                    }
                    "tbl" => {
                        if table_depth == 1 {
                            body.push('\n');
                        }
                        table_depth = table_depth.saturating_sub(1);
                    }
                    _ => {}
                }
            }
            Event::Eof => break,
            _ => {}
        }
        if stopped && table_depth == 0 && paragraphs >= MAX_DOCX_PARAGRAPHS.saturating_sub(1) {
            break;
        }
    }

    let body = cut(&tidy(&body), budget, notes, "DOCX text");
    if body.trim().is_empty() {
        notes.push("no text in the document body".to_string());
    }
    let mut label = format!("docx, {paragraphs} paragraph{}", if paragraphs == 1 { "" } else { "s" });
    if tables > 0 {
        label.push_str(&format!(
            ", {tables} table{}, {table_rows} row{}",
            if tables == 1 { "" } else { "s" },
            if table_rows == 1 { "" } else { "s" }
        ));
    }
    Ok(vec![Section {
        label,
        body: if body.trim().is_empty() {
            "(no extractable text)".to_string()
        } else {
            body
        },
    }])
}

// ---- XLSX ------------------------------------------------------------------------------------

/// A cell as the sheet wrote it, before rendering.
#[derive(Clone, Debug, PartialEq)]
enum Cell {
    Empty,
    Text(String),
    Number(f64),
    /// A serial date, already decided by the cell's number format.
    Date(f64, bool), // second flag: the format carries a time part
    Bool(bool),
    Error(String),
}

impl Cell {
    fn render(&self) -> String {
        match self {
            Cell::Empty => String::new(),
            Cell::Text(text) => text.replace(['\n', '\t', '\r'], " ").replace('|', "/"),
            Cell::Number(value) => format_number(*value),
            Cell::Date(serial, with_time) => excel_datetime(*serial, *with_time),
            Cell::Bool(value) => if *value { "TRUE" } else { "FALSE" }.to_string(),
            Cell::Error(code) => code.clone(),
        }
    }
}

/// `1.0` is `1`, not `1.0000000000001`: f64's own shortest round-trip formatter is exactly what a
/// spreadsheet means by a number, and there is no locale in it.
fn format_number(value: f64) -> String {
    if !value.is_finite() {
        return String::new();
    }
    if value == value.trunc() && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        format!("{value}")
    }
}

/// Excel counts days from 1899-12-30 (1900's leap-year bug included, which is what every file in
/// the world has). The epoch shift is 25 569 days to 1970-01-01.
fn excel_datetime(serial: f64, with_time: bool) -> String {
    if !serial.is_finite() || serial < 0.0 {
        return String::new();
    }
    let days = serial.trunc() as i64 - 25_569;
    let (year, month, day) = civil_from_days(days);
    let mut out = format!("{year:04}-{month:02}-{day:02}");
    if with_time || serial.fract() > 0.0 {
        let seconds = (serial.fract() * 86_400.0).round() as u64 % 86_400;
        let (hour, minute, second) = (seconds / 3_600, (seconds % 3_600) / 60, seconds % 60);
        out.push_str(&format!(" {hour:02}:{minute:02}"));
        if second > 0 {
            out.push_str(&format!(":{second:02}"));
        }
    }
    out
}

/// Howard Hinnant's civil-from-days: `i64` day count since 1970-01-01 → (year, month, day).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

/// `A1`/`BC12` → 0-based column index. The row number in the reference is not trusted: `<row r>` is
/// what orders a sheet.
fn column_index(reference: &str) -> Option<usize> {
    let letters: Vec<u8> = reference
        .bytes()
        .take_while(|b| b.is_ascii_alphabetic())
        .map(|b| b.to_ascii_uppercase())
        .collect();
    if letters.is_empty() {
        return None;
    }
    let mut index = 0usize;
    for letter in letters {
        index = index * 26 + (letter - b'A' + 1) as usize;
    }
    Some(index - 1)
}

/// The built-in number formats Excel reserves for dates and times (ECMA-376, 18.8.30).
fn builtin_is_date(format_id: u32) -> bool {
    matches!(format_id, 14..=22 | 27..=36 | 45..=47 | 50..=58)
}

/// A custom format code is a date when it carries a date/time field outside quotes and brackets.
fn format_code_is_date(code: &str) -> bool {
    let mut in_quote = false;
    let mut in_bracket = 0usize;
    for ch in code.chars() {
        match ch {
            '"' => in_quote = !in_quote,
            '[' if !in_quote => in_bracket += 1,
            ']' if !in_quote => in_bracket = in_bracket.saturating_sub(1),
            _ if !in_quote && in_bracket == 0 => {
                if matches!(ch.to_ascii_lowercase(), 'y' | 'd' | 'h' | 's') {
                    return true;
                }
            }
            _ => {}
        }
    }
    false
}

fn zip_text(archive: &mut zip::ZipArchive<Cursor<&[u8]>>, name: &str) -> Option<String> {
    let mut file = archive.by_name(name).ok()?;
    let mut text = String::new();
    file.read_to_string(&mut text).ok()?;
    Some(text)
}

/// The `<sheet>` elements of `xl/workbook.xml`, in workbook order, with the relationship id that
/// points at each sheet's part.
fn workbook_sheets(xml: &str) -> Vec<(String, String)> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut sheets = Vec::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) | Ok(Event::Empty(element)) => {
                let name = tag(element.name().into_inner()).to_string();
                if name == "sheet" {
                    let attributes = attributes(&element);
                    let get = |wanted: &str| {
                        attributes
                            .iter()
                            .find(|(key, _)| key == wanted)
                            .map(|(_, value)| value.clone())
                    };
                    if let (Some(sheet_name), Some(relationship)) = (get("name"), get("id")) {
                        sheets.push((sheet_name, relationship));
                    }
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    sheets
}

/// `rId3` → `worksheets/sheet3.xml`, from `xl/_rels/workbook.xml.rels`.
fn workbook_relationships(xml: &str) -> Vec<(String, String)> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut relations = Vec::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) | Ok(Event::Empty(element)) => {
                let name = tag(element.name().into_inner()).to_string();
                if name == "Relationship" {
                    let attributes = attributes(&element);
                    let get = |wanted: &str| {
                        attributes
                            .iter()
                            .find(|(key, _)| key == wanted)
                            .map(|(_, value)| value.clone())
                    };
                    if let (Some(id), Some(target)) = (get("Id"), get("Target")) {
                        relations.push((id, target));
                    }
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    relations
}

/// Shared strings in index order; `<rPh>` (phonetic guides for furigana) is skipped, because it is
/// pronunciation, not content.
fn shared_strings(xml: &str) -> Vec<String> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    let mut strings = Vec::new();
    let mut current = String::new();
    let mut in_item = false;
    let mut in_text = false;
    let mut skip_depth = 0usize;
    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                let name = tag(element.name().into_inner()).to_string();
                match name.as_str() {
                    "si" => {
                        in_item = true;
                        current.clear();
                    }
                    "rPh" => skip_depth += 1,
                    "t" if skip_depth == 0 => in_text = true,
                    _ => {}
                }
            }
            Ok(Event::Text(text)) => {
                if in_item && in_text && skip_depth == 0 {
                    current.push_str(&text.into_inner());
                }
            }
            Ok(Event::GeneralRef(reference)) => {
                if in_item && in_text && skip_depth == 0 {
                    let value = resolve_reference(&reference.into_inner());
                    current.push_str(&value);
                }
            }
            Ok(Event::End(element)) => {
                let name = tag(element.name().into_inner()).to_string();
                match name.as_str() {
                    "t" => in_text = false,
                    "rPh" => skip_depth = skip_depth.saturating_sub(1),
                    "si" => {
                        in_item = false;
                        strings.push(current.clone());
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    strings
}

/// Which cell styles mean a date, from `xl/styles.xml`: the `numFmtId` of each `cellXfs` entry, and
/// the custom formats it refers to.
fn date_styles(xml: &str) -> Vec<bool> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut custom: Vec<(u32, bool)> = Vec::new();
    let mut styles: Vec<u32> = Vec::new();
    let mut in_cell_xfs = false;
    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) | Ok(Event::Empty(element)) => {
                let name = tag(element.name().into_inner()).to_string();
                let attributes = attributes(&element);
                let get = |wanted: &str| {
                    attributes
                        .iter()
                        .find(|(key, _)| key == wanted)
                        .map(|(_, value)| value.clone())
                };
                match name.as_str() {
                    "cellXfs" => in_cell_xfs = true,
                    "numFmt" => {
                        if let (Some(id), Some(code)) = (get("numFmtId"), get("formatCode")) {
                            if let Ok(id) = id.parse::<u32>() {
                                custom.push((id, format_code_is_date(&code)));
                            }
                        }
                    }
                    "xf" if in_cell_xfs => {
                        let id = get("numFmtId").and_then(|v| v.parse::<u32>().ok()).unwrap_or(0);
                        styles.push(id);
                    }
                    _ => {}
                }
            }
            Ok(Event::End(element)) => {
                if tag(element.name().into_inner()) == "cellXfs" {
                    in_cell_xfs = false;
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    styles
        .into_iter()
        .map(|id| {
            builtin_is_date(id)
                || custom
                    .iter()
                    .find(|(custom_id, _)| *custom_id == id)
                    .map(|(_, is_date)| *is_date)
                    .unwrap_or(false)
        })
        .collect()
}

/// One worksheet: every cell that carries a value, keyed by (row, column).
fn sheet_cells(xml: &str, shared: &[String], date_styles: &[bool]) -> Vec<(u32, usize, Cell)> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    let mut cells = Vec::new();
    let mut row_number: u32 = 0;
    let mut next_row: u32 = 0;
    let mut in_cell = false;
    let mut cell_type = String::new();
    let mut cell_style: usize = 0;
    let mut cell_column: Option<usize> = None;
    let mut in_value = false;
    let mut in_inline = false;
    let mut value = String::new();

    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                let name = tag(element.name().into_inner()).to_string();
                let attributes = attributes(&element);
                match name.as_str() {
                    "row" => {
                        next_row += 1;
                        row_number = attributes
                            .iter()
                            .find(|(key, _)| key == "r")
                            .and_then(|(_, value)| value.parse::<u32>().ok())
                            .unwrap_or(next_row);
                        next_row = row_number;
                    }
                    "c" => {
                        in_cell = true;
                        value.clear();
                        cell_type.clear();
                        cell_style = 0;
                        cell_column = None;
                        for (key, attribute) in &attributes {
                            match key.as_str() {
                                "r" => cell_column = column_index(attribute),
                                "t" => cell_type = attribute.clone(),
                                "s" => cell_style = attribute.parse::<usize>().unwrap_or(0),
                                _ => {}
                            }
                        }
                    }
                    "v" => in_value = true,
                    "is" => in_inline = true,
                    "t" if in_inline => in_value = true,
                    _ => {}
                }
            }
            Ok(Event::Text(text)) => {
                if in_value && in_cell {
                    value.push_str(&text.into_inner());
                }
            }
            Ok(Event::GeneralRef(reference)) => {
                if in_value && in_cell {
                    let resolved = resolve_reference(&reference.into_inner());
                    value.push_str(&resolved);
                }
            }
            Ok(Event::End(element)) => {
                let name = tag(element.name().into_inner()).to_string();
                match name.as_str() {
                    "v" => in_value = false,
                    "t" if in_inline => in_value = false,
                    "is" => in_inline = false,
                    "c" => {
                        in_cell = false;
                        let Some(column) = cell_column else { continue };
                        let parsed = match cell_type.as_str() {
                            "s" => {
                                let index = value.trim().parse::<usize>().unwrap_or(usize::MAX);
                                match shared.get(index) {
                                    Some(text) if !text.is_empty() => Cell::Text(text.clone()),
                                    _ => Cell::Empty,
                                }
                            }
                            "inlineStr" | "str" => {
                                if value.is_empty() {
                                    Cell::Empty
                                } else {
                                    Cell::Text(value.clone())
                                }
                            }
                            "b" => Cell::Bool(value.trim() == "1"),
                            "e" => Cell::Error(value.clone()),
                            _ => {
                                if value.trim().is_empty() {
                                    Cell::Empty
                                } else {
                                    match value.trim().parse::<f64>() {
                                        Ok(number) => {
                                            let is_date = date_styles.get(cell_style).copied().unwrap_or(false);
                                            if is_date {
                                                Cell::Date(number, false)
                                            } else {
                                                Cell::Number(number)
                                            }
                                        }
                                        Err(_) => Cell::Text(value.clone()),
                                    }
                                }
                            }
                        };
                        cells.push((row_number, column, parsed));
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    cells
}

fn extract_xlsx(
    bytes: &[u8],
    budget: usize,
    notes: &mut Vec<String>,
) -> Result<Vec<Section>, OfficeError> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|_| OfficeError::new("this XLSX could not be opened as a zip archive".to_string()))?;
    let workbook = zip_text(&mut archive, "xl/workbook.xml")
        .ok_or_else(|| OfficeError::new("this XLSX has no xl/workbook.xml".to_string()))?;
    let shared = zip_text(&mut archive, "xl/sharedStrings.xml")
        .map(|xml| shared_strings(&xml))
        .unwrap_or_default();
    let date_styles = zip_text(&mut archive, "xl/styles.xml")
        .map(|xml| date_styles(&xml))
        .unwrap_or_default();
    let relations = workbook_relationships(
        &zip_text(&mut archive, "xl/_rels/workbook.xml.rels").unwrap_or_default(),
    );

    let sheets = workbook_sheets(&workbook);
    if sheets.is_empty() {
        return Err(OfficeError::new("this XLSX declares no sheets".to_string()));
    }

    let mut sections = Vec::new();
    let mut spent = 0usize;
    for (index, (sheet_name, relationship)) in sheets.iter().take(MAX_XLSX_SHEETS).enumerate() {
        if spent >= budget {
            notes.push(format!(
                "stopped before sheet {} of {} (character budget spent)",
                index + 1,
                sheets.len()
            ));
            break;
        }
        let Some(target) = relations
            .iter()
            .find(|(id, _)| id == relationship)
            .map(|(_, target)| target.clone())
        else {
            notes.push(format!("sheet '{sheet_name}' has no part in this workbook"));
            continue;
        };
        let path = if target.starts_with('/') {
            target.trim_start_matches('/').to_string()
        } else {
            format!("xl/{target}")
        };
        let Some(xml) = zip_text(&mut archive, &path) else {
            notes.push(format!("sheet '{sheet_name}' could not be read"));
            continue;
        };

        let cells = sheet_cells(&xml, &shared, &date_styles);
        if cells.is_empty() {
            sections.push(Section {
                label: format!("sheet: {sheet_name}"),
                body: "(this sheet is empty)".to_string(),
            });
            continue;
        }

        let min_row = cells.iter().map(|(row, _, _)| *row).min().unwrap_or(1);
        let max_row = cells.iter().map(|(row, _, _)| *row).max().unwrap_or(1);
        let min_col = cells.iter().map(|(_, col, _)| *col).min().unwrap_or(0);
        let max_col = cells.iter().map(|(_, col, _)| *col).max().unwrap_or(0);
        let rows = (max_row.saturating_sub(min_row) + 1) as usize;
        let columns = (max_col.saturating_sub(min_col) + 1) as usize;

        let shown_rows = rows.min(MAX_XLSX_ROWS);
        let shown_columns = columns.min(MAX_XLSX_COLS);
        let mut body = String::new();
        let mut by_row: Vec<(u32, usize, Cell)> = cells;
        by_row.sort_by_key(|(row, col, _)| (*row, *col));
        for row in min_row..min_row + shown_rows as u32 {
            let mut rendered: Vec<String> = vec![String::new(); shown_columns];
            for (_, cell_col, cell) in by_row.iter().filter(|(r, _, _)| *r == row) {
                let column = cell_col.saturating_sub(min_col);
                if column < shown_columns && *cell_col <= max_col {
                    rendered[column] = cell.render();
                }
            }
            let line = rendered.join(" | ");
            body.push_str(line.trim_end());
            body.push('\n');
        }
        if rows > shown_rows {
            body.push_str(&format!("[... {} more rows not shown]\n", rows - shown_rows));
            notes.push(format!(
                "sheet '{sheet_name}': rows {}-{rows} not extracted (limit {MAX_XLSX_ROWS} rows)",
                shown_rows + 1
            ));
        }
        if columns > shown_columns {
            body.push_str(&format!("[... {} more columns not shown]\n", columns - shown_columns));
            notes.push(format!(
                "sheet '{sheet_name}': columns {}-{columns} not extracted (limit {MAX_XLSX_COLS} columns)",
                shown_columns + 1
            ));
        }

        let body = cut(&body, remaining(budget, spent), notes, &format!("sheet '{sheet_name}'"));
        spent += body.chars().count();
        let mut label = format!("sheet: {sheet_name}");
        if rows > 1 || columns > 1 {
            label.push_str(&format!(", {rows} row{}, {columns} column{}",
                if rows == 1 { "" } else { "s" },
                if columns == 1 { "" } else { "s" }));
        }
        sections.push(Section { label, body });
    }

    if sheets.len() > MAX_XLSX_SHEETS {
        notes.push(format!(
            "sheets {}-{} not extracted (limit {MAX_XLSX_SHEETS} sheets)",
            MAX_XLSX_SHEETS + 1,
            sheets.len()
        ));
    }
    if sections.is_empty() {
        sections.push(Section {
            label: "xlsx, no readable sheets".to_string(),
            body: "(no sheet in this workbook could be read)".to_string(),
        });
    }
    Ok(sections)
}

// ---- CSV / plain text ------------------------------------------------------------------------

/// One CSV record, quotes and `""` escapes honoured — a formula bar's worth of correctness, not a
/// full RFC 4180 state machine over the whole file.
fn parse_csv_line(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut field = String::new();
    let mut in_quotes = false;
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '"' if in_quotes => {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    in_quotes = false;
                }
            }
            '"' if field.trim().is_empty() => {
                field.clear();
                in_quotes = true;
            }
            ',' if !in_quotes => {
                fields.push(field.trim().to_string());
                field.clear();
            }
            other => field.push(other),
        }
    }
    fields.push(field.trim().to_string());
    fields
}

fn extract_text(
    kind: Kind,
    bytes: &[u8],
    budget: usize,
    notes: &mut Vec<String>,
) -> Result<Vec<Section>, OfficeError> {
    let slice = &bytes[..bytes.len().min(MAX_TEXT_BYTES)];
    if bytes.len() > MAX_TEXT_BYTES {
        notes.push(format!(
            "only the first {} MiB was read (limit {} MiB)",
            MAX_TEXT_BYTES / (1024 * 1024),
            MAX_TEXT_BYTES / (1024 * 1024)
        ));
    }
    let text = std::str::from_utf8(slice).map_err(|_| {
        OfficeError::new("this file is not UTF-8 text, so it cannot be read as CSV or plain text".to_string())
    })?;
    let normalised = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut lines: Vec<&str> = normalised.split('\n').collect();
    if lines.last().map(|line| line.is_empty()).unwrap_or(false) {
        lines.pop();
    }
    let total = lines.len();
    let shown = total.min(MAX_TEXT_ROWS);
    let mut body = String::new();
    for line in lines.iter().take(shown) {
        if kind == Kind::Csv {
            let fields = parse_csv_line(line);
            body.push_str(fields.join(" | ").trim_end());
        } else {
            body.push_str(line.trim_end());
        }
        body.push('\n');
    }
    if total > shown {
        body.push_str(&format!("[... {} more rows not shown]\n", total - shown));
        notes.push(format!(
            "rows {}-{total} not extracted (limit {MAX_TEXT_ROWS} rows)",
            shown + 1
        ));
    }
    let body = cut(&body, budget, notes, "text");
    let unit = if kind == Kind::Csv { "rows" } else { "lines" };
    Ok(vec![Section {
        label: format!("{kind}, {shown} {unit}"),
        body,
    }])
}

// ---- the app-facing route --------------------------------------------------------------------

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, detail: impl Into<String>) -> Fail {
    (status, Json(json!({ "detail": detail.into() })))
}

/// The filename header is a label in a prompt, never a path: one component, no control characters,
/// preferably one that ends in the extension that names the type.
fn label_name(raw: &str) -> String {
    let name: String = raw
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("document")
        .chars()
        .filter(|c| !c.is_control())
        .take(120)
        .collect();
    if name.trim().is_empty() {
        "document".to_string()
    } else {
        name
    }
}

/// `POST /v1/office/extract` — here is a document, give me the block of text to put in the prompt.
///
/// Raw bytes in the body and the filename in `x-hermey-filename`, exactly like `POST /v1/attachments`:
/// one code path, no multipart parser to get wrong, and a `curl --data-binary @budget.xlsx` is the
/// whole client. A device ticket, or a caller on loopback (a bot on this host asking for itself).
///
/// The response is the block *and* its parts, so an app can paste `block` verbatim and still show
/// "12 000 characters, truncated" without re-reading anything.
pub async fn post_office_extract(
    State(st): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<Value>, Fail> {
    if require_device(&st, &headers).is_err() && !peer.ip().is_loopback() {
        return Err(bad(StatusCode::NOT_FOUND, "not found"));
    }
    if body.is_empty() {
        return Err(bad(StatusCode::BAD_REQUEST, "empty body"));
    }
    if body.len() > MAX_OFFICE_BYTES {
        return Err(bad(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!(
                "document larger than {} MiB",
                MAX_OFFICE_BYTES / (1024 * 1024)
            ),
        ));
    }
    let name = label_name(
        headers
            .get("x-hermey-filename")
            .and_then(|value| value.to_str().ok())
            .unwrap_or("document"),
    );

    extract_with_budget(&name, &body, MAX_EXTRACT_CHARS)
        .map(|extraction| Json(extraction.to_value()))
        .map_err(|error| bad(StatusCode::UNPROCESSABLE_ENTITY, error.detail().to_string()))
}

// ---- attachments on a message -----------------------------------------------------------------

/// One attachment as a caller hands it over: a name and either raw base64 or a `data:` URL.
pub struct Incoming<'a> {
    pub name: &'a str,
    pub data: &'a str,
}

/// Decode one attachment's bytes. The strict decoder and the 8 MiB ceiling are the ones the relay
/// already applies to `file.attach`, so a document that would be refused there is refused here too —
/// and a `data:` URL is accepted only with the MIME type the bytes must have.
pub fn decode_attachment(incoming: &Incoming<'_>) -> Result<Vec<u8>, OfficeError> {
    let mut data = incoming.data.trim();
    if let Some(rest) = data.strip_prefix("data:") {
        let Some((header, payload)) = rest.split_once(',') else {
            return Err(OfficeError::new(format!(
                "{}. data URL has no comma",
                incoming.name
            )));
        };
        let Some(encoding) = header.strip_suffix(";base64") else {
            return Err(OfficeError::new(format!(
                "{}. data URL is not base64",
                incoming.name
            )));
        };
        let declared = encoding.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
        if !declared.is_empty() && declared != "application/octet-stream" {
            let known = [
                Kind::Pdf,
                Kind::Docx,
                Kind::Xlsx,
                Kind::Csv,
                Kind::Text,
            ]
            .iter()
            .any(|kind| kind.mime().split(';').next() == Some(declared.as_str()));
            if !known {
                return Err(OfficeError::new(format!(
                    "{}: {declared} is not a document type this host reads",
                    incoming.name
                )));
            }
        }
        data = payload;
    }
    if data.is_empty() {
        return Err(OfficeError::new(format!("{} is empty", incoming.name)));
    }
    decode_base64(data).map_err(|_| {
        OfficeError::new(format!(
            "{}: the attachment is not valid base64",
            incoming.name
        ))
    })
}

/// Validate a name the way `attachments.rs` does: one component, bounded, no control characters.
pub fn valid_attachment_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && name != "."
        && name != ".."
        && !name.contains(|c: char| matches!(c, '/' | '\\' | '\u{0}' | '\n' | '\r'))
}

// ---- the prompt the relay forwards ------------------------------------------------------------

/// Whether a name claims one of the three document types the pickers offer. Those are the names the
/// send path checks against the bytes ([`sniff`]); everything else travels exactly as it did.
pub fn claims_office_document(name: &str) -> bool {
    matches!(
        extension(name).as_deref(),
        Some("pdf") | Some("docx") | Some("xlsx")
    )
}

/// Every `@file:` target a prompt carries, in order, wrappers stripped.
///
/// The app puts the `file.attach` receipt's reference into the prompt verbatim, and the engine's
/// `_format_ref_value` wraps a path containing whitespace in backticks, so both shapes are read
/// here. A bare target ends at whitespace — where the engine ends it — and keeps none of the
/// punctuation a sentence would put after a path.
fn file_refs(text: &str) -> Vec<String> {
    let mut refs = Vec::new();
    let mut cursor = 0usize;
    while let Some(offset) = text[cursor..].find("@file:") {
        let start = cursor + offset + "@file:".len();
        cursor = start;
        let rest = &text[start..];
        let Some(first) = rest.chars().next() else { break };
        let target = if matches!(first, '`' | '"' | '\'') {
            match rest[1..].find(first) {
                Some(close) => &rest[1..1 + close],
                // Unbalanced wrapper: the token ends where the next one can start, and nothing
                // after it is treated as a path.
                None => continue,
            }
        } else {
            let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
            rest[..end]
                .trim_end_matches(|c: char| matches!(c, '.' | ',' | ';' | ':' | '!' | '?' | ')' | ']' | '}'))
        };
        if !target.is_empty() {
            refs.push(target.to_string());
        }
    }
    refs
}

/// The labelled blocks for every office document this prompt references, so the engine reads the
/// document instead of a filename it can only stub as "binary file".
///
/// The reference itself is never touched: the `@file:` line in the stored row is how the app finds
/// the bytes again, and the engine still resolves it (to a stub). The text is *appended* after it,
/// bounded like every other delivery — [`MAX_EXTRACT_CHARS`] per document, [`MAX_MESSAGE_ATTACHMENT_CHARS`]
/// across the prompt — and a second prompt carrying the same document grows no second copy.
///
/// Only paths inside `engine_home` are read. A prompt may name anything it likes; the host turns a
/// claim into bytes only inside its own profiles, so a ref pointing at `/etc/…` is left for the
/// engine to refuse as it does today.
pub fn prompt_blocks(text: &str, engine_home: &Path) -> Option<String> {
    if engine_home.as_os_str().is_empty() {
        return None;
    }
    let root = engine_home.canonicalize().ok()?;
    let mut blocks = String::new();
    let mut spent = 0usize;
    let mut read = 0usize;
    for target in file_refs(text) {
        if read >= MAX_ATTACHMENTS_PER_MESSAGE {
            break;
        }
        if !claims_office_document(&target) {
            continue;
        }
        let path = Path::new(&target);
        if !path.is_absolute() {
            // A workspace-relative ref is the engine's own shorthand for its session cwd, which
            // this side does not know; it expands there as it always has.
            continue;
        }
        let Ok(resolved) = path.canonicalize() else { continue };
        if !resolved.starts_with(&root) {
            continue;
        }
        let Some(name) = resolved.file_name().and_then(|file| file.to_str()) else {
            continue;
        };
        if text.contains(&format!("--- attachment: {name}")) {
            continue;
        }
        read += 1;
        let budget = MAX_EXTRACT_CHARS.min(MAX_MESSAGE_ATTACHMENT_CHARS.saturating_sub(spent));
        if budget < 200 {
            blocks.push_str(&format!(
                "--- attachment: {name} (not included) ---\n\
                 [not included: this prompt already carries {MAX_MESSAGE_ATTACHMENT_CHARS} characters of attachments]\n"
            ));
            continue;
        }
        let Ok(bytes) = std::fs::read(&resolved) else { continue };
        let Ok(extraction) = extract_with_budget(name, &bytes, budget) else {
            // The bytes changed between the send and the prompt (or were never a document): say so
            // where the reader will meet it rather than silently dropping the reference.
            blocks.push_str(&format!(
                "--- attachment: {name} (not read) ---\n\
                 [not read: the file could not be parsed as a document]\n"
            ));
            continue;
        };
        spent += extraction.chars();
        if !blocks.is_empty() {
            blocks.push('\n');
        }
        blocks.push_str(&extraction.block());
    }
    (!blocks.is_empty()).then_some(blocks)
}

/// Real documents, built here rather than checked in as binaries: a fixture nobody can read in a
/// diff is a fixture nobody maintains. `#[cfg(test)]` because nothing in a running service needs to
/// write an Office file — only the tests do.
#[cfg(test)]
pub(crate) mod fixtures {
    use super::*;
    use std::io::Write;

/// A one-page PDF with a real text object, written by lopdf itself (a hand-typed xref offset
/// would be a test of my arithmetic, not of the reader).
pub(crate) fn pdf_fixture(text: &str) -> Vec<u8> {
    use lopdf::content::{Content, Operation};
    use lopdf::{dictionary, Document, Object, Stream};

    let mut doc = Document::with_version("1.5");
    let pages_id = doc.new_object_id();
    let font_id = doc.add_object(dictionary! {
        "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica",
    });
    let resources_id = doc.add_object(dictionary! {
        "Font" => dictionary! { "F1" => font_id },
    });
    let content = Content {
        operations: vec![
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![72.into(), 720.into()]),
            Operation::new("Tj", vec![Object::string_literal(text)]),
            Operation::new("ET", vec![]),
        ],
    };
    let content_id = doc.add_object(Stream::new(dictionary! {}, content.encode().unwrap()));
    let page_id = doc.add_object(dictionary! {
        "Type" => "Page", "Parent" => pages_id, "Contents" => content_id,
        "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
        "Resources" => resources_id,
    });
    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages", "Kids" => vec![page_id.into()], "Count" => 1,
        }),
    );
    let catalog_id = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    doc.trailer.set("Root", catalog_id);
    let mut out = Vec::new();
    doc.save_to(&mut out).unwrap();
    out
}

pub(crate) fn zip_of(entries: &[(&str, &str)]) -> Vec<u8> {
    let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    for (name, body) in entries {
        writer.start_file(name.to_string(), options).unwrap();
        writer.write_all(body.as_bytes()).unwrap();
    }
    writer.finish().unwrap().into_inner()
}

pub(crate) fn docx_fixture() -> Vec<u8> {
    let document = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Quarterly report</w:t></w:r></w:p>
<w:p><w:r><w:t>Revenue grew </w:t></w:r><w:r><w:t>by nine percent.</w:t></w:r></w:p>
<w:tbl>
  <w:tr><w:tc><w:p><w:r><w:t>Region</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Revenue</w:t></w:r></w:p></w:tc></w:tr>
  <w:tr><w:tc><w:p><w:r><w:t>North</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>1200</w:t></w:r></w:p></w:tc></w:tr>
</w:tbl>
<w:p><w:r><w:t>End of report.</w:t></w:r></w:p>
  </w:body>
</w:document>"#;
    zip_of(&[
        ("[Content_Types].xml", "<Types/>"),
        ("word/document.xml", document),
    ])
}

pub(crate) fn xlsx_fixture() -> Vec<u8> {
    let workbook = r#"<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
<sheet name="Q4" sheetId="1" r:id="rId1"/>
<sheet name="Summary" sheetId="2" r:id="rId2"/>
  </sheets>
</workbook>"#;
    let rels = r#"<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="worksheet" Target="worksheets/sheet2.xml"/>
</Relationships>"#;
    let shared = r#"<?xml version="1.0" encoding="UTF-8"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <si><t>Region</t></si><si><t>Units</t></si><si><t>North</t></si><si><t>South</t></si>
</sst>"#;
    let styles = r#"<?xml version="1.0" encoding="UTF-8"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\-mm\-dd"/></numFmts>
  <cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/></cellXfs>
</styleSheet>"#;
    let sheet1 = r#"<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>42</v></c></row>
<row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><v>7.5</v></c><c r="C3" s="1"><v>45658</v></c></row>
  </sheetData>
</worksheet>"#;
    let sheet2 = r#"<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Total</t></is></c><c r="B1"><v>1250</v></c></row></sheetData>
</worksheet>"#;
    zip_of(&[
        ("[Content_Types].xml", "<Types/>"),
        ("xl/workbook.xml", workbook),
        ("xl/_rels/workbook.xml.rels", rels),
        ("xl/sharedStrings.xml", shared),
        ("xl/styles.xml", styles),
        ("xl/worksheets/sheet1.xml", sheet1),
        ("xl/worksheets/sheet2.xml", sheet2),
    ])
}
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;
    use crate::test_support::{scratch, state};
    use axum::extract::ConnectInfo;
    use axum::http::HeaderValue;

    // ---- what each type is, and what a lie is ---------------------------------------------

    #[test]
    fn each_type_is_recognised_by_its_bytes() {
        assert_eq!(sniff("a.pdf", &pdf_fixture("hi")).unwrap(), Kind::Pdf);
        assert_eq!(sniff("a.docx", &docx_fixture()).unwrap(), Kind::Docx);
        assert_eq!(sniff("a.xlsx", &xlsx_fixture()).unwrap(), Kind::Xlsx);
        assert_eq!(sniff("a.csv", b"a,b\n1,2\n").unwrap(), Kind::Csv);
        assert_eq!(sniff("a.txt", b"hello\n").unwrap(), Kind::Text);
        // The right bytes under the wrong name are still accepted when nothing was claimed: a
        // downloaded file often arrives as `download` or with no extension at all.
        assert_eq!(sniff("download", &pdf_fixture("hi")).unwrap(), Kind::Pdf);
        assert_eq!(sniff("noext", &xlsx_fixture()).unwrap(), Kind::Xlsx);
    }

    #[test]
    fn a_mislabelled_file_is_refused_and_the_message_names_both_sides() {
        let error = sniff("budget.xlsx", &pdf_fixture("hi")).unwrap_err();
        assert!(error.detail().contains("budget.xlsx"), "{}", error.detail());
        assert!(error.detail().contains("Excel"), "{}", error.detail());
        assert!(error.detail().contains("PDF"), "{}", error.detail());

        // A .docx that is an .xlsx.
        let error = sniff("report.docx", &xlsx_fixture()).unwrap_err();
        assert!(error.detail().contains("Word"), "{}", error.detail());

        // A zip that is neither office format.
        let error = sniff("archive.zip", &zip_of(&[("x.txt", "x")])).unwrap_err();
        assert!(error.detail().contains("zip archive"), "{}", error.detail());
    }

    #[test]
    fn unsupported_binary_and_empty_input_are_refused() {
        assert!(sniff("photo.heic", &[0xff, 0xd8, 0xff, 0x00]).is_err());
        assert!(sniff("empty.pdf", b"").is_err());
        // A .pdf whose bytes are plain text is a lie too.
        assert!(sniff("fake.pdf", b"just some words\n").is_err());
    }

    // ---- extraction -----------------------------------------------------------------------

    #[test]
    fn a_pdf_yields_its_text_layer_with_a_page_marker() {
        let bytes = pdf_fixture("Hello office");
        let extraction = extract("contract.pdf", &bytes).unwrap();
        assert_eq!(extraction.kind, Kind::Pdf);
        assert!(
            extraction.block().contains("Hello office"),
            "{}",
            extraction.block()
        );
        assert!(extraction.block().contains("--- attachment: contract.pdf (pdf, 1 page) ---"));
        assert!(extraction.block().contains("[page 1]"));
    }

    #[test]
    fn a_docx_yields_headings_paragraphs_and_flattened_tables() {
        let extraction = extract("report.docx", &docx_fixture()).unwrap();
        let block = extraction.block();
        assert!(block.contains("--- attachment: report.docx (docx,"), "{block}");
        assert!(block.contains("# Quarterly report"), "{block}");
        // Two runs in one paragraph are one paragraph, not two.
        assert!(block.contains("Revenue grew by nine percent."), "{block}");
        assert!(block.contains("| Region | Revenue |"), "{block}");
        assert!(block.contains("| North | 1200 |"), "{block}");
        assert!(block.contains("End of report."), "{block}");
        // The heading is marked and the body paragraphs are in document order.
        let heading = block.find("# Quarterly report").unwrap();
        let table = block.find("| Region | Revenue |").unwrap();
        let end = block.find("End of report.").unwrap();
        assert!(heading < table && table < end);
    }

    #[test]
    fn an_xlsx_yields_one_block_per_sheet_with_pipe_separated_rows() {
        let extraction = extract("budget.xlsx", &xlsx_fixture()).unwrap();
        let block = extraction.block();
        assert!(block.contains("--- attachment: budget.xlsx (sheet: Q4,"), "{block}");
        assert!(block.contains("--- attachment: budget.xlsx (sheet: Summary"), "{block}");
        assert!(block.contains("Region | Units"), "{block}");
        assert!(block.contains("North | 42"), "{block}");
        assert!(block.contains("South | 7.5"), "{block}");
        // The style says this cell is a date, so it reads as one instead of a serial number.
        assert!(block.contains("2025-01-01"), "{block}");
        assert!(block.contains("Total | 1250"), "{block}");
    }

    #[test]
    fn csv_quotes_are_honoured_and_text_keeps_its_lines() {
        let csv = b"name,note,amount\n\"Smith, Jo\",\"said \"\"hi\"\"\",12\n";
        let extraction = extract("books.csv", csv).unwrap();
        let block = extraction.block();
        assert!(block.contains("Smith, Jo | said \"hi\" | 12"), "{block}");
        assert!(block.contains("--- attachment: books.csv (csv, 2 rows) ---"), "{block}");

        let extraction = extract("notes.txt", b"first line\nsecond line\n").unwrap();
        assert!(extraction.block().contains("first line\nsecond line"));
    }

    #[test]
    fn the_character_budget_is_spent_and_says_where_it_stopped() {
        let long = "x".repeat(MAX_EXTRACT_CHARS + 500);
        let bytes = format!("{long}\n");
        let extraction = extract_with_budget("big.txt", bytes.as_bytes(), MAX_EXTRACT_CHARS).unwrap();
        assert!(extraction.truncated());
        // The marker line that says where it stopped is inside the block, on purpose.
        assert!(extraction.chars() > MAX_EXTRACT_CHARS);
        assert!(extraction.chars() <= MAX_EXTRACT_CHARS + 64);
        assert!(extraction.block().contains("[... truncated at"));
        assert!(extraction.notes.iter().any(|note| note.contains("characters")));
    }

    #[test]
    fn a_sheet_past_the_row_limit_says_how_many_rows_are_missing() {
        let mut rows = String::new();
        for row in 1..=MAX_XLSX_ROWS + 5 {
            rows.push_str(&format!("<row r=\"{row}\"><c r=\"A{row}\"><v>{row}</v></c></row>"));
        }
        let sheet = format!(
            r#"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>{rows}</sheetData></worksheet>"#
        );
        let bytes = zip_of(&[
            ("[Content_Types].xml", "<Types/>"),
            (
                "xl/workbook.xml",
                r#"<workbook xmlns:r="r"><sheets><sheet name="Big" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            ),
            (
                "xl/_rels/workbook.xml.rels",
                r#"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>"#,
            ),
            ("xl/worksheets/sheet1.xml", &sheet),
        ]);
        let extraction = extract("big.xlsx", &bytes).unwrap();
        assert!(extraction.truncated());
        assert!(extraction.block().contains("more rows not shown"));
        assert!(
            extraction
                .notes
                .iter()
                .any(|note| note.contains("limit 500 rows")),
            "{:?}",
            extraction.notes
        );
        // The first rows are there; the 501st is not.
        assert!(extraction.block().contains("\n1\n"));
        assert!(!extraction.block().contains("\n505\n"));
    }

    // ---- the wire shape -------------------------------------------------------------------

    #[test]
    fn the_value_is_the_block_plus_what_was_truncated() {
        let extraction = extract("report.docx", &docx_fixture()).unwrap();
        let value = extraction.to_value();
        assert_eq!(value["name"], "report.docx");
        assert_eq!(value["kind"], "docx");
        assert_eq!(
            value["mime"],
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        );
        assert_eq!(value["truncated"], false);
        assert!(value["chars"].as_u64().unwrap() > 0);
        assert_eq!(value["block"], extraction.block());
        assert!(value["text"].as_str().unwrap().contains("Quarterly"));

        let summary = extraction.summary();
        assert_eq!(summary.as_object().unwrap().len(), 4);
        assert_eq!(summary["name"], "report.docx");
    }

    #[test]
    fn a_data_url_is_accepted_for_the_type_it_declares_and_refused_for_another() {
        let bytes = docx_fixture();
        let encoded = base64_of(&bytes);
        let data = format!(
            "data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64,{encoded}"
        );
        let decoded = decode_attachment(&Incoming { name: "a.docx", data: &data }).unwrap();
        assert_eq!(decoded, bytes);

        // A declared MIME that no reader here handles is refused rather than guessed at.
        let wrong = format!("data:image/png;base64,{encoded}");
        assert!(decode_attachment(&Incoming { name: "a.docx", data: &wrong }).is_err());

        // Plain base64 and `application/octet-stream` are both fine.
        let plain = decode_attachment(&Incoming { name: "a.docx", data: &encoded }).unwrap();
        assert_eq!(plain, bytes);
        let octet = format!("data:application/octet-stream;base64,{encoded}");
        assert!(decode_attachment(&Incoming { name: "a.docx", data: &octet }).is_ok());

        assert!(decode_attachment(&Incoming { name: "a.docx", data: "not base64!!" }).is_err());
        assert!(decode_attachment(&Incoming { name: "a.docx", data: "" }).is_err());
    }

    #[test]
    fn attachment_names_are_one_component() {
        assert!(valid_attachment_name("budget.xlsx"));
        assert!(valid_attachment_name("Q4 budget final (v2).xlsx"));
        for name in ["../etc/passwd", "a/b", "a\\b", "", ".", "..", "a\nb"] {
            assert!(!valid_attachment_name(name), "{name:?}");
        }
    }

    fn base64_of(bytes: &[u8]) -> String {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    // ---- the route ---------------------------------------------------------------------------

    fn headers(name: &str, token: Option<&str>) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert("x-hermey-filename", HeaderValue::from_str(name).unwrap());
        if let Some(token) = token {
            headers.insert(
                "authorization",
                HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
            );
        }
        headers
    }

    async fn call(
        st: &Arc<AppState>,
        peer: &str,
        headers: HeaderMap,
        body: Vec<u8>,
    ) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
        post_office_extract(
            State(Arc::clone(st)),
            ConnectInfo(peer.parse::<SocketAddr>().unwrap()),
            headers,
            Bytes::from(body),
        )
        .await
    }

    #[tokio::test]
    async fn the_route_answers_a_device_and_a_loopback_bot_and_nobody_else() {
        let dir = scratch("office-route");
        let st = Arc::new(state(&dir));
        let bytes = docx_fixture();

        // A paired device, with the ticket every other route takes.
        let value = call(&st, "10.0.0.7:5000", headers("report.docx", Some("test-local-token")), bytes.clone())
            .await
            .expect("a device ticket is enough");
        assert_eq!(value.0["kind"], "docx");
        assert!(value.0["block"].as_str().unwrap().contains("Quarterly report"));
        assert_eq!(value.0["truncated"], false);
        assert!(value.0["chars"].as_u64().unwrap() > 0);

        // A bot on this host, with no credential at all: same route, same answer.
        let local = call(&st, "127.0.0.1:5000", headers("report.docx", None), bytes.clone())
            .await
            .expect("loopback is a bot on this host");
        assert_eq!(local.0["block"], value.0["block"]);

        // A caller through the tailscale proxy with no ticket learns nothing: not even that the
        // route exists, which is the answer every unknown route gives.
        let error = call(&st, "10.0.0.7:5000", headers("report.docx", None), bytes)
            .await
            .unwrap_err();
        assert_eq!(error.0, StatusCode::NOT_FOUND);
        assert_eq!(error.1 .0["detail"], "not found");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn the_route_refuses_what_it_cannot_read_and_says_why() {
        let dir = scratch("office-refusals");
        let st = Arc::new(state(&dir));
        let authorised = || headers("budget.xlsx", Some("test-local-token"));

        // A mislabelled document: 422 with the name and both sides of the disagreement.
        let error = call(&st, "127.0.0.1:1", authorised(), pdf_fixture("x"))
            .await
            .unwrap_err();
        assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY);
        let detail = error.1 .0["detail"].as_str().unwrap().to_string();
        assert!(detail.contains("budget.xlsx") && detail.contains("Excel"), "{detail}");

        // An empty body, and something that is not a document at all.
        assert_eq!(
            call(&st, "127.0.0.1:1", authorised(), Vec::new()).await.unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            call(&st, "127.0.0.1:1", authorised(), vec![0x00, 0x01, 0x02])
                .await
                .unwrap_err()
                .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );

        // One byte over the ceiling is refused by the explicit check (the router's body limit would
        // answer first in a real request, with the same status).
        let oversize = vec![b'a'; MAX_OFFICE_BYTES + 1];
        assert_eq!(
            call(&st, "127.0.0.1:1", authorised(), oversize).await.unwrap_err().0,
            StatusCode::PAYLOAD_TOO_LARGE
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_filename_header_is_a_label_not_a_path() {
        // A caller that sends a traversal as the name cannot steer anything: it is cut to its last
        // component and stripped of control characters.
        assert_eq!(label_name("../../etc/passwd"), "passwd");
        assert_eq!(label_name("Q4 budget.xlsx"), "Q4 budget.xlsx");
        assert_eq!(label_name("  "), "document");
        assert!(!label_name("a\nb.docx").contains('\n'));
        // Nothing in it is a path component any more.
        for name in ["../../x", "..\\..\\y", "/etc/shadow"] {
            assert!(!label_name(name).contains(['/', '\\']), "{name}");
        }
    }

    // ---- the prompt the relay forwards -------------------------------------------------------

    /// The delivery contract: an office reference becomes the labelled block the engine reads,
    /// inside the host's own tree only, and a second pass over the same prompt adds nothing.
    #[test]
    fn a_prompt_reference_becomes_a_labelled_block_and_only_inside_the_host() {
        let dir = scratch("prompt-blocks");
        let attachments = dir.join("profiles").join("cody").join("attachments");
        std::fs::create_dir_all(&attachments).unwrap();
        std::fs::write(attachments.join("budget.xlsx"), xlsx_fixture()).unwrap();
        std::fs::write(attachments.join("scan.pdf"), pdf_fixture("Invoice 4711")).unwrap();
        std::fs::write(attachments.join("shot.png"), b"\x89PNG\r\n").unwrap();
        let outside = scratch("prompt-blocks-outside");
        std::fs::write(outside.join("budget.xlsx"), xlsx_fixture()).unwrap();

        let workbook = attachments.join("budget.xlsx");
        let text = format!("@file:{}\n\nwhat is in it?", workbook.display());
        let blocks = prompt_blocks(&text, &dir).expect("the document's text reaches the prompt");
        assert!(blocks.starts_with("--- attachment: budget.xlsx (sheet:"), "{blocks}");
        assert!(blocks.contains("North | 42"), "{blocks}");

        // The reference itself is the app's handle and is never rewritten: `prompt_blocks` only
        // says what to append, and the relay appends it after the caller's own words.
        assert!(text.starts_with("@file:"), "the caller's text is not this function's to edit");

        // Idempotent: the same prompt, already carrying the block, gains no second copy.
        let with_block = format!("{text}\n\n{blocks}");
        assert_eq!(prompt_blocks(&with_block, &dir), None);

        // An image reference, a relative one, a path outside the host, and a plain sentence are
        // all left for the engine exactly as they were.
        assert_eq!(
            prompt_blocks(&format!("@file:{}\n\nlook", attachments.join("shot.png").display()), &dir),
            None
        );
        assert_eq!(prompt_blocks("@file:attachments/budget.xlsx\n\nlook", &dir), None);
        assert_eq!(
            prompt_blocks(&format!("@file:{}\n\nlook", outside.join("budget.xlsx").display()), &dir),
            None
        );
        assert_eq!(prompt_blocks("just words", &dir), None);
        // No root at all (the policy-only state) reads nothing.
        assert_eq!(prompt_blocks(&text, std::path::Path::new("")), None);

        // A document that claims one type and is another is not read into a prompt either: the
        // refusal path already stopped it at the send, and the bytes are checked again here.
        std::fs::write(attachments.join("liar.xlsx"), pdf_fixture("x")).unwrap();
        let liar = format!("@file:{}\n\nlook", attachments.join("liar.xlsx").display());
        assert!(prompt_blocks(&liar, &dir).unwrap().contains("not read"), "the lie is named");

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&outside);
    }

    /// The attribute helper every document goes through: namespace prefixes stripped, entities
    /// resolved, and the XML spec's attribute normalization applied — a style name reads the same
    /// whichever tool wrote it.
    #[test]
    fn attributes_are_resolved_and_normalised() {
        let mut reader = Reader::from_str(r#"<w:pStyle w:val="Q4 &amp; Partners" xmlns="x"/>"#);
        let mut found = Vec::new();
        loop {
            match reader.read_event() {
                Ok(Event::Empty(element)) | Ok(Event::Start(element)) => {
                    found.extend(attributes(&element));
                }
                Ok(Event::Eof) => break,
                Ok(_) => {}
                Err(error) => panic!("the fixture must parse: {error}"),
            }
        }
        assert!(
            found.contains(&("val".to_string(), "Q4 & Partners".to_string())),
            "an entity in an attribute must resolve: {found:?}"
        );
        assert!(
            found.contains(&("xmlns".to_string(), "x".to_string())),
            "a namespace declaration is an attribute like any other: {found:?}"
        );
    }

    /// The three names the send path sniffs — and only those.
    #[test]
    fn only_the_picker_types_claim_a_document() {
        assert!(claims_office_document("budget.XLSX"));
        assert!(claims_office_document("a.b.docx"));
        assert!(claims_office_document("scan.pdf"));
        for name in ["shot.png", "notes.txt", "data.csv", "archive.zip", "noext", "doc"] {
            assert!(!claims_office_document(name), "{name}");
        }
    }
}
