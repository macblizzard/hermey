//! Bundled agent skills: the instructions that make a capability *real* for a bot.
//!
//! Port of `hermes_bridge/agent_skills.py`. A bot that cannot see how to reach the owner's Mac will
//! try SSH and fail, so the capability only exists if the **instructions** are present too. The
//! bridge used to be the only thing that wrote them; on a host where hermeyd is the only service
//! left, every bot was blind to the Mac, to its own desktop screen, to sign-in cards and to the
//! owner's connected accounts, with nothing in the log saying so.
//!
//! What this module does, mirroring the Python one:
//!
//! 1. **Materialises the scripts** next to this service's state (`<state>/bin/*.py`), mode `0755`.
//!    The skills' examples call them by absolute path, so the path must survive the install.
//! 2. **Renders each `SKILL.md`** with that absolute CLI path, its directory, and this service's
//!    loopback URL baked in — no placeholder ever reaches a bot.
//! 3. **Writes it where bots load skills**: the shared skills dir when the engine is configured with
//!    one, otherwise the engine home's shared root plus every profile's own `skills/` directory
//!    (`skills.manage list` enumerates the profile's own tree, so the per-profile copies are what
//!    put the rows on the Skills page).
//!
//! The safety story is the `managed_by:` marker in the frontmatter, exactly as in the bridge:
//!
//! * a skill of the same name **without** it belongs to the owner and is never touched;
//! * a file **with** it is ours: a changed template replaces it, and the text that was there is
//!   kept beside it as `SKILL.md.previous` (a bot's hand edit is never silently destroyed);
//! * identical content is left completely alone, which is what makes every boot a no-op.
//!
//! Everything is embedded (`include_str!`/`include_bytes!`): a deployed hermeyd must not depend on
//! a source checkout, and the bridge's own installer deletes its checkout.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// The skill whose row Settings → Computer is about. Every bundled skill is installed; this one is
/// the primary in the install report, as in the bridge.
pub const SKILL_NAME: &str = "mac-local-computer";

/// Frontmatter line that marks a file as ours to update. Absence of it means "hands off".
///
/// Deliberately the bridge's marker rather than a new one: a host that has run both services must
/// not see its own files become "foreign" (and therefore frozen at an old template) when the other
/// service writes next.
pub const MANAGED_MARKER: &str = "managed_by: hermey-bridge";

pub const CLI_PLACEHOLDER: &str = "@@CLI@@";
pub const BIN_PLACEHOLDER: &str = "@@BIN@@";
/// Base URL of the main API (device-authenticated routes), e.g. `http://127.0.0.1:8788`.
pub const API_PLACEHOLDER: &str = "@@API@@";
/// Base URL of the browser channel (`/v1/browser/*`), e.g. `http://127.0.0.1:8790`.
pub const BROWSER_PLACEHOLDER: &str = "@@BROWSER@@";
/// Absolute path of the local bearer the scripts read, e.g. `<state>/local.token`.
pub const TOKEN_FILE_PLACEHOLDER: &str = "@@TOKEN_FILE@@";

/// The script every "run something on the Mac" instruction in the Mac skill goes through.
pub const CLI_SCRIPT: &str = "local_computer.py";

/// What a host that cannot write the scripts is told inside a template that only names siblings.
const NO_SCRIPTS_NOTE: &str = "(the bundled scripts are not installed on this host)";

/// One bundled skill: its directory name (also the name Hermes shows) and its template.
pub struct Skill {
    pub name: &'static str,
    pub template: &'static str,
}

/// One bundled script, installed beside the CLI so a skill can name a sibling of it.
pub struct Script {
    pub name: &'static str,
    pub bytes: &'static [u8],
}

/// Every skill hermeyd bundles, each a directory under `assets/agent-skills/`.
///
/// One instruction is not enough: the Mac skill teaches a bot how to drive the owner's laptop, and
/// `bot-desktop` teaches it which X display is its own. A bot with only the first lands on whatever
/// display it finds — on this host a bot picked the owner's personal `:10` session, opened a
/// browser there, exited 0 and reported success, while the owner's viewer showed an empty screen.
pub const BUNDLED_SKILLS: &[Skill] = &[
    Skill {
        name: SKILL_NAME,
        template: include_str!("../assets/agent-skills/mac-local-computer/SKILL.md"),
    },
    Skill {
        name: "bot-desktop",
        template: include_str!("../assets/agent-skills/bot-desktop/SKILL.md"),
    },
    Skill {
        name: "signin",
        template: include_str!("../assets/agent-skills/signin/SKILL.md"),
    },
    Skill {
        name: "integrations",
        template: include_str!("../assets/agent-skills/integrations/SKILL.md"),
    },
    // Cards are the only way a question renders in the native apps: `clarify` draws on Hermes Desktop
    // and nowhere else, so a bot that asks in prose is a bot the owner cannot answer.
    Skill {
        name: "agent-cards",
        template: include_str!("../assets/agent-skills/agent-cards/SKILL.md"),
    },
];

/// Every script the bundled skills name, byte for byte as the bridge ships it.
pub const BUNDLED_SCRIPTS: &[Script] = &[
    Script {
        name: CLI_SCRIPT,
        bytes: include_bytes!("../assets/agent-skills/bin/local_computer.py"),
    },
    Script {
        name: "hermey_browser.py",
        bytes: include_bytes!("../assets/agent-skills/bin/hermey_browser.py"),
    },
    Script {
        name: "hermey_desktop.py",
        bytes: include_bytes!("../assets/agent-skills/bin/hermey_desktop.py"),
    },
    Script {
        name: "hermey_integrations.py",
        bytes: include_bytes!("../assets/agent-skills/bin/hermey_integrations.py"),
    },
    Script {
        name: "hermey_signin.py",
        bytes: include_bytes!("../assets/agent-skills/bin/hermey_signin.py"),
    },
];

