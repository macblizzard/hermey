//! Where this host keeps its `.env`.
//!
//! The keys hermeyd uses for Composio and voice (`HERMEY_COMPOSIO_API_KEY`,
//! `HERMEY_GROQ_API_KEY`, …) live in **the Hermey home's** `.env`, never in the engine's managed
//! env and never in the process environment of a normal install. Two places read it, and both used
//! to *guess* the location the same way: `engine_home.parent().join(".env")`.
//!
//! That guess is only right for the development layout (`var/hermey/engine` next to
//! `var/hermey/.env`). An install whose engine home is `/var/lib/hermes` and whose Hermey home is
//! `/var/lib/hermey` had no env file at all — Composio and voice silently reported "not
//! configured", with nothing in the log naming the file they had looked for.
//!
//! So the resolution is explicit and tolerant, in this order:
//!
//! 1. `$HERMEY_HOME/.env` when `HERMEY_HOME` is set (the documented location);
//! 2. `<engine_home>/.env` (a stock install keeps its `.env` in `HERMES_HOME`);
//! 3. `<engine_home>/../.env` (the old guess; kept for hosts installed before the explicit rule).
//!
//! The first candidate that **exists** wins; when none does, the first candidate is named anyway
//! and an empty string is read. Nothing here can fail: a missing `.env` means "not configured",
//! which every caller already models.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// One resolved location plus enough context for the boot line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub path: PathBuf,
    /// Whether that file is actually there.
    pub exists: bool,
    /// Which rule chose it: `HERMEY_HOME`, `engine home`, or `parent`.
    pub rule: &'static str,
}

/// The candidate list, deduplicated, in the documented order. `None` means that rule does not
/// apply on this host (no `HERMEY_HOME`).
pub fn candidates(engine_home: &Path, hermey_home: Option<&Path>) -> Vec<(&'static str, PathBuf)> {
    let mut out: Vec<(&'static str, PathBuf)> = Vec::new();
    let mut push = |rule: &'static str, path: PathBuf| {
        if !path.as_os_str().is_empty() && !out.iter().any(|(_, seen)| seen == &path) {
            out.push((rule, path));
        }
    };
    if let Some(home) = hermey_home {
        push("HERMEY_HOME", home.join(".env"));
    }
    push("engine home", engine_home.join(".env"));
    if let Some(parent) = engine_home.parent() {
        push("parent", parent.join(".env"));
    }
    out
}

/// Resolve the env file for a given pair of homes. Pure: the test suite drives it with temp dirs.
pub fn select(engine_home: &Path, hermey_home: Option<&Path>) -> Selection {
    let candidates = candidates(engine_home, hermey_home);
    for (rule, path) in &candidates {
        if path.is_file() {
            return Selection {
                path: path.clone(),
                exists: true,
                rule,
            };
        }
    }
    match candidates.into_iter().next() {
        Some((rule, path)) => Selection {
            path,
            exists: false,
            rule,
        },
        // No engine home and no HERMEY_HOME: a relative name is still better than a panic, and the
        // caller reads nothing from it.
        None => Selection {
            path: PathBuf::from(".env"),
            exists: false,
            rule: "cwd",
        },
    }
}

/// The same resolution against this process's environment.
pub fn select_from_process(engine_home: &Path) -> Selection {
    let hermey_home = std::env::var("HERMEY_HOME")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    select(engine_home, hermey_home.as_deref())
}

/// The file's text, or `""` when it is absent or unreadable. The caller treats an empty text as
/// "no keys in the file", which is exactly what a missing file means.
pub fn read_text(engine_home: &Path) -> String {
    let selection = select_from_process(engine_home);
    std::fs::read_to_string(&selection.path).unwrap_or_default()
}

/// The one line boot prints, so the log always names the file that was used — or the first one
/// that was looked for and not found.
pub fn boot_line(selection: &Selection) -> String {
    if selection.exists {
        format!(
            "env: using {} (found via {})",
            selection.path.display(),
            selection.rule
        )
    } else {
        format!(
            "env: no .env at {} (looked via {}); continuing without it",
            selection.path.display(),
            selection.rule
        )
    }
}

