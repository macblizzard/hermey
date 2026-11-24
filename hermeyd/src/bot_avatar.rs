//! The avatar a bot may carry: an `open-bot-avatar` v1 definition, and the rules for accepting one.
//!
//! The definition is one monochrome SVG path in a fixed `0 0 100 100` box plus a placement for the
//! eye pair (`docs/avatar-contract.md` upstream). It is stored beside the bot's chosen face in
//! `DOC_ICONS`:
//!
//! ```json
//! { "faces": { "cody": { "avatar": "#A97EFE::shape_1", "definition": { … }, "color": "#A97EFE" } } }
//! ```
//!
//! **The same rules are enforced twice, on purpose.** The host refuses a bad definition with a 400
//! and the reason, so a hand-edited document or a script cannot poison the store; the Swift side
//! (`Sources/HermeyUI/OpenBotAvatar/BotAvatarDefinition.swift`) re-checks before drawing, because a
//! definition can also arrive from an older host that predates this route. The two implementations
//! read the same contract, and `Tests/test_open_bot_avatar.py` checks that theirs and ours accept
//! and reject the same shapes.
//!
//! **Why this is not a full SVG parser.** The host has no need to know what the path *looks* like —
//! only that it is a safe, well-formed path inside the box. So it reads the command letters and the
//! numbers, and checks the extents of every number it finds. Arc radii and flags are numbers too, so
//! the box check is conservative: a path whose `rx` alone leaves the box is refused even if the
//! flattened curve would not. That is the right way round for a validator — a false refusal is a
//! visible "fix your path", a false accept is a drawing that runs off its tile.

use serde_json::{json, Value};

/// Contract limits, copied from upstream `packages/core/src/path.ts` (`PATH_LIMITS`).
pub const MAX_PATH_CHARS: usize = 6000;
const MAX_SUBPATHS: usize = 16;
/// Hard bounds of a body's geometry: the safe area inside the 0..100 box (upstream `BODY_MIN/MAX`).
const BODY_MIN: f64 = 6.0;
const BODY_MAX: f64 = 94.0;
/// Neutral eye size at scale 1 (upstream `EYE_W`, `EYE_H`).
const EYE_W: f64 = 4.0;
const EYE_H: f64 = 11.0;

const TOP_KEYS: [&str; 5] = ["version", "id", "name", "body", "eyes"];
const EYE_KEYS: [&str; 4] = ["x", "y", "spacing", "scale"];