/// What happened to one skill in one target directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The file was created or replaced (a changed template, or the first install).
    Written,
    /// Identical content was already there; nothing was written.
    Current,
    /// A skill by that name exists without our marker: the owner's, left exactly as it is.
    Foreign,
    /// This host cannot host the skill (its `platforms:` list excludes the OS).
    PlatformSkipped,
    /// The template needs the local-computer CLI and this host could not write it.
    NoCli,
    /// The write failed; the reason is kept for the log and the route's answer.
    Failed(String),
}

impl Outcome {
    /// The lowercase token used in the log line and the JSON answer.
    pub fn as_str(&self) -> &str {
        match self {
            Outcome::Written => "written",
            Outcome::Current => "current",
            Outcome::Foreign => "foreign",
            Outcome::PlatformSkipped => "platform-skipped",
            Outcome::NoCli => "no-cli",
            Outcome::Failed(_) => "failed",
        }
    }
}

/// One skill's result in one target directory.
#[derive(Debug, Clone)]
pub struct SkillResult {
    pub name: &'static str,
    pub outcome: Outcome,
}

/// Everything that happened in one target directory. `profile` is the directory's name, or
/// `shared` for the engine's shared skills root.
#[derive(Debug, Clone, Default)]
pub struct ProfileReport {
    pub profile: String,
    pub dir: PathBuf,
    pub results: Vec<SkillResult>,
}

impl ProfileReport {
    /// How many skills ended in this state. `Outcome::Failed` matches whatever reason it carries.
    pub fn count(&self, outcome: &Outcome) -> usize {
        self.results
            .iter()
            .filter(|r| same_kind(&r.outcome, outcome))
            .count()
    }

    /// `written=2 current=2 skipped_platform=none user_owned=none failed=none` — the one shape both
    /// the log line and the route's answer use, so a reader can compare them.
    pub fn summary(&self) -> String {
        format!(
            "written={} current={} skipped_platform={} user_owned={} no_cli={} failed={}",
            self.count(&Outcome::Written),
            self.count(&Outcome::Current),
            list(&self.results, "platform-skipped"),
            list(&self.results, "foreign"),
            list(&self.results, "no-cli"),
            list(&self.results, "failed"),
        )
    }
}

/// `Outcome::Failed` carries a reason, so equality would compare the message rather than the state.
fn same_kind(a: &Outcome, b: &Outcome) -> bool {
    matches!(
        (a, b),
        (Outcome::Failed(_), Outcome::Failed(_))
            | (Outcome::Written, Outcome::Written)
            | (Outcome::Current, Outcome::Current)
            | (Outcome::Foreign, Outcome::Foreign)
            | (Outcome::PlatformSkipped, Outcome::PlatformSkipped)
            | (Outcome::NoCli, Outcome::NoCli)
    )
}

fn list(results: &[SkillResult], token: &str) -> String {
    let names: Vec<&str> = results
        .iter()
        .filter(|r| r.outcome.as_str() == token)
        .map(|r| r.name)
        .collect();
    if names.is_empty() {
        "none".to_string()
    } else {
        names.join(",")
    }
}

/// The whole install: scripts, then every target directory.
#[derive(Debug, Clone, Default)]
pub struct Report {
    pub cli: Option<PathBuf>,
    pub scripts_written: usize,
    pub script_error: Option<String>,
    pub profiles: Vec<ProfileReport>,
}

impl Report {
    pub fn written(&self) -> usize {
        self.profiles.iter().map(|p| p.count(&Outcome::Written)).sum()
    }

    pub fn current(&self) -> usize {
        self.profiles.iter().map(|p| p.count(&Outcome::Current)).sum()
    }

    /// Targets where at least one skill could not be written.
    pub fn failed(&self) -> Vec<String> {
        self.profiles
            .iter()
            .filter(|p| p.count(&Outcome::Failed(String::new())) > 0)
            .map(|p| p.profile.clone())
            .collect()
    }

    /// The primary skill's target directories — what the bridge's `installed` answer means.
    pub fn installed(&self) -> Vec<String> {
        self.profiles
            .iter()
            .filter(|p| {
                p.results
                    .iter()
                    .any(|r| r.name == SKILL_NAME && matches!(r.outcome, Outcome::Written | Outcome::Current))
            })
            .map(|p| p.dir.to_string_lossy().to_string())
            .collect()
    }

    /// `{skill: {dir, outcome}}` for the primary skill, keyed as the app's row expects.
    pub fn skill_outcomes(&self) -> serde_json::Map<String, serde_json::Value> {
        let mut out = serde_json::Map::new();
        for profile in &self.profiles {
            for result in &profile.results {
                out.insert(
                    result.name.to_string(),
                    serde_json::json!({
                        "outcome": result.outcome.as_str(),
                        "dir": profile.dir.to_string_lossy(),
                        "profile": profile.profile,
                        "error": match &result.outcome {
                            Outcome::Failed(e) => Some(e.clone()),
                            _ => None,
                        },
                    }),
                );
            }
        }
        out
    }
}

// ---- platform gating ---------------------------------------------------------------------------

/// This host's OS, in `std::env::consts::OS` terms (`linux`, `macos`, `windows`).
pub fn host_os() -> &'static str {
    std::env::consts::OS
}

/// `sys.platform`-style name, so a template's `platforms:` list means the same thing here as in the
/// engine (`macos` → `darwin`, `windows` → `win32`, otherwise the name itself).
fn sys_platform(host_os: &str) -> String {
    match host_os {
        "macos" | "osx" | "mac" => "darwin".to_string(),
        "windows" | "win" => "win32".to_string(),
        other => other.to_string(),
    }
}

fn mapped_platform(declared: &str) -> String {
    match declared.trim().to_lowercase().as_str() {
        "macos" | "osx" | "mac" => "darwin".to_string(),
        "windows" | "win" => "win32".to_string(),
        other => other.to_string(),
    }
}

/// The skill's frontmatter as a mapping (empty when it has none, or is not valid YAML).
fn frontmatter(text: &str) -> serde_yaml::Value {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let Some(rest) = text.strip_prefix("---") else {
        return serde_yaml::Value::Null;
    };
    let rest = rest.trim_start_matches(['\r', '\n']);
    let Some(end) = rest.find("\n---") else {
        return serde_yaml::Value::Null;
    };
    serde_yaml::from_str(&rest[..end]).unwrap_or(serde_yaml::Value::Null)
}