/// Print [`boot_line`] once per process. Called from boot; the lazy readers do not log, so a host
/// that never uses Composio or voice still gets exactly one line about its env file.
pub fn log_choice_once(selection: &Selection) {
    static ONCE: OnceLock<()> = OnceLock::new();
    if ONCE.set(()).is_ok() {
        eprintln!("{}", boot_line(selection));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn scratch(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-env-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    /// The documented install: `$HERMEY_HOME/.env` wins even though the engine home also has one.
    #[test]
    fn hermey_home_wins_when_it_is_set() {
        let root = scratch("hermeyhome");
        let hermey = root.join("hermey");
        let engine = hermey.join("engine");
        std::fs::create_dir_all(&engine).unwrap();
        std::fs::write(hermey.join(".env"), b"HERMEY_COMPOSIO_API_KEY=one\n").unwrap();
        std::fs::write(engine.join(".env"), b"HERMEY_COMPOSIO_API_KEY=two\n").unwrap();

        let chosen = select(&engine, Some(&hermey));
        assert_eq!(chosen.path, hermey.join(".env"));
        assert_eq!(chosen.rule, "HERMEY_HOME");
        assert!(chosen.exists);
        let line = boot_line(&chosen);
        assert!(line.contains(&hermey.join(".env").display().to_string()), "{line}");
        assert!(line.contains("HERMEY_HOME"), "{line}");
        assert!(!line.contains("no .env"), "{line}");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Without HERMEY_HOME, a stock install's own `<engine_home>/.env` is next — not the parent's.
    #[test]
    fn engine_home_is_second() {
        let root = scratch("enginehome");
        let engine = root.join("hermes");
        std::fs::create_dir_all(&engine).unwrap();
        std::fs::write(engine.join(".env"), b"HERMEY_GROQ_API_KEY=g\n").unwrap();

        let chosen = select(&engine, None);
        assert_eq!(chosen.path, engine.join(".env"));
        assert_eq!(chosen.rule, "engine home");
        assert!(chosen.exists);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The old layout, and the only case the previous guess got right: `<engine_home>/../.env`.
    #[test]
    fn the_parent_is_the_last_existing_candidate() {
        let root = scratch("parent");
        let engine = root.join("hermey").join("engine");
        std::fs::create_dir_all(&engine).unwrap();
        std::fs::write(root.join("hermey").join(".env"), b"HERMEY_GROQ_API_KEY=p\n").unwrap();

        let chosen = select(&engine, None);
        assert_eq!(chosen.path, root.join("hermey").join(".env"));
        assert_eq!(chosen.rule, "parent");
        assert!(chosen.exists);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Nothing on disk is a normal state, not an error: the line names the file that was looked
    /// for, and the read is empty.
    #[test]
    fn a_missing_file_is_named_and_reads_empty() {
        let root = scratch("missing");
        let hermey = root.join("hermey");
        let engine = hermey.join("engine");
        std::fs::create_dir_all(&engine).unwrap();

        let chosen = select(&engine, Some(&hermey));
        assert_eq!(chosen.path, hermey.join(".env"));
        assert!(!chosen.exists);
        let line = boot_line(&chosen);
        assert!(line.contains("no .env at"), "{line}");
        assert!(line.contains(&hermey.join(".env").display().to_string()), "{line}");
        assert!(line.contains("continuing without it"), "{line}");
        assert_eq!(std::fs::read_to_string(&chosen.path).unwrap_or_default(), "");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The rules are ordered and deduplicated: `HERMEY_HOME == engine_home.parent()` (the
    /// development layout) must not appear twice, so the log line cannot be ambiguous.
    #[test]
    fn candidates_are_ordered_and_deduplicated() {
        let root = scratch("dedupe");
        let hermey = root.join("hermey");
        let engine = hermey.join("engine");
        std::fs::create_dir_all(&engine).unwrap();

        let rules: Vec<&str> = candidates(&engine, Some(&hermey))
            .into_iter()
            .map(|(rule, _)| rule)
            .collect();
        assert_eq!(rules, vec!["HERMEY_HOME", "engine home"]);

        let rules: Vec<&str> = candidates(&engine, None)
            .into_iter()
            .map(|(rule, _)| rule)
            .collect();
        assert_eq!(rules, vec!["engine home", "parent"]);
        let _ = std::fs::remove_dir_all(&root);
    }
}
