//! Attachment parameter validation — port of
//! `Bridge/hermes_bridge/attachment_validation.py`.
//!
//! The allow-listed attachment methods (`file.attach`, `image.attach_bytes`) carry their bytes
//! inside the JSON-RPC frame, and before this module existed the relay forwarded whatever it was
//! handed: an arbitrary filename, an unbounded payload, a path instead of a data URL. The Python
//! bridge refused all of that before proxying ([`attachment_validation.py:18-45`]), and the app
//! only ever learned one thing from a refusal: JSON-RPC `-32602`, message `"invalid attachment"`
//! (`proxy.py:524-529`). Those two shapes are reproduced here.
//!
//! The checks, and where each comes from:
//!
//! | check | Python line |
//! |---|---|
//! | method in the byte-only set, params an object | `18-20` |
//! | `session_id` string, 1–128 chars | `26-27` |
//! | name string, 1–255 UTF-8 bytes, not `.`/`..`, no `/ \ NUL CR LF` | `28-29` |
//! | `file.attach` data is `data:application/octet-stream;base64,` + base64 | `33-37` |
//! | payload non-empty and ≤ `((8 MiB + 2) / 3) * 4` base64 chars | `38-39` |
//! | strict base64, decoded 1–8 MiB | `40-45` |
//! | only the keys those methods need (`session_id` + name + bytes) | `21-23` |
//!
//! There is no extension allow-list in the Python module and none is invented here: the MIME rule
//! is the fixed `application/octet-stream` prefix on `file.attach`, and `image.attach_bytes`
//! carries raw bytes with no prefix at all. The name rules are about traversal and length, not
//! type. (`pdf.attach` is hard-denied to remote clients by `relay::HARD_DENIED_CLIENT_METHODS`,
//! exactly as `proxy.py:502-503` did; when a host-side caller hands it in, it uses the `file.attach`
//! data-URL rules so it cannot be the one path with no ceiling.)

use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use base64::{alphabet, Engine as _};
use serde_json::Value;
use std::borrow::Cow;

/// `attachment_validation.py:9` — 8 MiB of decoded bytes.
pub const MAX_ATTACHMENT_BYTES: usize = 8 * 1024 * 1024;
/// `_MAX_ATTACHMENT_LABEL`, interpolated into the Python message. Kept named so the literal in
/// [`empty_or_oversize`] is traceable to its Python origin.
#[allow(dead_code)]
pub const MAX_ATTACHMENT_LABEL: &str = "8 MiB";
/// Base64 expansion of the cap, `((MAX + 2) // 3) * 4`. Checked *before* decoding so a 40 MB
/// string is refused without allocating its 30 MB decode.
pub const MAX_BASE64_LEN: usize = ((MAX_ATTACHMENT_BYTES + 2) / 3) * 4;

/// `attachment_validation.py:11` — the byte-only subset.
pub const ATTACHMENT_METHODS: &[&str] = &["file.attach", "image.attach_bytes"];
/// Refused to remote clients by the relay, but a host-side caller gets the same data-URL checks.
pub const PDF_ATTACH: &str = "pdf.attach";

/// Python's `b64decode(..., validate=True)` rejects non-alphabet characters but tolerates absent
/// padding, so the decoder must be strict about bytes and indifferent about padding. `STANDARD`'s
/// default requires canonical padding and would refuse payloads the bridge accepted.
const B64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

/// `data:application/octet-stream;base64,` — the only MIME shape `file.attach` accepts.
const FILE_PREFIX: &str = "data:application/octet-stream;base64,";

const SESSION_ID: &str = "session_id";

/// A refusal. The `detail` is the Python message verbatim, so a test (and a caller's log) can tell
/// which check failed without ever seeing the payload.
///
/// The one refusal that carries its own sentence instead is the content sniff: the Python bridge
/// never read a file's bytes, so it has no message for "this `.xlsx` is a PDF" — and a fixed
/// `invalid attachment` would tell the person who just picked a file nothing at all. Those errors
/// are built with [`AttachmentError::explained`] and the relay echoes their detail.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AttachmentError {
    detail: Cow<'static, str>,
    explain: bool,
}