/// Whether this host may receive the skill.
///
/// The gate is the template's own `platforms:` list — the same field the engine reads when it builds
/// its skill index (`agent/skill_utils.py::skill_matches_platform_list`): absent or empty means every
/// platform. Writing a skill the engine will then hide would be the worst of both worlds: the app
/// reports an install, the bot never sees the row.
pub fn applies_on(template: &str, host_os: &str) -> bool {
    let front = frontmatter(template);
    let declared = match front.get("platforms") {
        None | Some(serde_yaml::Value::Null) => return true,
        Some(serde_yaml::Value::Sequence(items)) if items.is_empty() => return true,
        Some(value) => value.clone(),
    };
    let current = sys_platform(host_os);
    let mut wanted: Vec<String> = Vec::new();
    match declared {
        serde_yaml::Value::Sequence(items) => {
            for item in items {
                if let Some(text) = item.as_str() {
                    wanted.push(text.to_string());
                }
            }
        }
        serde_yaml::Value::String(text) => wanted.push(text),
        _ => return true,
    }
    wanted
        .iter()
        .any(|platform| current.starts_with(&mapped_platform(platform)))
}

/// The `version:` line of a template's frontmatter, for the app to show next to the row.
///
/// `1.0.0` is a string in YAML, but `1.0` is a number: both are answered as text so a template that
/// writes a bare decimal does not report an empty version.
pub fn version(template: &str) -> String {
    match frontmatter(template).get("version") {
        Some(serde_yaml::Value::String(text)) => text.clone(),
        Some(serde_yaml::Value::Number(number)) => number.to_string(),
        _ => String::new(),
    }
}

// ---- rendering ---------------------------------------------------------------------------------

/// Where a bot's shell reaches this host, baked into every rendered skill.
///
/// A hermeyd-only host has **two** listeners, and conflating them is what made the scripts useless:
/// `/v1/browser/*` lives on the browser channel (8788's `HERMEYD_BROWSER_PORT`, 8790) and needs no
/// device credential, while everything the scripts otherwise call — credentials, integrations,
/// local computers — is on the main API and does. The scripts resolve these themselves (they are
/// installed verbatim); the values here are what the skills' prose and `curl` examples use.
#[derive(Debug, Clone)]
pub struct Endpoints {
    pub api: String,
    pub browser: String,
    pub token_file: PathBuf,
}

impl Endpoints {
    /// From the same environment the listeners read, so a moved port is not a stale instruction.
    /// The browser channel always binds `127.0.0.1` (see `main.rs`), whatever `HERMEYD_BIND` says.
    pub fn from_env(bind: &str, api_port: u16, browser_port: u16, token_file: PathBuf) -> Self {
        Self {
            api: loopback_url(bind, api_port),
            browser: format!("http://127.0.0.1:{browser_port}"),
            token_file,
        }
    }

    /// The same thing, read straight from this process's environment. Used by the reinstall route,
    /// which has no copy of the listener variables.
    pub fn from_process_env(state_home: &Path) -> Self {
        let bind = std::env::var("HERMEYD_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());
        let port = std::env::var("HERMEYD_PORT")
            .ok()
            .and_then(|v| v.parse::<u16>().ok())
            .unwrap_or(8788);
        let browser = std::env::var("HERMEYD_BROWSER_PORT")
            .ok()
            .and_then(|v| v.parse::<u16>().ok())
            .unwrap_or(8790);
        Self::from_env(&bind, port, browser, crate::local_token::token_path(state_home))
    }
}

/// Whether a template is only meaningful with the local-computer CLI path in it.
///
/// The Mac skill is: every command in it is that CLI. The desktop and sign-in skills name siblings
/// of it instead, so a host that cannot write the CLI must still receive them — the capabilities are
/// separate and one failing must not silently withhold the other.
pub fn needs_cli(skill: &Skill) -> bool {
    skill.template.contains(CLI_PLACEHOLDER)
}

/// The skill text with this host's paths substituted.
///
/// The substitutions are shared by every bundled skill, so a template that does not use one is left
/// exactly as written rather than needing a second renderer.
pub fn render(skill: &Skill, cli: Option<&Path>, endpoints: &Endpoints) -> String {
    let mut body = skill.template.to_string();
    match cli {
        Some(path) => {
            body = body.replace(CLI_PLACEHOLDER, &path.to_string_lossy());
            let bin = path.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
            body = body.replace(BIN_PLACEHOLDER, &bin);
        }
        None => {
            // A host that cannot write the scripts still gets this skill — the separation the owner
            // asked for. The command cannot work there, so say that rather than leaving a literal
            // placeholder in a bot's instructions and letting it run "<placeholder>/hermey_desktop.py".
            body = body.replace(BIN_PLACEHOLDER, NO_SCRIPTS_NOTE);
        }
    }
    body.replace(API_PLACEHOLDER, &endpoints.api)
        .replace(BROWSER_PLACEHOLDER, &endpoints.browser)
        .replace(TOKEN_FILE_PLACEHOLDER, &endpoints.token_file.to_string_lossy())
}

// ---- writing -----------------------------------------------------------------------------------

/// 0644: a skill is read by every agent process on the host, and an atomic write lands 0600.
/// Not a failure if it cannot be done — the mode is a convenience, the content is the point.
fn relax_mode(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644));
    }
    #[cfg(not(unix))]
    let _ = path;
}

fn set_mode(path: &Path, mode: u32) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
}

/// Write via a temp file in the same directory and rename, so a reader never sees half a skill and
/// a crash mid-install cannot leave one.
fn atomic_write(path: &Path, bytes: &[u8], mode: u32) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "skill".to_string());
    let tmp = parent.join(format!(
        ".{name}.{}.{}.tmp",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    if let Err(e) = std::fs::write(&tmp, bytes) {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("{}: {e}", tmp.display()));
    }
    set_mode(&tmp, mode);
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("{}: {e}", path.display()));
    }
    Ok(())
}