/// A validated definition, normalised to the fields the apps store.
#[derive(Debug, Clone, PartialEq)]
pub struct AvatarSpec {
    pub id: String,
    pub name: String,
    pub path: String,
    pub eyes: AvatarEyes,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AvatarEyes {
    pub x: f64,
    pub y: f64,
    pub spacing: f64,
    pub scale: f64,
}

impl AvatarSpec {
    /// The definition exactly as it is stored: the upstream JSON, unchanged apart from the
    /// normalised name and path.
    pub fn to_json(&self) -> Value {
        json!({
            "version": 1,
            "id": self.id,
            "name": self.name,
            "body": { "path": self.path },
            "eyes": {
                "x": json_number(self.eyes.x),
                "y": json_number(self.eyes.y),
                "spacing": json_number(self.eyes.spacing),
                "scale": json_number(self.eyes.scale),
            },
        })
    }
}

/// A number the way a human writes it in a definition: `1`, not `1.0`.
///
/// `serde_json` keeps `1.0` as a float, so a stored definition would come back as `{"scale": 1.0}`
/// and differ from the text that was pasted in — which matters because the apps compare and cache
/// the JSON, and a round trip that changes its bytes changes its identity too.
fn json_number(value: f64) -> Value {
    if value.fract() == 0.0 && value.abs() < 9.0e15 {
        json!(value as i64)
    } else {
        json!(value)
    }
}

/// Everything wrong with a definition, in the contract's own words.
///
/// A `Vec` rather than one string because the editor shows a list: a paste with a bad eye scale
/// usually also has a bad spacing, and rewriting the sentence twice to see both is how a paste box
/// becomes a guessing game.
pub fn validate(definition: &Value) -> Result<AvatarSpec, Vec<String>> {
    let mut errors: Vec<String> = Vec::new();
    let Some(obj) = definition.as_object() else {
        return Err(vec!["definition must be a JSON object".to_string()]);
    };

    for key in obj.keys() {
        if !TOP_KEYS.contains(&key.as_str()) {
            errors.push(format!(
                "unknown field \"{key}\" (allowed: {})",
                TOP_KEYS.join(", ")
            ));
        }
    }
    if obj.get("version").and_then(Value::as_i64) != Some(1) {
        errors.push("version must be 1".to_string());
    }

    let id = obj.get("id").and_then(Value::as_str).unwrap_or("");
    if !is_slug(id) {
        errors.push("id must be a lowercase slug of 1-40 chars [a-z0-9-]".to_string());
    }
    let name = obj
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if name.is_empty() || name.chars().count() > 40 || name.chars().any(|c| c == '<' || c == '>' || c.is_control()) {
        errors.push("name must be 1-40 printable characters without < or >".to_string());
    }

    let path = match obj.get("body") {
        Some(Value::Object(body)) => {
            for key in body.keys() {
                if key != "path" {
                    errors.push(format!(
                        "unknown field \"body.{key}\" (only \"path\" is allowed)"
                    ));
                }
            }
            match body.get("path").and_then(Value::as_str) {
                Some(path) => Some(path.to_string()),
                None => {
                    errors.push("body.path must be a string".to_string());
                    None
                }
            }
        }
        _ => {
            errors.push("body must be an object { \"path\": \"...\" }".to_string());
            None
        }
    };

    let mut eyes: Option<AvatarEyes> = None;
    match obj.get("eyes") {
        Some(Value::Object(e)) => {
            for key in e.keys() {
                if !EYE_KEYS.contains(&key.as_str()) {
                    errors.push(format!(
                        "unknown field \"eyes.{key}\" (allowed: {})",
                        EYE_KEYS.join(", ")
                    ));
                }
            }
            let numbers: Vec<Option<f64>> = EYE_KEYS.iter().map(|k| e.get(*k).and_then(Value::as_f64)).collect();
            let missing: Vec<&str> = EYE_KEYS
                .iter()
                .zip(numbers.iter())
                .filter(|(_, n)| n.is_none())
                .map(|(k, _)| *k)
                .collect();
            if !missing.is_empty() {
                errors.push(format!(
                    "eyes.{} must be finite numbers",
                    missing.join(", eyes.")
                ));
            } else {
                let parsed = AvatarEyes {
                    x: numbers[0].unwrap(),
                    y: numbers[1].unwrap(),
                    spacing: numbers[2].unwrap(),
                    scale: numbers[3].unwrap(),
                };
                let min_spacing = EYE_W * parsed.scale * 1.75;
                if !(0.6..=1.8).contains(&parsed.scale) {
                    errors.push(format!(
                        "eyes.scale {} out of range 0.6..1.8",
                        round1(parsed.scale)
                    ));
                }
                if parsed.spacing < min_spacing || parsed.spacing > 40.0 {
                    errors.push(format!(
                        "eyes.spacing {} out of range {}..40 for scale {}",
                        round1(parsed.spacing),
                        round1(min_spacing),
                        round1(parsed.scale)
                    ));
                }
                if !(0.0..=100.0).contains(&parsed.x) || !(0.0..=100.0).contains(&parsed.y) {
                    errors.push("eyes.x and eyes.y must be inside the 0 0 100 100 box".to_string());
                }
                eyes = Some(parsed);
            }
        }
        _ => errors.push("eyes must be an object { x, y, spacing, scale }".to_string()),
    }

    // The path's own rules, and the extents it is allowed to occupy.
    let mut body_box: Option<(f64, f64, f64, f64)> = None;
    if let Some(path) = path.as_deref() {
        match path_extents(path) {
            Ok(bounds) => {
                let (min_x, min_y, max_x, max_y) = bounds;
                body_box = Some(bounds);
                let mut outside: Vec<String> = Vec::new();
                if min_x < BODY_MIN {
                    outside.push(format!("left edge x={}", round1(min_x)));
                }
                if min_y < BODY_MIN {
                    outside.push(format!("top edge y={}", round1(min_y)));
                }
                if max_x > BODY_MAX {
                    outside.push(format!("right edge x={}", round1(max_x)));
                }
                if max_y > BODY_MAX {
                    outside.push(format!("bottom edge y={}", round1(max_y)));
                }
                if !outside.is_empty() {
                    errors.push(format!(
                        "body.path leaves the safe area ({}); keep geometry within 8..92",
                        outside.join(", ")
                    ));
                }
                let (width, height) = (max_x - min_x, max_y - min_y);
                if width.max(height) < 40.0 || width.min(height) < 14.0 {
                    errors.push(format!(
                        "body is too small ({}x{}); use at least 40 units on the long side and 14 on the short side",
                        round1(width),
                        round1(height)
                    ));
                }
            }
            Err(reason) => errors.push(format!("body.path: {reason}")),
        }
    }

    // The eyes have to sit inside the body, measured at their own scale.
    if let (Some(eyes), Some((min_x, min_y, max_x, max_y))) = (eyes, body_box) {
        let half_w = eyes.spacing / 2.0 + (EYE_W * eyes.scale) / 2.0;
        let half_h = (EYE_H * eyes.scale) / 2.0;
        if eyes.x - half_w < min_x
            || eyes.x + half_w > max_x
            || eyes.y - half_h < min_y
            || eyes.y + half_h > max_y
        {
            errors.push(
                "eyes must sit inside the body; move eyes.x/eyes.y toward the widest solid area, \
                 reduce spacing or scale"
                    .to_string(),
            );
        }
    }

    if !errors.is_empty() {
        return Err(errors);
    }
    Ok(AvatarSpec {
        id: id.to_string(),
        name,
        path: path.unwrap_or_default(),
        eyes: eyes.expect("eyes validated"),
    })
}

fn round1(n: f64) -> f64 {
    (n * 10.0).round() / 10.0
}

/// `^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$` — upstream's id rule, character by character.
fn is_slug(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes.len() > 40 {
        return false;
    }
    let ok = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-';
    if !ok(bytes[0]) || bytes[0] == b'-' || !ok(bytes[bytes.len() - 1]) || bytes[bytes.len() - 1] == b'-' {
        return false;
    }
    bytes.iter().all(|b| ok(*b))
}

/// The bounding box of a path's absolute points, plus the checks that make a path safe to keep.
///
/// Returns `(min_x, min_y, max_x, max_y)`. This walks the pen the way SVG does — implicit repeats,
/// absolute and relative forms — and takes the box over the points that bound the drawing: move and
/// line ends, curve control points and ends, arc ends. Control points bound their curve, so the box
/// never under-reports; an arc's radii are not coordinates and are left out.
fn path_extents(path: &str) -> Result<(f64, f64, f64, f64), String> {
    if path.trim().is_empty() {
        return Err("path is empty".to_string());
    }
    if path.len() > MAX_PATH_CHARS {
        return Err(format!("path longer than {MAX_PATH_CHARS} characters"));
    }
    if !path.trim_start().starts_with(['M', 'm']) {
        return Err("path must start with M".to_string());
    }
    let chars: Vec<char> = path.chars().collect();
    let mut i = 0usize;
    let (mut pen_x, mut pen_y) = (0.0f64, 0.0f64);
    let (mut start_x, mut start_y) = (0.0f64, 0.0f64);
    let mut subpaths = 0usize;
    let mut points = 0usize;
    let mut box_min = (f64::INFINITY, f64::INFINITY);
    let mut box_max = (f64::NEG_INFINITY, f64::NEG_INFINITY);
    let mut command: Option<char> = None;

    fn read_number(chars: &[char], i: &mut usize) -> Result<f64, String> {
        // A multi-number command ("M20 20", "C… …") separates its numbers with spaces or commas.
        while *i < chars.len() && (chars[*i].is_whitespace() || chars[*i] == ',') {
            *i += 1;
        }
        let start = *i;
        if *i < chars.len() && (chars[*i] == '-' || chars[*i] == '+') {
            *i += 1;
        }
        let digits_from = *i;
        while *i < chars.len() && (chars[*i].is_ascii_digit() || chars[*i] == '.') {
            *i += 1;
        }
        if *i == digits_from {
            return Err("malformed number".to_string());
        }
        if *i < chars.len() && (chars[*i] == 'e' || chars[*i] == 'E') {
            let mark = *i;
            *i += 1;
            if *i < chars.len() && (chars[*i] == '-' || chars[*i] == '+') {
                *i += 1;
            }
            let exp_from = *i;
            while *i < chars.len() && chars[*i].is_ascii_digit() {
                *i += 1;
            }
            if *i == exp_from {
                *i = mark;
            }
        }
        let text: String = chars[start..*i].iter().collect();
        match text.parse::<f64>() {
            Ok(value) if value.is_finite() => Ok(value),
            _ => Err(format!("cannot parse number {text:?}")),
        }
    }

    while i < chars.len() {
        let c = chars[i];
        if c.is_ascii_alphabetic() {
            if !"MmLlHhVvCcSsQqTtAaZz".contains(c) {
                return Err(format!(
                    "unsupported character {c:?} (allowed commands: M L H V C S Q T A Z)"
                ));
            }
            command = Some(c);
            if c.eq_ignore_ascii_case(&'M') {
                subpaths += 1;
            }
            if c.eq_ignore_ascii_case(&'Z') {
                pen_x = start_x;
                pen_y = start_y;
            }
            i += 1;
            continue;
        }
        if c.is_whitespace() || c == ',' {
            i += 1;
            continue;
        }
        let Some(cmd) = command else {
            return Err("path must start with M".to_string());
        };
        let relative = cmd.is_ascii_lowercase();
        let upper = cmd.to_ascii_uppercase();
        let (dx, dy) = if relative { (pen_x, pen_y) } else { (0.0, 0.0) };
        let mut point = |x: f64, y: f64| {
            points += 1;
            box_min.0 = box_min.0.min(x);
            box_min.1 = box_min.1.min(y);
            box_max.0 = box_max.0.max(x);
            box_max.1 = box_max.1.max(y);
        };
        match upper {
            'M' | 'L' | 'T' => {
                let x = read_number(&chars, &mut i)? + dx;
                let y = read_number(&chars, &mut i)? + dy;
                point(x, y);
                pen_x = x;
                pen_y = y;
                if upper == 'M' {
                    start_x = x;
                    start_y = y;
                    // Subsequent pairs are implicit line-tos.
                    command = Some(if relative { 'l' } else { 'L' });
                }
            }
            'H' => {
                let x = read_number(&chars, &mut i)? + dx;
                point(x, pen_y);
                pen_x = x;
            }
            'V' => {
                let y = read_number(&chars, &mut i)? + dy;
                point(pen_x, y);
                pen_y = y;
            }
            'C' => {
                for _ in 0..3 {
                    let x = read_number(&chars, &mut i)? + dx;
                    let y = read_number(&chars, &mut i)? + dy;
                    point(x, y);
                    pen_x = x;
                    pen_y = y;
                }
            }
            'S' | 'Q' => {
                for _ in 0..2 {
                    let x = read_number(&chars, &mut i)? + dx;
                    let y = read_number(&chars, &mut i)? + dy;
                    point(x, y);
                    pen_x = x;
                    pen_y = y;
                }
            }
            'A' => {
                // rx ry rotation large-arc sweep x y: only the end point is a coordinate, and only
                // it is relative.
                let _rx = read_number(&chars, &mut i)?;
                let _ry = read_number(&chars, &mut i)?;
                let _rotation = read_number(&chars, &mut i)?;
                let _large = read_number(&chars, &mut i)?;
                let _sweep = read_number(&chars, &mut i)?;
                let x = read_number(&chars, &mut i)? + dx;
                let y = read_number(&chars, &mut i)? + dy;
                point(x, y);
                pen_x = x;
                pen_y = y;
            }
            _ => return Err(format!("unsupported command {cmd:?}")),
        }
    }
    if subpaths == 0 {
        return Err("path has no move command".to_string());
    }
    if subpaths > MAX_SUBPATHS {
        return Err(format!("path has more than {MAX_SUBPATHS} subpaths"));
    }
    if points < 2 {
        return Err("path has too few coordinates".to_string());
    }
    Ok((box_min.0, box_min.1, box_max.0, box_max.1))
}

/// `#rgb` or `#rrggbb`, the only colours the runtime accepts.
pub fn is_hex_color(value: &str) -> bool {
    let Some(rest) = value.strip_prefix('#') else {
        return false;
    };
    (rest.len() == 3 || rest.len() == 6) && rest.chars().all(|c| c.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn box_definition() -> Value {
        json!({
            "version": 1,
            "id": "box",
            "name": "Box",
            "body": { "path": "M20 20 H80 V80 H20 Z" },
            "eyes": { "x": 50, "y": 46, "spacing": 15, "scale": 1 },
        })
    }

    #[test]
    fn the_contract_example_validates_and_round_trips() {
        let spec = validate(&box_definition()).expect("the docs' example is valid");
        assert_eq!(spec.id, "box");
        assert_eq!(spec.eyes.spacing, 15.0);
        let stored = spec.to_json();
        assert_eq!(stored, box_definition(), "storage keeps the definition unchanged");
        // …and what came back out validates again: the document is idempotent.
        assert!(validate(&stored).is_ok());
    }

    #[test]
    fn a_path_outside_the_box_is_refused_with_the_edge_named() {
        let mut def = box_definition();
        def["body"]["path"] = json!("M2 20 H80 V80 H20 Z");
        let errors = validate(&def).expect_err("x=2 is outside the safe area");
        assert!(errors.iter().any(|e| e.contains("left edge x=2")), "{errors:?}");
    }

    #[test]
    fn eye_fields_are_range_checked() {
        let mut def = box_definition();
        def["eyes"]["scale"] = json!(3);
        let errors = validate(&def).expect_err("scale 3 is out of range");
        assert!(errors.iter().any(|e| e.contains("eyes.scale 3 out of range 0.6..1.8")), "{errors:?}");

        let mut def = box_definition();
        def["eyes"]["spacing"] = json!(2);
        let errors = validate(&def).expect_err("spacing 2 is inside the eye pair");
        assert!(errors.iter().any(|e| e.contains("eyes.spacing 2 out of range")), "{errors:?}");

        let mut def = box_definition();
        def["eyes"]["y"] = json!(120);
        let errors = validate(&def).expect_err("y=120 is outside the box");
        assert!(errors.iter().any(|e| e.contains("inside the 0 0 100 100 box")), "{errors:?}");
    }

    #[test]
    fn eyes_must_sit_inside_the_body() {
        let mut def = box_definition();
        def["eyes"]["x"] = json!(88);
        let errors = validate(&def).expect_err("the eye pair overhangs the right edge");
        assert!(errors.iter().any(|e| e.contains("eyes must sit inside the body")), "{errors:?}");
    }

    #[test]
    fn unknown_fields_and_a_bad_version_are_named() {
        let mut def = box_definition();
        def["colour"] = json!("#ff0000");
        def["version"] = json!(2);
        let errors = validate(&def).expect_err("unknown field and version 2");
        assert!(errors.iter().any(|e| e.contains("unknown field \"colour\"")), "{errors:?}");
        assert!(errors.iter().any(|e| e.contains("version must be 1")), "{errors:?}");
    }

    #[test]
    fn a_path_with_a_script_character_is_refused() {
        let mut def = box_definition();
        def["body"]["path"] = json!("M20 20 H80 <script>");
        let errors = validate(&def).expect_err("markup is not a path");
        assert!(errors.iter().any(|e| e.contains("body.path:")), "{errors:?}");
    }

    #[test]
    fn colours_are_three_or_six_hex_digits() {
        assert!(is_hex_color("#A97EFE"));
        assert!(is_hex_color("#abc"));
        assert!(!is_hex_color("A97EFE"));
        assert!(!is_hex_color("#12345"));
        assert!(!is_hex_color("#gggggg"));
    }
}