impl AttachmentError {
    const fn new(detail: &'static str) -> Self {
        Self {
            detail: Cow::Borrowed(detail),
            explain: false,
        }
    }

    /// A refusal whose wording is the point: the relay sends `detail` to the client instead of the
    /// bridge's fixed `invalid attachment`.
    fn explained(detail: String) -> Self {
        Self {
            detail: Cow::Owned(detail),
            explain: true,
        }
    }

    /// The message `attachment_validation.py` raises for this refusal — or, for a sniff, the one
    /// written here.
    #[allow(dead_code)] // asserted in the tests; the relay only needs the `Err`
    pub fn detail(&self) -> &str {
        &self.detail
    }

    /// Whether the relay may echo [`Self::detail`] to the client.
    pub fn explains(&self) -> bool {
        self.explain
    }
}

impl std::fmt::Display for AttachmentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.detail)
    }
}

impl std::error::Error for AttachmentError {}

/// Whether a method's params must pass [`validate_attachment_request`].
pub fn is_attachment_method(method: &str) -> bool {
    ATTACHMENT_METHODS.contains(&method) || method == PDF_ATTACH
}

/// The JSON-RPC answer the app already knows (`proxy.py:527-528`): `-32602 invalid attachment`.
/// The reason is never echoed to the client — the Python bridge sent one fixed message.
pub fn invalid_params_frame(id: Value) -> Value {
    invalid_params_frame_with(id, "invalid attachment")
}

/// The same refusal with a reason the caller can act on. Only the content sniff uses it: a file the
/// person just picked came back refused, and `invalid attachment` alone would leave them guessing
/// which of their three files the host would not take.
pub fn invalid_params_frame_with(id: Value, message: impl Into<String>) -> Value {
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": -32602, "message": message.into() },
    })
}