fn read_text(path: &Path) -> Option<String> {
    std::fs::read(path)
        .ok()
        .map(|bytes| String::from_utf8_lossy(&bytes).to_string())
}

/// The file's text, `None` when it does not exist, and an error when it exists but cannot be read —
/// "cannot read it" is not permission to replace it (the bridge answers `failed` there too).
fn read_existing(path: &Path) -> Result<Option<String>, String> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(String::from_utf8_lossy(&bytes).to_string())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

/// Write one copy. Returns `written` / `current` / `foreign` / `failed: …`.
///
/// `foreign` is a real answer, not a failure: the owner has a skill by that name, so their file stays
/// exactly as it is and this install leaves it alone. A file carrying our marker is ours to refresh;
/// what was in it is preserved as `SKILL.md.previous` first, because a bot's hand edit is never
/// silently destroyed.
pub fn write_skill(root: &Path, name: &str, body: &str) -> Outcome {
    let dir = root.join(name);
    let path = dir.join("SKILL.md");
    let existing = match read_existing(&path) {
        Ok(existing) => existing,
        Err(e) => return Outcome::Failed(e),
    };
    if let Some(existing) = existing {
        if existing == body {
            relax_mode(&path); // an install that predates this may still be 0600
            return Outcome::Current;
        }
        if !existing.contains(MANAGED_MARKER) {
            return Outcome::Foreign;
        }
        let previous = dir.join("SKILL.md.previous");
        if let Err(e) = atomic_write(&previous, existing.as_bytes(), 0o644) {
            return Outcome::Failed(e);
        }
        relax_mode(&previous);
    }
    match atomic_write(&path, body.as_bytes(), 0o644) {
        Ok(()) => {
            relax_mode(&path);
            Outcome::Written
        }
        Err(e) => Outcome::Failed(e),
    }
}

/// Put every bundled script at `<state_home>/bin` and hand back the CLI's path.
///
/// `<state>` is the one writable, non-temporary directory this process owns (the systemd unit allows
/// it by name), so it is the only place a bot on an installed host can rely on. Identical content is
/// left untouched; `0755` is applied either way, because a script that lost its mode must still be
/// runnable.
pub fn install_scripts(state_home: &Path) -> Result<(PathBuf, usize), String> {
    let bin = state_home.join("bin");
    std::fs::create_dir_all(&bin).map_err(|e| format!("{}: {e}", bin.display()))?;
    let mut written = 0usize;
    for script in BUNDLED_SCRIPTS {
        let target = bin.join(script.name);
        let existing = std::fs::read(&target).ok();
        if existing.as_deref() != Some(script.bytes) {
            atomic_write(&target, script.bytes, 0o755)?;
            written += 1;
        }
        set_mode(&target, 0o755);
    }
    Ok((bin.join(CLI_SCRIPT), written))
}

/// Install every bundled skill into one target directory (`<profile>/skills`).
///
/// Never returns an error: one skill failing is one line in the report, not a stopped install. A
/// target directory that does not exist yet is created — a bot profile created after this service
/// started must still be able to get its instructions.
pub fn install_into(
    root: &Path,
    skills: &[Skill],
    host_os: &str,
    cli: Option<&Path>,
    endpoints: &Endpoints,
) -> Vec<SkillResult> {
    let mut results = Vec::with_capacity(skills.len());
    for skill in skills {
        let outcome = if !applies_on(skill.template, host_os) {
            Outcome::PlatformSkipped
        } else if cli.is_none() && needs_cli(skill) {
            Outcome::NoCli
        } else {
            write_skill(root, skill.name, &render(skill, cli, endpoints))
        };
        results.push(SkillResult {
            name: skill.name,
            outcome,
        });
    }
    results
}

// ---- target resolution -------------------------------------------------------------------------

fn expand_home(raw: &str) -> PathBuf {
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(raw)
}

/// `skills.external_dirs` out of the engine's config, when it has one.
///
/// A configured shared dir serves every profile at once, so writing the same file into twenty profile
/// dirs as well would only give the next reader twenty copies to keep in step.
fn external_dirs(config: &Path) -> Vec<PathBuf> {
    let Some(text) = read_text(config) else {
        return Vec::new();
    };
    let parsed: serde_yaml::Value = match serde_yaml::from_str(&text) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };
    let Some(list) = parsed
        .get("skills")
        .and_then(|skills| skills.get("external_dirs"))
    else {
        return Vec::new();
    };
    let mut out = Vec::new();
    match list {
        serde_yaml::Value::Sequence(items) => {
            for item in items {
                if let Some(text) = item.as_str() {
                    out.push(expand_home(text));
                }
            }
        }
        serde_yaml::Value::String(one) => out.push(expand_home(one)),
        _ => {}
    }
    out
}

/// Every place a bot may load a skill from: `(label, skills root)`.
///
/// Order matters and mirrors the bridge: an explicit `HERMES_SKILLS_DIR`, then the engine's
/// `skills.external_dirs`, then — the stock install, and this host — the engine home's shared root
/// followed by every profile's own `skills/` directory.
pub fn targets(engine_home: &Path) -> Vec<(String, PathBuf)> {
    if let Ok(explicit) = std::env::var("HERMES_SKILLS_DIR") {
        if !explicit.trim().is_empty() {
            return vec![("shared".to_string(), expand_home(explicit.trim()))];
        }
    }
    let configured = external_dirs(&engine_home.join("config.yaml"));
    if !configured.is_empty() {
        return configured
            .into_iter()
            .map(|dir| ("shared".to_string(), dir))
            .collect();
    }

    let mut out = vec![("shared".to_string(), engine_home.join("skills"))];
    let profiles = engine_home.join("profiles");
    let mut names: Vec<String> = std::fs::read_dir(&profiles)
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .filter(|entry| entry.file_type().map(|t| t.is_dir()).unwrap_or(false))
                .map(|entry| entry.file_name().to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    for name in names {
        out.push((name.clone(), profiles.join(&name).join("skills")));
    }
    out
}

/// The loopback URL a bot's shell should reach this service on.
///
/// The bind address may be `localhost` or `::1`; the CLI needs something it can dial, so the
/// wildcard-ish names are answered with the loopback literal they mean.
pub fn loopback_url(bind: &str, port: u16) -> String {
    if bind.trim() == "::1" {
        format!("http://[::1]:{port}")
    } else {
        format!("http://127.0.0.1:{port}")
    }
}

// ---- the install -------------------------------------------------------------------------------

/// Make every bundled skill available to every bot on this host.
///
/// Called on every boot, so it must be safe to repeat: identical content is left untouched, and a
/// changed template is picked up on the next start (a template update ships with the binary).
///
/// Best effort on purpose, exactly as in the bridge: a skills directory this process cannot write
/// must not stop the service from serving, and the next start simply tries again.
pub fn install(
    engine_home: &Path,
    state_home: &Path,
    host_os: &str,
    endpoints: &Endpoints,
) -> Report {
    let mut report = Report::default();
    match install_scripts(state_home) {
        Ok((cli, written)) => {
            report.cli = Some(cli);
            report.scripts_written = written;
        }
        Err(e) => {
            // Recorded, not fatal: only the skills that actually run that CLI are held back.
            eprintln!("skills: bundled scripts could not be written: {e}");
            report.script_error = Some(e);
        }
    }

    let cli = report.cli.clone();
    for (label, root) in targets(engine_home) {
        let results = install_into(&root, BUNDLED_SKILLS, host_os, cli.as_deref(), endpoints);
        let profile = ProfileReport {
            profile: label,
            dir: root,
            results,
        };
        // One line per target, naming it: "written=0 current=4" on every boot is the healthy case,
        // and a target that lost its skills shows up as written=4 with no other explanation needed.
        eprintln!(
            "skills: {} {} ({})",
            profile.profile,
            profile.summary(),
            profile.dir.display()
        );
        report.profiles.push(profile);
    }

    eprintln!(
        "skills: {} targets, {} written, {} already current, cli={} ({} script(s) written){}",
        report.profiles.len(),
        report.written(),
        report.current(),
        report
            .cli
            .as_ref()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| "unavailable".to_string()),
        report.scripts_written,
        if report.failed().is_empty() {
            String::new()
        } else {
            format!(", FAILED in {}", report.failed().join(","))
        }
    );
    report
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-skills-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    /// What a hermeyd-only host bakes into every skill: the API, the browser channel, the bearer.
    fn endpoints() -> Endpoints {
        Endpoints {
            api: "http://127.0.0.1:8788".to_string(),
            browser: "http://127.0.0.1:8790".to_string(),
            token_file: PathBuf::from("/var/lib/hermey/local.token"),
        }
    }

    fn outcome<'a>(results: &'a [SkillResult], name: &str) -> &'a Outcome {
        &results
            .iter()
            .find(|r| r.name == name)
            .unwrap_or_else(|| panic!("no result for {name}"))
            .outcome
    }

    /// A skill that declares itself macOS-only, as a template in the bot's own frontmatter would.
    const MAC_ONLY: Skill = Skill {
        name: "apple-notes",
        template: "---\nname: apple-notes\ndescription: \"Manage Apple Notes.\"\nversion: 1.0.1\nplatforms: [macos]\nmanaged_by: hermey-bridge\n---\n\n# Apple Notes\n",
    };

    #[test]
    fn install_into_an_empty_dir_writes_every_applicable_skill() {
        let root = scratch("empty");
        let cli = root.join("bin").join(CLI_SCRIPT);
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, b"#!/usr/bin/env python3\n").unwrap();

        let results = install_into(&root.join("skills"), BUNDLED_SKILLS, "linux", Some(&cli), &endpoints());

        assert_eq!(results.len(), BUNDLED_SKILLS.len());
        for result in &results {
            assert_eq!(result.outcome, Outcome::Written, "{} was not written", result.name);
            let path = root.join("skills").join(result.name).join("SKILL.md");
            assert!(path.is_file(), "{} missing", path.display());
        }
        let dir = root.join("skills");
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn second_install_is_a_no_op() {
        let root = scratch("noop");
        let cli = root.join("bin").join(CLI_SCRIPT);
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, b"#!/usr/bin/env python3\n").unwrap();
        let skills = root.join("skills");

        let first = install_into(&skills, BUNDLED_SKILLS, "linux", Some(&cli), &endpoints());
        assert_eq!(first.iter().filter(|r| r.outcome == Outcome::Written).count(), BUNDLED_SKILLS.len());
        let watched = skills.join(SKILL_NAME).join("SKILL.md");
        let before = std::fs::metadata(&watched).unwrap().modified().unwrap();
        let bytes_before = std::fs::read(&watched).unwrap();

        std::thread::sleep(std::time::Duration::from_millis(20));
        let second = install_into(&skills, BUNDLED_SKILLS, "linux", Some(&cli), &endpoints());

        assert!(second.iter().all(|r| r.outcome == Outcome::Current), "{second:?}");
        assert_eq!(std::fs::metadata(&watched).unwrap().modified().unwrap(), before);
        assert_eq!(std::fs::read(&watched).unwrap(), bytes_before);
        assert!(!skills.join(SKILL_NAME).join("SKILL.md.previous").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn macos_only_skill_is_not_installed_on_linux() {
        let root = scratch("platform");
        let cli = root.join("bin").join(CLI_SCRIPT);
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, b"#!/usr/bin/env python3\n").unwrap();
        let skills = root.join("skills");
        let bundle = [MAC_ONLY];

        let on_linux = install_into(&skills, &bundle, "linux", Some(&cli), &endpoints());
        assert_eq!(outcome(&on_linux, "apple-notes"), &Outcome::PlatformSkipped);
        assert!(!skills.join("apple-notes").join("SKILL.md").exists());

        let on_mac = install_into(&skills, &bundle, "macos", Some(&cli), &endpoints());
        assert_eq!(outcome(&on_mac, "apple-notes"), &Outcome::Written);
        assert!(skills.join("apple-notes").join("SKILL.md").is_file());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_skill_without_our_marker_is_never_touched() {
        let root = scratch("foreign");
        let ours_dir = root.join("skills");
        let theirs = ours_dir.join(SKILL_NAME);
        std::fs::create_dir_all(&theirs).unwrap();
        let body = "---\nname: mac-local-computer\ndescription: mine\n---\n\n# my own instructions\n";
        std::fs::write(theirs.join("SKILL.md"), body).unwrap();
        let cli = root.join("bin").join(CLI_SCRIPT);
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, b"#!/usr/bin/env python3\n").unwrap();

        let results = install_into(&ours_dir, BUNDLED_SKILLS, "linux", Some(&cli), &endpoints());

        assert_eq!(outcome(&results, SKILL_NAME), &Outcome::Foreign);
        assert_eq!(std::fs::read_to_string(theirs.join("SKILL.md")).unwrap(), body);
        assert!(!theirs.join("SKILL.md.previous").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_managed_skill_is_refreshed_and_the_old_text_kept() {
        // The bridge's semantics, matched deliberately: our marker means the bundled template wins;
        // the text that was there is kept beside it rather than silently destroyed. No version
        // comparison happens — an equal-content check is what makes a re-run a no-op.
        let root = scratch("managed");
        let dir = root.join("skills").join(SKILL_NAME);
        std::fs::create_dir_all(&dir).unwrap();
        let old = "---\nname: mac-local-computer\nversion: 0.9.0\nmanaged_by: hermey-bridge\n---\n\nold instructions\n";
        std::fs::write(dir.join("SKILL.md"), old).unwrap();
        let cli = root.join("bin").join(CLI_SCRIPT);
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, b"#!/usr/bin/env python3\n").unwrap();

        let results = install_into(&root.join("skills"), BUNDLED_SKILLS, "linux", Some(&cli), &endpoints());

        assert_eq!(outcome(&results, SKILL_NAME), &Outcome::Written);
        assert_eq!(std::fs::read_to_string(dir.join("SKILL.md.previous")).unwrap(), old);
        let now = std::fs::read_to_string(dir.join("SKILL.md")).unwrap();
        assert!(now.contains("http://127.0.0.1:8788"), "API URL not rendered");
        for placeholder in [CLI_PLACEHOLDER, BIN_PLACEHOLDER, API_PLACEHOLDER,
                            BROWSER_PLACEHOLDER, TOKEN_FILE_PLACEHOLDER] {
            assert!(!now.contains(placeholder), "{placeholder} survived rendering");
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_missing_profile_directory_is_created() {
        let root = scratch("missing");
        let profile = root.join("profiles").join("newbot");
        assert!(!profile.exists());
        let cli = root.join("bin").join(CLI_SCRIPT);
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, b"#!/usr/bin/env python3\n").unwrap();

        let results = install_into(&profile.join("skills"), BUNDLED_SKILLS, "linux", Some(&cli), &endpoints());

        assert_eq!(results.len(), BUNDLED_SKILLS.len());
        assert!(profile.join("skills").join(SKILL_NAME).join("SKILL.md").is_file());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn scripts_land_executable_beside_the_cli_and_render_their_path() {
        let root = scratch("scripts");
        let (cli, written) = install_scripts(&root).expect("scripts installed");

        assert_eq!(written, BUNDLED_SCRIPTS.len());
        assert_eq!(cli, root.join("bin").join(CLI_SCRIPT));
        assert!(cli.is_file());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for script in BUNDLED_SCRIPTS {
                let mode = std::fs::metadata(root.join("bin").join(script.name))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777;
                assert_eq!(mode, 0o755, "{} is {mode:o}", script.name);
            }
        }

        // A second run is a no-op as well: the same bytes are left alone.
        let (_, again) = install_scripts(&root).expect("scripts installed again");
        assert_eq!(again, 0);

        let results = install_into(&root.join("skills"), BUNDLED_SKILLS, "linux", Some(&cli), &endpoints());
        let desktop = std::fs::read_to_string(
            root.join("skills").join("bot-desktop").join("SKILL.md"),
        )
        .unwrap();
        let bin = cli.parent().unwrap().to_string_lossy().to_string();
        assert!(desktop.contains(&format!("{bin}/hermey_desktop.py")), "sibling path not rendered");
        assert!(!desktop.contains(BIN_PLACEHOLDER));
        assert!(results.iter().all(|r| r.outcome == Outcome::Written));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn without_the_cli_only_the_skill_that_needs_it_is_held_back() {
        let root = scratch("nocli");
        let results = install_into(&root.join("skills"), BUNDLED_SKILLS, "linux", None, &endpoints());

        assert_eq!(outcome(&results, SKILL_NAME), &Outcome::NoCli);
        assert!(!root.join("skills").join(SKILL_NAME).join("SKILL.md").exists());
        for name in ["bot-desktop", "signin", "integrations"] {
            assert_eq!(outcome(&results, name), &Outcome::Written, "{name}");
            let text = std::fs::read_to_string(root.join("skills").join(name).join("SKILL.md")).unwrap();
            assert!(text.contains(NO_SCRIPTS_NOTE), "{name} kept a literal placeholder");
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn frontmatter_drives_platform_and_version() {
        assert!(!applies_on(MAC_ONLY.template, "linux"));
        assert!(applies_on(MAC_ONLY.template, "macos"));
        assert_eq!(version(MAC_ONLY.template), "1.0.1");

        // Every bundled skill ships without a `platforms:` list, so every host gets it — the Mac
        // skill is what a *Linux* host needs, since that is the machine the bot runs on.
        for skill in BUNDLED_SKILLS {
            assert!(applies_on(skill.template, "linux"), "{}", skill.name);
            assert!(applies_on(skill.template, "macos"), "{}", skill.name);
        }
        assert!(needs_cli(&BUNDLED_SKILLS[0]));
        assert!(!needs_cli(&BUNDLED_SKILLS[1]));
        assert_eq!(version(BUNDLED_SKILLS[0].template), "1.0.0");
    }

    #[test]
    fn a_full_install_covers_the_shared_root_and_every_profile() {
        let root = scratch("full");
        let engine = root.join("engine");
        std::fs::create_dir_all(engine.join("skills")).unwrap();
        for profile in ["alpha", "beta"] {
            std::fs::create_dir_all(engine.join("profiles").join(profile)).unwrap();
        }
        // A stray file where a profile should be: it must not be mistaken for a bot.
        std::fs::write(engine.join("profiles").join("README"), b"not a profile").unwrap();

        let report = install(&engine, &root, "linux", &endpoints());

        let labels: Vec<&str> = report.profiles.iter().map(|p| p.profile.as_str()).collect();
        assert_eq!(labels, vec!["shared", "alpha", "beta"]);
        assert_eq!(report.cli, Some(root.join("bin").join(CLI_SCRIPT)));
        assert_eq!(report.scripts_written, BUNDLED_SCRIPTS.len());
        assert_eq!(report.written(), BUNDLED_SKILLS.len() * 3);
        assert_eq!(report.failed(), Vec::<String>::new());
        for profile in ["alpha", "beta"] {
            for skill in BUNDLED_SKILLS {
                let path = engine
                    .join("profiles")
                    .join(profile)
                    .join("skills")
                    .join(skill.name)
                    .join("SKILL.md");
                assert!(path.is_file(), "{}", path.display());
            }
        }
        assert_eq!(report.current(), 0);

        // Second boot: nothing to do anywhere.
        let again = install(&engine, &root, "linux", &endpoints());
        assert_eq!(again.written(), 0);
        assert_eq!(again.current(), BUNDLED_SKILLS.len() * 3);
        assert_eq!(again.scripts_written, 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn one_unwritable_slot_does_not_stop_the_others() {
        let root = scratch("blocked");
        let skills = root.join("skills");
        std::fs::create_dir_all(&skills).unwrap();
        // A FILE where the skill's directory must be: every other skill must still land.
        std::fs::write(skills.join("signin"), b"in the way").unwrap();
        let cli = root.join("bin").join(CLI_SCRIPT);
        std::fs::create_dir_all(cli.parent().unwrap()).unwrap();
        std::fs::write(&cli, b"#!/usr/bin/env python3\n").unwrap();

        let results = install_into(&skills, BUNDLED_SKILLS, "linux", Some(&cli), &endpoints());

        assert!(matches!(outcome(&results, "signin"), Outcome::Failed(_)), "{results:?}");
        for name in [SKILL_NAME, "bot-desktop", "integrations"] {
            assert_eq!(outcome(&results, name), &Outcome::Written, "{name}");
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_configured_shared_skill_dir_replaces_the_per_profile_fan_out() {
        let root = scratch("external");
        let engine = root.join("engine");
        std::fs::create_dir_all(engine.join("profiles").join("alpha")).unwrap();
        let shared = root.join("one-shared-tree");
        std::fs::write(
            engine.join("config.yaml"),
            format!("skills:\n  external_dirs: [\"{}\"]\n", shared.display()),
        )
        .unwrap();

        assert_eq!(external_dirs(&engine.join("config.yaml")), vec![shared.clone()]);

        // A config this parser cannot follow yields no dirs, so the per-profile fan-out still works.
        std::fs::write(engine.join("config.yaml"), b"skills: [unclosed\n").unwrap();
        assert!(external_dirs(&engine.join("config.yaml")).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn loopback_url_names_something_a_cli_can_dial() {
        assert_eq!(loopback_url("127.0.0.1", 8788), "http://127.0.0.1:8788");
        assert_eq!(loopback_url("localhost", 8788), "http://127.0.0.1:8788");
        assert_eq!(loopback_url("::1", 8788), "http://[::1]:8788");
    }

    /// The scripts are installed verbatim, so their defaults are the only thing that decides which
    /// service a bot reaches. All four HTTP scripts must know both ports and the local bearer.
    #[test]
    fn bundled_scripts_default_to_hermeyd_and_never_the_retired_bridge() {
        for script in BUNDLED_SCRIPTS {
            let text = std::str::from_utf8(script.bytes).expect("scripts are UTF-8");
            assert!(
                !text.contains("8787"),
                "{} still names the retired bridge's port",
                script.name
            );
        }
        for name in ["hermey_browser.py", "hermey_signin.py", "hermey_integrations.py", "local_computer.py"] {
            let text = std::str::from_utf8(
                BUNDLED_SCRIPTS.iter().find(|s| s.name == name).expect("bundled").bytes,
            )
            .unwrap();
            assert!(text.contains("8788"), "{name} does not know the main API port");
            assert!(text.contains("8790"), "{name} does not know the browser-channel port");
            assert!(text.contains("HERMEYD_LOCAL_TOKEN"), "{name} cannot take a bearer from the env");
            assert!(text.contains("local.token"), "{name} has no token-file fallback");
        }
    }

    #[test]
    fn rendered_skills_name_both_ports_and_the_token_file_with_no_leftovers() {
        let cli = PathBuf::from("/var/lib/hermey/bin/local_computer.py");
        for skill in BUNDLED_SKILLS {
            let body = render(skill, Some(&cli), &endpoints());
            assert!(!body.contains("@@"), "{} kept a placeholder", skill.name);
            assert!(!body.contains("8787"), "{} still names the retired bridge", skill.name);
        }
        let mac = render(&BUNDLED_SKILLS[0], Some(&cli), &endpoints());
        assert!(mac.contains("http://127.0.0.1:8788"), "the Mac skill must name the API");
        assert!(mac.contains("/var/lib/hermey/local.token"), "the Mac skill must name the token file");
        assert!(mac.contains("Authorization: Bearer"), "the Mac skill's curl must send the bearer");
        let desktop = render(&BUNDLED_SKILLS[1], Some(&cli), &endpoints());
        assert!(
            desktop.contains("http://127.0.0.1:8790/v1/browser/act"),
            "the desktop skill's probe must use the browser channel"
        );
        let signin = render(&BUNDLED_SKILLS[2], Some(&cli), &endpoints());
        assert!(signin.contains("http://127.0.0.1:8788") && signin.contains("http://127.0.0.1:8790"));
    }

    #[test]
    fn an_install_leaves_no_placeholder_in_any_installed_file() {
        let root = scratch("placeholders");
        let engine = root.join("engine");
        let report = install(&engine, &root, "linux", &endpoints());
        assert!(report.cli.is_some(), "scripts must install on a writable state dir");

        for (_, dir) in targets(&engine) {
            for skill in BUNDLED_SKILLS {
                let path = dir.join(skill.name).join("SKILL.md");
                if !path.is_file() {
                    continue; // NoCli for the Mac skill on a host that could not write it.
                }
                let text = std::fs::read_to_string(&path).unwrap();
                assert!(!text.contains("@@"), "{} kept a placeholder", path.display());
                assert!(!text.contains("8787"), "{} names the retired bridge", path.display());
            }
        }
        for script in BUNDLED_SCRIPTS {
            let text = std::str::from_utf8(script.bytes).unwrap();
            assert!(!text.contains("@@"), "{} ships a literal placeholder", script.name);
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    // ---- the scripts' own behaviour, exercised with the interpreter they ship for ---------------

    fn python3() -> Option<&'static str> {
        let ok = std::process::Command::new("python3")
            .arg("--version")
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false);
        if ok {
            Some("python3")
        } else {
            None
        }
    }

    fn python_command(envs: &[(&str, &str)]) -> std::process::Command {
        let mut command = std::process::Command::new("python3");
        command.env_clear().env("PATH", "/usr/local/bin:/usr/bin:/bin");
        for (key, value) in envs {
            command.env(key, value);
        }
        command
    }

    fn run_python(script: &Path, args: &[&str], envs: &[(&str, &str)]) -> std::process::Output {
        python_command(envs)
            .arg(script)
            .args(args)
            .output()
            .expect("python3 runs")
    }

    /// Import a script and print its resolved defaults, endpoints and bearer.
    const PROBE: &str = r#"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("bundled", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(json.dumps({
    "api": module.DEFAULT_API,
    "browser": module.DEFAULT_BROWSER,
    "pair": list(module.endpoints()),
    "compat": list(module.endpoints("http://127.0.0.1:9999")),
    "token": module.local_token(),
}))
"#;

    #[test]
    fn the_scripts_resolve_hermeyd_defaults_and_env_beats_the_token_file() {
        let Some(_) = python3() else {
            eprintln!("skipping: python3 is not on PATH on this build host");
            return;
        };
        let root = scratch("pydefaults");
        let (cli, _) = install_scripts(&root).expect("scripts installed");
        let bin = cli.parent().unwrap().to_path_buf();
        let token_file = root.join("local.token");
        std::fs::write(&token_file, "file-token-0123456789abcdef0123456789abcdef\n").unwrap();

        let probe = |script: &str, extra: &[(&str, &str)]| -> serde_json::Value {
            let mut envs = vec![("HERMEYD_LOCAL_TOKEN_FILE", token_file.to_str().unwrap())];
            envs.extend_from_slice(extra);
            let out = python_command(&envs)
                .args(["-c", PROBE])
                .arg(bin.join(script))
                .output()
                .expect("python3 runs");
            assert!(out.status.success(), "{}: {}", script, String::from_utf8_lossy(&out.stderr));
            serde_json::from_slice(&out.stdout).expect("probe printed JSON")
        };

        for script in ["hermey_browser.py", "hermey_signin.py", "hermey_integrations.py", "local_computer.py"] {
            let value = probe(script, &[]);
            assert_eq!(value["api"], "http://127.0.0.1:8788", "{script}");
            assert_eq!(value["browser"], "http://127.0.0.1:8790", "{script}");
            assert_eq!(value["pair"], serde_json::json!(["http://127.0.0.1:8788", "http://127.0.0.1:8790"]));
            assert_eq!(value["token"], "file-token-0123456789abcdef0123456789abcdef", "{script}");

            // Env wins over the file: a caller with the value never needs the state dir.
            let value = probe(script, &[("HERMEYD_LOCAL_TOKEN", "env-token")]);
            assert_eq!(value["token"], "env-token", "{script} ignored its env var");

            // An explicit bridge override still governs both channels, old-host style — whether it
            // arrives as the environment variable or as the `--bridge` argument.
            let value = probe(script, &[("HERMES_BRIDGE_URL", "http://127.0.0.1:9999")]);
            assert_eq!(
                value["pair"],
                serde_json::json!(["http://127.0.0.1:9999", "http://127.0.0.1:9999"]),
                "{script} ignored HERMES_BRIDGE_URL"
            );
            assert_eq!(
                value["compat"],
                serde_json::json!(["http://127.0.0.1:9999", "http://127.0.0.1:9999"]),
                "{script} ignored an explicit --bridge"
            );
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_missing_token_file_is_a_clear_error_not_a_traceback() {
        let Some(_) = python3() else {
            eprintln!("skipping: python3 is not on PATH on this build host");
            return;
        };
        let root = scratch("pymissing");
        let (cli, _) = install_scripts(&root).expect("scripts installed");
        let bin = cli.parent().unwrap().to_path_buf();
        let missing = root.join("no-such-local.token");
        let envs = [("HERMEYD_LOCAL_TOKEN_FILE", missing.to_str().unwrap())];

        for (script, args) in [
            ("hermey_integrations.py", vec!["list"]),
            ("hermey_signin.py", vec!["ask", "--site", "example.invalid"]),
            ("local_computer.py", vec!["observe"]),
        ] {
            let out = run_python(&bin.join(script), &args, &envs);
            assert!(!out.status.success(), "{script} should fail without a bearer");
            let err = String::from_utf8_lossy(&out.stderr);
            assert!(err.contains("no local bearer"), "{script}: {err}");
            assert!(err.contains("local.token"), "{script} must name the file it looked for: {err}");
            assert!(!err.contains("Traceback"), "{script} printed a traceback: {err}");
        }
        let _ = std::fs::remove_dir_all(&root);
    }
}