/// Validate the byte-only subset of an attachment request. Ok means "forward it unchanged".
pub fn validate_attachment_request(
    method: &str,
    params: Option<&Value>,
) -> Result<(), AttachmentError> {
    // `if method not in ATTACHMENT_METHODS or not isinstance(params, dict)`
    if !is_attachment_method(method) {
        return Err(AttachmentError::new("Invalid attachment request"));
    }
    let Some(params) = params.and_then(Value::as_object) else {
        return Err(AttachmentError::new("Invalid attachment request"));
    };

    // `set(params) - allowed` — a caller cannot smuggle `path`, `staged_upload` or extra fields
    // alongside the bytes for a later layer to honour.
    let (name_key, data_key) = if method == "image.attach_bytes" {
        ("filename", "content_base64")
    } else {
        ("name", "data_url")
    };
    if params
        .keys()
        .any(|key| key != SESSION_ID && key != name_key && key != data_key)
    {
        return Err(AttachmentError::new("Only byte uploads are permitted"));
    }

    // `if not isinstance(sid, str) or not sid or len(sid) > 128`
    match params.get(SESSION_ID).and_then(Value::as_str) {
        Some(sid) if !sid.is_empty() && sid.chars().count() <= 128 => {}
        _ => return Err(AttachmentError::new("Invalid session")),
    }

    // `len(name.encode("utf-8")) > 255 or name in (".", "..") or any(c in name for c in ...)`
    let name = match params.get(name_key).and_then(Value::as_str) {
        Some(name) => name,
        None => return Err(AttachmentError::new("Invalid attachment name")),
    };
    if name.is_empty()
        || name.len() > 255
        || name == "."
        || name == ".."
        || name.contains(|c| matches!(c, '/' | '\\' | '\u{0}' | '\n' | '\r'))
    {
        return Err(AttachmentError::new("Invalid attachment name"));
    }

    // `if not isinstance(data, str)`
    let Some(data) = params.get(data_key).and_then(Value::as_str) else {
        return Err(AttachmentError::new("Attachment data is required"));
    };

    // `file.attach` (and the host-side `pdf.attach`) must name the MIME type explicitly.
    let data = if method == "image.attach_bytes" {
        data
    } else {
        let Some(stripped) = data.strip_prefix(FILE_PREFIX) else {
            return Err(AttachmentError::new("Invalid attachment data URL"));
        };
        stripped
    };

    // `if not data or len(data) > ((MAX + 2) // 3) * 4`
    if data.is_empty() || data.len() > MAX_BASE64_LEN {
        return Err(empty_or_oversize());
    }

    // `base64.b64decode(data, validate=True)` — strict, like `validate=True`: whitespace and
    // non-alphabet characters are errors, not something to skip.
    let decoded = B64
        .decode(data)
        .map_err(|_| AttachmentError::new("Invalid attachment encoding"))?;

    // `if not decoded or len(decoded) > MAX_ATTACHMENT_BYTES`
    if decoded.is_empty() || decoded.len() > MAX_ATTACHMENT_BYTES {
        return Err(empty_or_oversize());
    }

    // The three document types the pickers offer are checked against their own bytes before they
    // travel. `file.attach` has always been name-only — the Python bridge never read a file — so a
    // `.xlsx` that is really a PDF would reach a bot as something nobody can open; the refusal
    // carries both facts (see [`AttachmentError::explained`]). Images are not sniffed: that path
    // is unchanged, byte for byte, and so is every other extension.
    if method != "image.attach_bytes" && crate::office::claims_office_document(name) {
        if let Err(error) = crate::office::sniff(name, &decoded) {
            return Err(AttachmentError::explained(error.detail().to_string()));
        }
    }
    Ok(())
}

/// Strict base64 → bytes, with the same decoder [`validate_attachment_request`] uses.
///
/// Exposed so the office-document path (`office.rs`) decodes with the one strict decoder this crate
/// has, rather than a second one that could disagree about padding or stray characters.
pub fn decode_base64(data: &str) -> Result<Vec<u8>, AttachmentError> {
    B64.decode(data)
        .map_err(|_| AttachmentError::new("Invalid attachment encoding"))
}

/// `f'Attachment is empty or exceeds {_MAX_ATTACHMENT_LABEL}'` — one message for both ends, as in
/// Python: an empty payload and an oversized one are the same refusal to the app.
fn empty_or_oversize() -> AttachmentError {
    // The Python f-string is `Attachment is empty or exceeds 8 MiB`; keep it byte-identical.
    AttachmentError::new("Attachment is empty or exceeds 8 MiB")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn b64(bytes: &[u8]) -> String {
        B64.encode(bytes)
    }

    fn file_params(name: &str, data: &str) -> Value {
        json!({
            "session_id": "s-1",
            "name": name,
            "data_url": format!("{FILE_PREFIX}{data}"),
        })
    }

    fn image_params(name: &str, data: &str) -> Value {
        json!({
            "session_id": "s-1",
            "filename": name,
            "content_base64": data,
        })
    }

    #[test]
    fn a_valid_file_attachment_passes_unchanged() {
        let params = file_params("notes.pdf", &b64(b"%PDF-1.4 hello"));
        validate_attachment_request("file.attach", Some(&params)).expect("valid attachment");
        // Validation must not rewrite what it forwards.
        assert_eq!(params["name"], "notes.pdf");
        assert_eq!(params["session_id"], "s-1");
    }

    #[test]
    fn a_valid_image_attachment_passes() {
        let params = image_params("shot.png", &b64(b"\x89PNG\r\n"));
        validate_attachment_request("image.attach_bytes", Some(&params))
            .expect("valid image attachment");
    }

    #[test]
    fn path_traversal_is_rejected() {
        for name in ["../etc/passwd", "a/b.txt", "a\\b.txt", "..", "."] {
            let params = file_params(name, &b64(b"x"));
            let err = validate_attachment_request("file.attach", Some(&params))
                .expect_err("traversal must be refused");
            assert_eq!(err.detail(), "Invalid attachment name", "name {name:?}");
        }
    }

    #[test]
    fn an_oversize_payload_is_rejected_before_decoding() {
        // One character over the base64 ceiling; never decoded.
        let data = "A".repeat(MAX_BASE64_LEN + 1);
        let params = image_params("big.bin", &data);
        let err = validate_attachment_request("image.attach_bytes", Some(&params))
            .expect_err("oversize must be refused");
        assert_eq!(err.detail(), "Attachment is empty or exceeds 8 MiB");

        // ... and a string at exactly the base64 ceiling that decodes one byte past the cap is
        // refused after decoding, as Python does (`MAX + 1` is divisible by 3, so its base64 form
        // is exactly `MAX_BASE64_LEN` characters).
        let data = b64(&vec![0u8; MAX_ATTACHMENT_BYTES + 1]);
        assert_eq!(data.len(), MAX_BASE64_LEN, "the ceiling must be exact");
        let params = image_params("big.bin", &data);
        let err = validate_attachment_request("image.attach_bytes", Some(&params))
            .expect_err("decoded oversize must be refused");
        assert_eq!(err.detail(), "Attachment is empty or exceeds 8 MiB");
    }

    #[test]
    fn an_empty_payload_is_rejected() {
        let params = image_params("empty.bin", "");
        assert_eq!(
            validate_attachment_request("image.attach_bytes", Some(&params))
                .unwrap_err()
                .detail(),
            "Attachment is empty or exceeds 8 MiB"
        );
    }

    #[test]
    fn the_wrong_transport_shape_is_rejected() {
        // An image method handed the file method's params, and a file method handed raw bytes:
        // both are "not the byte-only subset this method declares".
        assert_eq!(
            validate_attachment_request(
                "image.attach_bytes",
                Some(&file_params("a.png", &b64(b"x")))
            )
            .unwrap_err()
            .detail(),
            "Only byte uploads are permitted"
        );
        assert_eq!(
            validate_attachment_request("file.attach", Some(&image_params("a.png", &b64(b"x"))))
                .unwrap_err()
                .detail(),
            "Only byte uploads are permitted"
        );
    }

    #[test]
    fn a_wrong_or_missing_mime_prefix_is_rejected() {
        for data in [
            format!("data:image/png;base64,{}", b64(b"x")),
            format!("data:application/octet-stream,{}", b64(b"x")),
            b64(b"x"),
        ] {
            let params = json!({"session_id": "s-1", "name": "a.bin", "data_url": data});
            assert_eq!(
                validate_attachment_request("file.attach", Some(&params))
                    .unwrap_err()
                    .detail(),
                "Invalid attachment data URL"
            );
        }
    }

    #[test]
    fn extra_fields_are_rejected() {
        let params = json!({
            "session_id": "s-1",
            "name": "a.bin",
            "data_url": format!("{FILE_PREFIX}{}", b64(b"x")),
            "path": "/etc/passwd",
        });
        assert_eq!(
            validate_attachment_request("file.attach", Some(&params))
                .unwrap_err()
                .detail(),
            "Only byte uploads are permitted"
        );
    }

    #[test]
    fn bad_encoding_and_bad_names_use_the_python_messages() {
        let params = file_params("a.bin", "not base64!!");
        assert_eq!(
            validate_attachment_request("file.attach", Some(&params))
                .unwrap_err()
                .detail(),
            "Invalid attachment encoding"
        );

        let long = "x".repeat(256);
        assert_eq!(
            validate_attachment_request("image.attach_bytes", Some(&image_params(&long, &b64(b"x"))))
                .unwrap_err()
                .detail(),
            "Invalid attachment name"
        );

        let params = json!({"session_id": "", "filename": "a", "content_base64": b64(b"x")});
        assert_eq!(
            validate_attachment_request("image.attach_bytes", Some(&params))
                .unwrap_err()
                .detail(),
            "Invalid session"
        );

        assert_eq!(
            validate_attachment_request("file.attach", None)
                .unwrap_err()
                .detail(),
            "Invalid attachment request"
        );
        assert_eq!(
            validate_attachment_request("prompt.submit", Some(&file_params("a", "AAAA")))
                .unwrap_err()
                .detail(),
            "Invalid attachment request"
        );
    }

    #[test]
    fn the_refusal_frame_is_the_one_the_app_already_handles() {
        let frame = invalid_params_frame(json!(7));
        assert_eq!(frame["error"]["code"], -32602);
        assert_eq!(frame["error"]["message"], "invalid attachment");
        assert_eq!(frame["id"], 7);
    }

    // ---- the documents the pickers now offer ------------------------------------------------

    /// The send path's whole new contract: `pdf`, `docx` and `xlsx` travel as they are, images are
    /// untouched, and the bytes are what says whether a document is really one.
    #[test]
    fn the_three_office_types_pass_the_send_path() {
        use crate::office::fixtures;

        for (name, bytes) in [
            ("invoice.pdf", fixtures::pdf_fixture("Invoice 4711")),
            ("report.docx", fixtures::docx_fixture()),
            ("budget.xlsx", fixtures::xlsx_fixture()),
        ] {
            let params = file_params(name, &b64(&bytes));
            validate_attachment_request("file.attach", Some(&params)).expect(name);
        }

        // The image path is byte-identical: no sniff, same decoder, same silence.
        let params = image_params("shot.png", &b64(b"\x89PNG\r\n"));
        let error = validate_attachment_request("image.attach_bytes", Some(&params));
        assert!(error.is_ok());
        // ... and an extension this host does not read still travels, exactly as the bridge let it.
        let params = file_params("notes.odt", &b64(b"PK\x03\x04plain"));
        assert!(validate_attachment_request("file.attach", Some(&params)).is_ok());
    }

    /// A `.xlsx` that is a PDF in disguise is refused with both facts, and that refusal — unlike
    /// every Python-shaped one — is the message the app shows the person who picked the file.
    #[test]
    fn a_mislabelled_document_is_refused_and_the_reason_is_theirs() {
        use crate::office::fixtures;

        let params = file_params("budget.xlsx", &b64(&fixtures::pdf_fixture("x")));
        let error = validate_attachment_request("file.attach", Some(&params))
            .expect_err("a PDF wearing an .xlsx name must not travel");
        assert!(error.detail().contains("budget.xlsx"), "{}", error.detail());
        assert!(error.detail().contains("Excel"), "{}", error.detail());
        assert!(error.explains(), "the detail is the point of this refusal");

        // A real zip that is neither document, under a name that claims one.
        let params = file_params("report.docx", &b64(&crate::office::fixtures::zip_of(&[("readme.txt", "hi")])));
        let error = validate_attachment_request("file.attach", Some(&params)).unwrap_err();
        assert!(error.explains());
        assert!(error.detail().contains("report.docx"), "{}", error.detail());

        // Every Python-shaped refusal keeps its fixed message: only the sniff speaks for itself.
        let params = file_params("../etc/passwd", &b64(b"%PDF-1.4"));
        let error = validate_attachment_request("file.attach", Some(&params)).unwrap_err();
        assert_eq!(error.detail(), "Invalid attachment name");
        assert!(!error.explains());

        let frame = invalid_params_frame_with(json!(9), error.detail());
        assert_eq!(frame["error"]["code"], -32602);
        assert_eq!(frame["error"]["message"], "Invalid attachment name");
    }
}
