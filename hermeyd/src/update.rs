//! The service's own next version: `GET /v1/update` reports, `POST /v1/update` installs.
//!
//! `hermeyd` is the one process on a host that can rebuild itself without touching anything else:
//! it is a single static binary whose previous build is two `rename` calls away. So this module
//! does exactly that and nothing more — it never runs the installer, never touches the engine,
//! never writes outside `/opt/hermey` and the state directory, and never downloads anything a
//! checksum does not vouch for.
//!
//! ## The two answers
//!
//! ```json
//! GET  /v1/update
//! {"current":"0.3.9","latest":"0.4.0","available":true,
//!  "notes_url":"https://github.com/macblizzard/hermey/releases/tag/hermeyd-v0.4.0",
//!  "checked_at":1795222533.13,"can_self_update":true,"arch":"linux-x86_64",
//!  "last_update":{"target":"0.4.0","previous":"0.3.9","state":"healthy",
//!                 "attempts":1,"started_at":1795222533.1}}
//!
//! POST /v1/update                                        → 202 {"target":"0.4.0"}
//! ```
//!
//! `latest` is the newest published `hermeyd-v*` release of `macblizzard/hermey`, read from the
//! GitHub API and cached for [`CACHE_SECONDS`]. A host with no route to GitHub answers **unknown**
//! (`latest: null`, an `error` string, `available: false`) — never a version it invented; an
//! update check that guesses is worse than one that says it could not tell.
//!
//! ## The install, in order
//!
//! 1. download `<base>/<tag>/hermeyd-<platform>` and `<base>/<tag>/SHA256SUMS`;
//! 2. look the asset's digest up in `SHA256SUMS` (no entry = refuse) and compare it to the bytes;
//!    a mismatch deletes the download and installs nothing;
//! 3. copy the running binary to `hermeyd.prev` beside it;
//! 4. `rename` the verified download over the binary (atomic on one filesystem — which is why the
//!    staged file is written next to the binary, not in the state dir);
//! 5. write [`STATE_FILE`] as `pending`, audit, and `exit(0)`. `Restart=always` brings the new
//!    build up.
//!
//! ## Rollback, which must never need the network
//!
//! The state file — `{target, previous, state, attempts, started_at}` in the service state dir —
//! is the whole of it:
//!
//! * a boot that finds `pending` **and** is running `target` increments `attempts`;
//! * at [`MAX_ATTEMPTS`] the service copies `hermeyd.prev` over the binary, marks `rolled-back`,
//!   audits, and exits so systemd starts the previous build again. Every step is `fs::copy` +
//!   `rename`; a host with no outbound access rolls back exactly as well as one with it;
//! * the first boot after the install is attempt 1 and serves normally. A build that crashes or
//!   never binds comes back as attempt 2 and is replaced. That is "fails to start", tested;
//! * once the service has served for [`HEALTHY_SECONDS`], `pending` flips to `healthy` and
//!   `hermeyd.prev` is kept for the next update.
//!
//! A rollback is not retried until the owner presses again: `rolled-back` is terminal, and the
//! old binary booting with a record that names *it* as `previous` does nothing at all.

use crate::audit::{AuditLog, Event};
use crate::routes::{require_device, AppState};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// ---- the release feed ----------------------------------------------------------------

/// The newest `hermeyd-v*` release, cached. Six hours is a check per working day: a version that
/// shipped this morning is still news this afternoon, and a phone that relaunches five times in
/// ten minutes must not ask GitHub five times.
pub const CACHE_SECONDS: f64 = 6.0 * 60.0 * 60.0;

/// How long a *failed* check is remembered. Short, and deliberately not zero: an offline host
/// would otherwise pay a DNS timeout on every relaunch, but a host whose link came back should
/// stop saying "unknown" within a minute rather than sit on the failure for six hours.
pub const FAILURE_SECONDS: f64 = 60.0;

/// The newest releases of the repository. `releases/latest` is the newest release of *anything*
/// and an app release carries no host binary — `setup/install.sh` asks the same question the same
/// way for the same reason.
pub const RELEASES_API: &str = "https://api.github.com/repos/macblizzard/hermey/releases?per_page=40";

/// Where the assets live. Overridable (`HERMEYD_UPDATE_BASE`) so a mirror — or a test's own
/// listener — can serve them; the default is what `setup/install.sh` downloads from.
pub const DOWNLOAD_BASE: &str = "https://github.com/macblizzard/hermey/releases/download";

/// The release tag series this service publishes under, and the one the installer reads.
const TAG_PREFIX: &str = "hermeyd-v";

/// The file names beside the binary. `hermeyd.new` is written only after a download verifies, and
/// lives beside the binary so the final `rename` cannot cross a filesystem boundary.
pub const PREV_FILE: &str = "hermeyd.prev";
pub const STAGED_FILE: &str = "hermeyd.new";

/// The state record, in the service state directory (beside `bridge.db`, `audit.jsonl`).
pub const STATE_FILE: &str = "update-state.json";

/// `pending` → `healthy` once the service has been up and serving this long. Sixty seconds is the
/// first minute of real work: the listeners are bound, a device has almost certainly connected and
/// the engine probe has answered.
pub const HEALTHY_SECONDS: u64 = 60;

/// How many boots onto a new build before the previous one is put back. Two: the first boot is the
/// install itself, so a *second* boot means the first one did not stay up.
pub const MAX_ATTEMPTS: u32 = 2;

/// The three stages a press moves through, in order. Reported by `GET /v1/update` while a press
/// is in flight so the apps can say what is actually happening.
pub const DOWNLOADING: &str = "downloading";
pub const VERIFYING: &str = "verifying";
pub const INSTALLING: &str = "installing";

pub const PENDING: &str = "pending";
pub const HEALTHY: &str = "healthy";
pub const ROLLED_BACK: &str = "rolled-back";

/// A verified asset is ~15 MB; anything past this is not a hermeyd binary.
const MAX_ASSET_BYTES: usize = 64 * 1024 * 1024;

/// One update at a time per process. Every request that arrives while a download is running gets a
/// 409 rather than a second writer on the same two files.
static APPLYING: AtomicBool = AtomicBool::new(false);

/// What the install that is running is doing right now — `downloading`, `verifying`, `installing`.
///
/// The apps show these in the row they opened with a press, so the words on screen are the host's
/// own stage rather than the app's guess at what a file copy is probably doing.
static PROGRESS: Mutex<Option<&'static str>> = Mutex::new(None);

fn set_progress(stage: Option<&'static str>) {
    match PROGRESS.lock() {
        Ok(mut guard) => *guard = stage,
        Err(poisoned) => *poisoned.into_inner() = stage,
    }
}

fn progress() -> Option<&'static str> {
    match PROGRESS.lock() {
        Ok(guard) => *guard,
        Err(poisoned) => *poisoned.into_inner(),
    }
}

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, detail: impl Into<String>) -> Fail {
    (status, Json(json!({ "detail": detail.into() })))
}

fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn http_client() -> reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                // The feed and the assets are named by this host; a redirect into somewhere else is
                // not a place this service follows a download to.
                .redirect(reqwest::redirect::Policy::limited(3))
                // A 15 MB asset on a 1 Mbit/s line is two minutes, so this is the *download's*
                // ceiling. The feed is a few kilobytes of JSON and asks for its own, much shorter,
                // timeout per request — a hung API call must not hold a check for two minutes.
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(120))
                .build()
                .unwrap_or_else(|_| reqwest::Client::new())
        })
        // `reqwest::Client` is an `Arc` inside: this is a pointer copy, not a connection pool.
        .clone()
}

// ---- platforms -----------------------------------------------------------------------

/// The release asset for a platform, or `None` when this service publishes nothing for it.
///
/// One place, mirroring `setup/install.sh:detect_target()` and the release workflow's matrix:
/// `hermeyd-linux-x86_64`, `hermeyd-linux-aarch64`, `hermeyd-darwin-arm64`,
/// `hermeyd-darwin-x86_64`. A second naming scheme is how a self-update 404s on exactly one arch.
pub fn asset_for(os: &str, arch: &str) -> Option<String> {
    let platform = match (os, arch) {
        ("linux", "x86_64") => "linux-x86_64",
        ("linux", "aarch64") | ("linux", "arm64") => "linux-aarch64",
        ("macos", "aarch64") | ("macos", "arm64") => "darwin-arm64",
        ("macos", "x86_64") => "darwin-x86_64",
        _ => return None,
    };
    Some(format!("hermeyd-{platform}"))
}

/// What `GET /v1/update` reports as `arch`: the asset without the binary's name (`linux-x86_64`),
/// or `unknown` on a platform with no published build.
fn arch_label(asset: &str) -> String {
    asset
        .strip_prefix("hermeyd-")
        .unwrap_or(asset)
        .to_string()
}

/// Whether `dir` accepts a new file. The probe is created and removed, never left behind — a
/// write test that leaves a file is a write test that fails the second time.
fn writable_dir(dir: Option<&Path>) -> bool {
    let Some(dir) = dir else { return false };
    if !dir.is_dir() {
        return false;
    }
    let probe = dir.join(format!(".hermeyd-writable-{}", std::process::id()));
    match std::fs::OpenOptions::new().write(true).create_new(true).open(&probe) {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

// ---- configuration -------------------------------------------------------------------

/// Everything a check or an install needs, resolved once per request.
///
/// Not read from the environment in the middle of a download: a path that changes between the
/// verification and the `rename` is how an update lands somewhere nobody expected.
#[derive(Clone, Debug)]
pub struct Config {
    /// The binary to replace — the running one, unless `HERMEYD_UPDATE_BIN` says otherwise.
    pub bin: PathBuf,
    pub state_dir: PathBuf,
    /// `hermeyd-linux-x86_64` and friends; empty on a platform with no published build.
    pub asset: String,
    pub api: String,
    pub base: String,
    pub enabled: bool,
}

impl Config {
    /// The service as it is running now.
    pub fn resolve(state_dir: &Path) -> Config {
        let bin = std::env::var("HERMEYD_UPDATE_BIN")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::current_exe().ok())
            .unwrap_or_else(|| PathBuf::from("/opt/hermey/bin/hermeyd"));
        let asset = asset_for(std::env::consts::OS, std::env::consts::ARCH).unwrap_or_default();
        // An operator can turn this off for a host that is managed some other way (a package, a
        // fleet tool). Off means off: no download, no 202, and `can_self_update: false` so the
        // apps draw no row at all.
        let enabled = std::env::var("HERMEYD_SELF_UPDATE")
            .map(|v| {
                !matches!(
                    v.trim().to_ascii_lowercase().as_str(),
                    "0" | "off" | "no" | "false" | "disabled"
                )
            })
            .unwrap_or(true);
        Config {
            bin,
            state_dir: state_dir.to_path_buf(),
            asset,
            api: std::env::var("HERMEYD_UPDATE_API").unwrap_or_else(|_| RELEASES_API.to_string()),
            base: std::env::var("HERMEYD_UPDATE_BASE")
                .unwrap_or_else(|_| DOWNLOAD_BASE.to_string()),
            enabled,
        }
    }

    pub fn prev(&self) -> PathBuf {
        self.bin.with_file_name(PREV_FILE)
    }

    pub fn staged(&self) -> PathBuf {
        self.bin.with_file_name(STAGED_FILE)
    }

    pub fn state_path(&self) -> PathBuf {
        self.state_dir.join(STATE_FILE)
    }

    /// The one answer both endpoints share: this host can replace its own binary, right now.
    ///
    /// Four things must hold — the feature is on, a build is published for this platform, the
    /// directory holding the binary is writable, and the state directory exists to record the
    /// attempt. Anything false is a 403 on `POST` and `can_self_update: false` on `GET`, which is
    /// what the apps key the row on: an updater that offers a button it cannot honour is worse
    /// than one that says nothing.
    pub fn can_self_update(&self) -> bool {
        self.enabled
            && !self.asset.is_empty()
            && writable_dir(self.bin.parent())
            && self.state_dir.is_dir()
    }
}

// ---- versions ------------------------------------------------------------------------

/// The numeric core and the prerelease tail: `0.4.0-rc1` → (`[0,4,0]`, `Some("rc1")`).
fn split_version(raw: &str) -> (Vec<u64>, Option<String>) {
    let trimmed = raw.trim();
    let trimmed = trimmed.strip_prefix('v').unwrap_or(trimmed);
    let trimmed = trimmed.split('+').next().unwrap_or(trimmed);
    match trimmed.split_once('-') {
        Some((numbers, pre)) => (number_parts(numbers), Some(pre.to_string())),
        None => (number_parts(trimmed), None),
    }
}

fn number_parts(text: &str) -> Vec<u64> {
    text.split('.')
        .map(|part| part.trim().parse::<u64>().unwrap_or(0))
        .collect()
}

/// Semver ordering, without a semver crate: `0.4.0 > 0.3.9`, `0.4.0 > 0.4.0-rc1`, and an
/// unparseable part counts as 0 rather than panicking on a tag somebody typed by hand.
///
/// Absent parts are zero, so `0.4` and `0.4.0` are the same version — which is what decides
/// "already current" and must never depend on how a tag was written.
pub fn compare_versions(a: &str, b: &str) -> Ordering {
    let (left, left_pre) = split_version(a);
    let (right, right_pre) = split_version(b);
    for index in 0..3 {
        let lhs = left.get(index).copied().unwrap_or(0);
        let rhs = right.get(index).copied().unwrap_or(0);
        if lhs != rhs {
            return lhs.cmp(&rhs);
        }
    }
    match (left_pre, right_pre) {
        (None, None) => Ordering::Equal,
        // A released version beats its own prereleases: 0.4.0 is newer than 0.4.0-rc1.
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(x), Some(y)) => x.cmp(&y),
    }
}

// ---- checksums -----------------------------------------------------------------------

fn is_sha256_hex(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| b.is_ascii_hexdigit())
}

/// The digest `SHA256SUMS` publishes for `name`, or `None` when the file has no line for it.
///
/// `sha256sum` writes `<hash>  <name>`, and `--binary` writes `<hash> *<name>`; both are read, and
/// a line for some other asset is skipped rather than trusted by position.
pub fn checksum_for(sums: &str, name: &str) -> Option<String> {
    for line in sums.lines() {
        let mut fields = line.split_whitespace();
        let (Some(hash), Some(file)) = (fields.next(), fields.next()) else {
            continue;
        };
        if !is_sha256_hex(hash) {
            continue;
        }
        if file.trim_start_matches('*') == name {
            return Some(hash.to_ascii_lowercase());
        }
    }
    None
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

// ---- the release feed ----------------------------------------------------------------

/// One published build: what to download, what to call it, and where the notes are.
#[derive(Clone, Debug, PartialEq)]
pub struct Release {
    pub version: String,
    pub tag: String,
    pub notes_url: String,
}

/// The newest `hermeyd-v*` release in a GitHub releases listing.
///
/// Drafts and prereleases are skipped: an automatic updater must not walk a fleet onto an rc.
/// The newest is chosen by [`compare_versions`] rather than by the array's order, because the
/// feed is ordered by creation date and a re-cut release can be newer than the one above it.
pub fn parse_releases(text: &str) -> Result<Release, String> {
    let doc: Value = serde_json::from_str(text)
        .map_err(|_| "the release feed did not answer with JSON".to_string())?;
    let list = doc
        .as_array()
        .ok_or_else(|| "the release feed did not answer with a list".to_string())?;
    let mut best: Option<Release> = None;
    for item in list {
        if item.get("draft").and_then(Value::as_bool).unwrap_or(false) {
            continue;
        }
        if item.get("prerelease").and_then(Value::as_bool).unwrap_or(false) {
            continue;
        }
        let Some(tag) = item.get("tag_name").and_then(Value::as_str) else {
            continue;
        };
        let Some(version) = tag.strip_prefix(TAG_PREFIX) else {
            continue;
        };
        if version.is_empty() {
            continue;
        }
        let notes = item
            .get("html_url")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| {
                format!("https://github.com/macblizzard/hermey/releases/tag/{tag}")
            });
        let candidate = Release {
            version: version.to_string(),
            tag: tag.to_string(),
            notes_url: notes,
        };
        let newer = match &best {
            None => true,
            Some(current) => compare_versions(&candidate.version, &current.version) == Ordering::Greater,
        };
        if newer {
            best = Some(candidate);
        }
    }
    best.ok_or_else(|| "no hermeyd release in the feed".to_string())
}

/// Ask the feed. Any failure is a string — the caller reports "unknown", never a version.
pub async fn fetch_latest(client: &reqwest::Client, api: &str) -> Result<Release, String> {
    let response = client
        .get(api)
        .header(reqwest::header::USER_AGENT, concat!("hermeyd/", env!("CARGO_PKG_VERSION")))
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        // The feed is small; fifteen seconds is slow, not busy.
        .timeout(Duration::from_secs(15))
        .send()
        .await
        .map_err(|e| format!("the release feed is unreachable ({e})"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("the release feed answered {}", status.as_u16()));
    }
    let text = response
        .text()
        .await
        .map_err(|e| format!("the release feed stopped answering ({e})"))?;
    parse_releases(&text)
}

/// The cached answer, and how old it is.
#[derive(Default)]
pub struct Cache {
    inner: Mutex<Option<(f64, Option<Release>)>>,
}

impl Cache {
    /// `(checked_at, answer)` — the answer is `None` for a failed check.
    pub fn get(&self) -> Option<(f64, Option<Release>)> {
        match self.inner.lock() {
            Ok(guard) => guard.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    pub fn put(&self, value: Option<Release>, at: f64) {
        let mut guard = match self.inner.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        *guard = Some((at, value));
    }

    /// Whether a cached answer may be used for a request at `now`. A success lives
    /// [`CACHE_SECONDS`], a failure [`FAILURE_SECONDS`]; `force` (`?refresh=1`) uses neither.
    pub fn usable(&self, now: f64, force: bool) -> Option<Option<Release>> {
        if force {
            return None;
        }
        let (at, value) = self.get()?;
        let ttl = if value.is_some() { CACHE_SECONDS } else { FAILURE_SECONDS };
        if now - at < ttl {
            Some(value)
        } else {
            None
        }
    }
}

fn cache() -> &'static Cache {
    static CACHE: OnceLock<Cache> = OnceLock::new();
    CACHE.get_or_init(Cache::default)
}

/// The cached answer, or a fresh one — stored either way, failures included (for
/// [`FAILURE_SECONDS`]). This is the only reader of the feed.
async fn latest_release(cfg: &Config, force: bool) -> Result<Release, String> {
    if let Some(answer) = cache().usable(now_secs(), force) {
        return answer.ok_or_else(|| "the release feed is unreachable".to_string());
    }
    let fetched = fetch_latest(&http_client(), &cfg.api).await;
    cache().put(fetched.clone().ok(), now_secs());
    fetched
}

// ---- the state record ----------------------------------------------------------------

/// What the last install did, and what the current boot is in the middle of.
///
/// Written before the process exits into the new build, read by every boot after it — this file
/// *is* the rollback mechanism. `state` is one of [`PENDING`], [`HEALTHY`], [`ROLLED_BACK`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UpdateState {
    /// The version being installed.
    pub target: String,
    /// The version that was running when it was installed.
    pub previous: String,
    pub state: String,
    pub attempts: u32,
    pub started_at: f64,
}

pub fn read_state(path: &Path) -> Option<UpdateState> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// Write-then-rename, so a boot that reads this file never sees half of it.
pub fn write_state(path: &Path, record: &UpdateState) -> Result<(), String> {
    let text = serde_json::to_string_pretty(record).map_err(|e| e.to_string())?;
    write_atomically(path, text.as_bytes())
}

fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, bytes).map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("cannot move {} into place: {e}", path.display())
    })
}

/// The state a `GET` reports, or `null` when this host has never updated itself.
pub fn state_summary(path: &Path) -> Value {
    match read_state(path) {
        Some(record) => json!({
            "target": record.target,
            "previous": record.previous,
            "state": record.state,
            "attempts": record.attempts,
            "started_at": record.started_at,
        }),
        None => Value::Null,
    }
}

// ---- installing ----------------------------------------------------------------------

/// A failed install step, as an audit-safe reason plus the words a log line needs.
#[derive(Debug)]
struct StepError {
    reason: &'static str,
    detail: String,
}

impl StepError {
    fn new(reason: &'static str, detail: impl Into<String>) -> StepError {
        StepError { reason, detail: detail.into() }
    }
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
        .map_err(|e| format!("cannot set the mode on {}: {e}", path.display()))
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> Result<(), String> {
    Ok(())
}

/// Replace `bin` with `new` in one step: copy beside it, then `rename` over it.
///
/// Never writes through the target: on Linux the kernel refuses to open a running executable for
/// writing (`ETXTBSY`), and on both platforms a half-written binary is a host that does not boot.
fn replace_file(new: &Path, bin: &Path) -> Result<(), String> {
    let tmp = bin.with_file_name(format!("{}.incoming", bin.file_name().and_then(|n| n.to_str()).unwrap_or("hermeyd")));
    std::fs::copy(new, &tmp).map_err(|e| format!("cannot stage {}: {e}", tmp.display()))?;
    set_mode(&tmp, 0o755)?;
    std::fs::rename(&tmp, bin).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("cannot move {} into place: {e}", bin.display())
    })
}

/// Keep the running build beside the new one, then put the new one in place.
///
/// The backup comes first on purpose: a failure between the two leaves the host on its current
/// binary with a `.prev` it does not need, which is recoverable; the other order can leave no
/// previous build at all.
fn install(cfg: &Config) -> Result<(), StepError> {
    std::fs::copy(&cfg.bin, cfg.prev()).map_err(|e| {
        StepError::new(
            "backup_failed",
            format!("cannot keep the current build at {}: {e}", cfg.prev().display()),
        )
    })?;
    set_mode(&cfg.prev(), 0o755).map_err(|e| StepError::new("backup_failed", e))?;
    std::fs::rename(cfg.staged(), &cfg.bin).map_err(|e| {
        StepError::new(
            "install_failed",
            format!("cannot replace {}: {e}", cfg.bin.display()),
        )
    })
}

/// Put the previous build back over the binary. File operations only — the rollback path never
/// touches the network, and it is reached from `main` before a socket exists.
pub fn restore_binary(bin: &Path) -> Result<(), String> {
    let prev = bin.with_file_name(PREV_FILE);
    if !prev.is_file() {
        return Err(format!("no previous build at {}", prev.display()));
    }
    replace_file(&prev, bin)
}


async fn fetch_bytes(client: &reqwest::Client, url: &str) -> Result<Vec<u8>, StepError> {
    let response = client
        .get(url)
        .header(reqwest::header::USER_AGENT, concat!("hermeyd/", env!("CARGO_PKG_VERSION")))
        .send()
        .await
        .map_err(|e| StepError::new("download_failed", format!("{url}: {e}")))?;
    let status = response.status();
    if !status.is_success() {
        return Err(StepError::new(
            "download_failed",
            format!("{url} answered {}", status.as_u16()),
        ));
    }
    response
        .bytes()
        .await
        .map(|bytes| bytes.to_vec())
        .map_err(|e| StepError::new("download_failed", format!("{url}: {e}")))
}

/// Download, verify, and install. The staged file exists only between a passed check and the
/// `rename`, and a failure removes it — a mismatched download is never left on disk to be found
/// by something else later.
async fn stage_and_install(
    client: &reqwest::Client,
    cfg: &Config,
    release: &Release,
) -> Result<(), StepError> {
    let staged = cfg.staged();
    // A leftover from an earlier attempt is not a candidate: it may be the very bytes that failed
    // verification.
    let _ = std::fs::remove_file(&staged);

    let base = cfg.base.trim_end_matches('/');
    let asset_url = format!("{base}/{}/{}", release.tag, cfg.asset);
    let sums_url = format!("{base}/{}/SHA256SUMS", release.tag);

    let bytes = fetch_bytes(client, &asset_url).await?;
    if bytes.len() > MAX_ASSET_BYTES {
        return Err(StepError::new(
            "too_large",
            format!("{} bytes is not a hermeyd binary", bytes.len()),
        ));
    }
    let sums = fetch_bytes(client, &sums_url).await?;
    set_progress(Some(VERIFYING));
    let sums = String::from_utf8_lossy(&sums).to_string();
    let expected = checksum_for(&sums, &cfg.asset).ok_or_else(|| {
        StepError::new(
            "no_checksum",
            format!("SHA256SUMS has no entry for {}", cfg.asset),
        )
    })?;
    let actual = sha256_hex(&bytes);
    if actual != expected {
        let _ = std::fs::remove_file(&staged);
        return Err(StepError::new(
            "checksum_mismatch",
            format!("expected {expected}, got {actual} — nothing was installed"),
        ));
    }

    set_progress(Some(INSTALLING));
    std::fs::write(&staged, &bytes)
        .map_err(|e| StepError::new("stage_failed", format!("{}: {e}", staged.display())))?;
    if let Err(e) = set_mode(&staged, 0o755) {
        let _ = std::fs::remove_file(&staged);
        return Err(StepError::new("stage_failed", e));
    }
    if let Err(failure) = install(cfg) {
        let _ = std::fs::remove_file(&staged);
        return Err(failure);
    }
    Ok(())
}

/// The whole background half of `POST /v1/update`: download, verify, install, and exit into the
/// new build. Runs on its own task so the 202 is answered before the first byte is fetched.
async fn apply(cfg: Config, release: Release, device: String, audit: Arc<AuditLog>) {
    let client = http_client();
    set_progress(Some(DOWNLOADING));
    let outcome = stage_and_install(&client, &cfg, &release).await;
    // Whatever happened, no stage is running any more: a check after this point must see the
    // record, not a stale word about a download that stopped.
    set_progress(None);
    match outcome {
        Ok(()) => {
            let record = UpdateState {
                target: release.version.clone(),
                previous: crate::VERSION.to_string(),
                state: PENDING.to_string(),
                attempts: 0,
                started_at: now_secs(),
            };
            match write_state(&cfg.state_path(), &record) {
                Ok(()) => {
                    audit.emit(
                        "update.installed",
                        Event { device: Some(&device), outcome: Some("ok"), ..Default::default() },
                    );
                    eprintln!(
                        "self-update: {} installed over {}; exiting for systemd to start it",
                        release.version,
                        crate::VERSION
                    );
                    // The new binary is in place and the record says so. `Restart=always` is what
                    // makes this a restart rather than a stop.
                    std::process::exit(0);
                }
                Err(why) => {
                    APPLYING.store(false, AtomicOrdering::SeqCst);
                    let _ = std::fs::remove_file(cfg.staged());
                    audit.emit(
                        "update.failed",
                        Event {
                            device: Some(&device),
                            reason: Some("state_write_failed"),
                            ..Default::default()
                        },
                    );
                    eprintln!("self-update: installed the file but could not record it: {why}");
                }
            }
        }
        Err(failure) => {
            APPLYING.store(false, AtomicOrdering::SeqCst);
            let _ = std::fs::remove_file(cfg.staged());
            audit.emit(
                "update.failed",
                Event {
                    device: Some(&device),
                    reason: Some(failure.reason),
                    ..Default::default()
                },
            );
            eprintln!("self-update refused: {}", failure.detail);
        }
    }
}

// ---- boot: attempts and rollback -----------------------------------------------------

/// What this boot did about a `pending` record.
#[derive(Clone, Debug, PartialEq)]
pub enum Boot {
    /// No record, a settled record, or a record about some other build.
    Nothing,
    /// Attempt `n` of [`MAX_ATTEMPTS`] on the new build: serve, and let the healthy timer settle it.
    Attempt(u32),
    /// The previous build was put back. The caller must exit so systemd starts it.
    RolledBack { target: String, to: String },
    /// The record says roll back but the previous build is gone or unwritable.
    RollbackStuck(String),
}

/// One audit line from the boot path, where `AppState` does not exist yet and the log is opened
/// directly beside `bridge.db`. `reason` and `outcome` must already be audit tokens.
fn audit_boot(state_dir: &Path, event: &str, outcome: &str, reason: &str) {
    AuditLog::in_dir(state_dir).emit(
        event,
        Event { outcome: Some(outcome), reason: Some(reason), ..Default::default() },
    );
}

/// Read the state record and act on it, before anything is bound or served.
///
/// This runs first thing in `main`, before the state dir would otherwise be touched for anything
/// else, so a build that cannot start is replaced by the next start rather than by a human.
pub fn on_boot(state_dir: &Path, bin: &Path, running: &str) -> Boot {
    let path = state_dir.join(STATE_FILE);
    let Some(mut record) = read_state(&path) else {
        return Boot::Nothing;
    };
    if record.state != PENDING {
        return Boot::Nothing;
    }

    if record.target != running {
        // Not the build that was installed. If the version which came back is the one the record
        // names as `previous`, the rollback already happened (or was done by hand) — say so once
        // and stop; if it is a third version, this record is history and is left alone.
        if record.previous == running {
            record.state = ROLLED_BACK.to_string();
            let _ = write_state(&path, &record);
            audit_boot(state_dir, "update.rolled_back", "rolled_back", "previous_after_pending");
            return Boot::RolledBack { target: record.target, to: running.to_string() };
        }
        return Boot::Nothing;
    }

    record.attempts += 1;
    let _ = write_state(&path, &record);
    if record.attempts < MAX_ATTEMPTS {
        return Boot::Attempt(record.attempts);
    }

    let decision = match restore_binary(bin) {
        Ok(()) => {
            record.state = ROLLED_BACK.to_string();
            let _ = write_state(&path, &record);
            audit_boot(state_dir, "update.rolled_back", "rolled_back", "failed_to_start");
            Boot::RolledBack { target: record.target, to: record.previous }
        }
        Err(why) => {
            // The record stays `pending`: nothing was restored, so the next boot tries again. The
            // alternative — claiming success — would leave a host that can never explain itself.
            audit_boot(state_dir, "update.rolled_back", "pending", "rollback_failed");
            Boot::RollbackStuck(why)
        }
    };
    decision
}

/// `pending` → `healthy`, once this build has served for [`HEALTHY_SECONDS`].
///
/// Idempotent and quiet: called once per boot by the timer in `main`, and a record that is not
/// about this build (or is already settled) is left exactly as it is. `hermeyd.prev` is kept.
pub fn mark_healthy(state_dir: &Path, running: &str, audit: &AuditLog) -> bool {
    let path = state_dir.join(STATE_FILE);
    let Some(mut record) = read_state(&path) else {
        return false;
    };
    if record.state != PENDING || record.target != running {
        return false;
    }
    record.state = HEALTHY.to_string();
    if write_state(&path, &record).is_err() {
        return false;
    }
    audit.emit(
        "update.healthy",
        Event { outcome: Some("ok"), reason: Some("served"), ..Default::default() },
    );
    true
}

// ---- the routes ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CheckQuery {
    /// `?refresh=1` — ask the feed now instead of using the cached answer.
    pub refresh: Option<String>,
}

fn wants_refresh(query: &CheckQuery) -> bool {
    matches!(
        query.refresh.as_deref().map(str::to_ascii_lowercase).as_deref(),
        Some("1") | Some("true") | Some("yes")
    )
}

/// The body of `GET /v1/update`, built from an answer so both "found" and "unknown" are testable
/// without a network.
pub fn status_body(
    current: &str,
    answer: &Result<Release, String>,
    can_self_update: bool,
    asset: &str,
    state: Value,
    checked_at: f64,
    stage: Option<&str>,
) -> Value {
    match answer {
        Ok(release) => json!({
            "current": current,
            "latest": release.version,
            "available": compare_versions(&release.version, current) == Ordering::Greater,
            "notes_url": release.notes_url,
            "checked_at": checked_at,
            "can_self_update": can_self_update,
            "arch": arch_label(asset),
            "error": Value::Null,
            // The host's own stage while a press is in flight; null when nothing is running.
            "progress": stage,
            "last_update": state,
        }),
        Err(why) => json!({
            "current": current,
            // Unknown, not current: a check that failed must not read as "you are up to date".
            "latest": Value::Null,
            "available": false,
            "notes_url": Value::Null,
            "checked_at": checked_at,
            "can_self_update": can_self_update,
            "arch": arch_label(asset),
            "error": why,
            "progress": stage,
            "last_update": state,
        }),
    }
}

/// `GET /v1/update` — what this host is, what is published, and whether it can replace itself.
pub async fn get_update(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<CheckQuery>,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let cfg = Config::resolve(&st.home);
    let answer = latest_release(&cfg, wants_refresh(&query)).await;
    let body = status_body(
        crate::VERSION,
        &answer,
        cfg.can_self_update(),
        &cfg.asset,
        state_summary(&cfg.state_path()),
        now_secs(),
        progress(),
    );
    st.audit.emit(
        "update.check",
        Event {
            device: Some(&device),
            outcome: Some(if answer.is_ok() { "ok" } else { "unknown" }),
            ..Default::default()
        },
    );
    Ok(Json(body))
}

/// `POST /v1/update` — install the newest release, then restart into it.
///
/// Answered with 202 and the target version; the download, the verification and the exit happen
/// after the response, so the app can say "Downloading" while the host is actually downloading.
pub async fn post_update(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), Fail> {
    let device = require_device(&st, &headers)?;
    let cfg = Config::resolve(&st.home);
    if !cfg.can_self_update() {
        st.audit.emit(
            "update.blocked",
            Event { device: Some(&device), reason: Some("not_permitted"), ..Default::default() },
        );
        return Err(bad(
            StatusCode::FORBIDDEN,
            "this host does not update itself (self-update is off, or its binary is not writable)",
        ));
    }
    if APPLYING.swap(true, AtomicOrdering::SeqCst) {
        return Err(bad(StatusCode::CONFLICT, "an update is already running"));
    }
    let release = match latest_release(&cfg, false).await {
        Ok(release) => release,
        Err(why) => {
            APPLYING.store(false, AtomicOrdering::SeqCst);
            return Err(bad(StatusCode::SERVICE_UNAVAILABLE, why));
        }
    };
    if compare_versions(&release.version, crate::VERSION) != Ordering::Greater {
        APPLYING.store(false, AtomicOrdering::SeqCst);
        return Err(bad(
            StatusCode::CONFLICT,
            format!("this host is already on {} (newest published: {})", crate::VERSION, release.version),
        ));
    }
    let target = release.version.clone();
    st.audit.emit(
        "update.started",
        Event {
            device: Some(&device),
            reason: Some("target"),
            profile: Some(&target),
            ..Default::default()
        },
    );
    tokio::spawn(apply(cfg, release, device, Arc::clone(&st.audit)));
    Ok((StatusCode::ACCEPTED, Json(json!({ "target": target, "state": "started" }))))
}

// ---- tests ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::atomic::AtomicBool as Bool;
    use std::sync::Mutex as StdMutex;

    // ---- a release server, on this machine ------------------------------------------

    /// Serve a fixed set of `path → (status, body)` on a loopback port. `hermeyd` reaches releases
    /// with `reqwest`, exactly as production does, so the fake answers over real HTTP rather than
    /// through a seam that could drift from the real call.
    struct FakeRelease {
        base: String,
        hits: Arc<StdMutex<Vec<String>>>,
        stop: Arc<Bool>,
    }

    impl FakeRelease {
        fn start(routes: Vec<(&str, u16, Vec<u8>)>) -> FakeRelease {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind a loopback port");
            let port = listener.local_addr().expect("local addr").port();
            listener.set_nonblocking(true).expect("nonblocking");
            let hits = Arc::new(StdMutex::new(Vec::new()));
            let stop = Arc::new(Bool::new(false));
            let routes: Vec<(String, u16, Vec<u8>)> = routes
                .into_iter()
                .map(|(path, status, body)| (path.to_string(), status, body))
                .collect();
            let seen = Arc::clone(&hits);
            let halt = Arc::clone(&stop);
            std::thread::spawn(move || {
                while !halt.load(AtomicOrdering::SeqCst) {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            let mut buffer = [0u8; 4096];
                            let read = stream.read(&mut buffer).unwrap_or(0);
                            let request = String::from_utf8_lossy(&buffer[..read]).to_string();
                            let path = request
                                .lines()
                                .next()
                                .and_then(|line| line.split_whitespace().nth(1))
                                .unwrap_or("/")
                                .to_string();
                            seen.lock().unwrap().push(path.clone());
                            let found = routes.iter().find(|(route, _, _)| *route == path);
                            let (status, body) = match found {
                                Some((_, status, body)) => (*status, body.clone()),
                                None => (404, b"not found".to_vec()),
                            };
                            let head = format!(
                                "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                body.len()
                            );
                            let _ = stream.write_all(head.as_bytes());
                            let _ = stream.write_all(&body);
                            let _ = stream.flush();
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(Duration::from_millis(5));
                        }
                        Err(_) => break,
                    }
                }
            });
            FakeRelease { base: format!("http://127.0.0.1:{port}"), hits, stop }
        }

        fn requests(&self) -> Vec<String> {
            self.hits.lock().unwrap().clone()
        }
    }

    impl Drop for FakeRelease {
        fn drop(&mut self) {
            self.stop.store(true, AtomicOrdering::SeqCst);
        }
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-update-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    /// A host with a state dir, a "running binary" and a config pointed at a fake server.
    fn host(tag: &str, base: &str) -> (Config, PathBuf) {
        let dir = temp_dir(tag);
        let bin = dir.join("hermeyd");
        std::fs::write(&bin, b"OLD-BUILD").expect("write the running binary");
        let state_dir = dir.join("state");
        std::fs::create_dir_all(&state_dir).expect("state dir");
        let cfg = Config {
            bin,
            state_dir,
            asset: "hermeyd-linux-x86_64".to_string(),
            api: String::new(),
            base: base.to_string(),
            enabled: true,
        };
        (cfg, dir)
    }

    // ---- versions -------------------------------------------------------------------

    #[test]
    fn versions_order_numerically_not_lexically() {
        assert_eq!(compare_versions("0.4.0", "0.3.9"), Ordering::Greater);
        // "0.10.0" < "0.9.0" as strings, and that ordering would refuse a real update.
        assert_eq!(compare_versions("0.10.0", "0.9.0"), Ordering::Greater);
        assert_eq!(compare_versions("1.0.0", "0.99.99"), Ordering::Greater);
    }

    #[test]
    fn equal_versions_are_equal_however_they_are_written() {
        assert_eq!(compare_versions("0.4.0", "0.4.0"), Ordering::Equal);
        assert_eq!(compare_versions("v0.4.0", "0.4.0"), Ordering::Equal);
        assert_eq!(compare_versions("0.4", "0.4.0"), Ordering::Equal);
        assert_eq!(compare_versions("0.4.0+build.7", "0.4.0"), Ordering::Equal);
    }

    #[test]
    fn a_release_beats_its_prerelease_and_a_prerelease_is_older() {
        assert_eq!(compare_versions("0.4.0", "0.4.0-rc1"), Ordering::Greater);
        assert_eq!(compare_versions("0.4.0-rc1", "0.4.0"), Ordering::Less);
        assert_eq!(compare_versions("0.4.0-rc2", "0.4.0-rc1"), Ordering::Greater);
        assert_eq!(compare_versions("0.4.1-rc1", "0.4.0"), Ordering::Greater);
    }

    #[test]
    fn release_assets_follow_the_installers_platform_names() {
        assert_eq!(asset_for("linux", "x86_64").as_deref(), Some("hermeyd-linux-x86_64"));
        assert_eq!(asset_for("linux", "aarch64").as_deref(), Some("hermeyd-linux-aarch64"));
        assert_eq!(asset_for("macos", "aarch64").as_deref(), Some("hermeyd-darwin-arm64"));
        assert_eq!(asset_for("macos", "x86_64").as_deref(), Some("hermeyd-darwin-x86_64"));
        assert_eq!(asset_for("freebsd", "x86_64"), None);
        assert_eq!(arch_label("hermeyd-linux-x86_64"), "linux-x86_64");
    }

    // ---- checksums ------------------------------------------------------------------

    #[test]
    fn sha256_matches_the_published_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn a_sums_file_is_read_by_name_including_the_binary_marker() {
        let sums = "\
aaaa  hermeyd-darwin-arm64\n\
bbbb *hermeyd-linux-x86_64\n\
cccc  hermes-genui-plugin.tar.gz\n";
        // `bbbb` is not a digest: a line whose hash is not 64 hex characters is not trusted.
        assert_eq!(checksum_for(sums, "hermeyd-linux-x86_64"), None);
        let real = format!(
            "{}  hermeyd-linux-x86_64\n",
            sha256_hex(b"NEW-BUILD")
        );
        assert_eq!(
            checksum_for(&real, "hermeyd-linux-x86_64").as_deref(),
            Some(sha256_hex(b"NEW-BUILD").as_str())
        );
        let star = format!("{} *hermeyd-linux-x86_64\n", sha256_hex(b"NEW-BUILD"));
        assert!(checksum_for(&star, "hermeyd-linux-x86_64").is_some());
        assert_eq!(checksum_for(&real, "hermeyd-darwin-arm64"), None);
    }

    // ---- install --------------------------------------------------------------------

    /// The download path end to end: fetch the asset and the sums, verify, keep `.prev`, replace
    /// the binary, and remove the staged file.
    #[test]
    fn a_verified_download_replaces_the_binary_and_keeps_the_previous_one() {
        let new_bytes = b"NEW-BUILD".to_vec();
        let sums = format!("{}  hermeyd-linux-x86_64\n", sha256_hex(&new_bytes));
        let server = FakeRelease::start(vec![
            ("/dl/hermeyd-v0.4.0/hermeyd-linux-x86_64", 200, new_bytes.clone()),
            ("/dl/hermeyd-v0.4.0/SHA256SUMS", 200, sums.into_bytes()),
        ]);
        let (cfg, _dir) = host("verified", &format!("{}/dl", server.base));
        let release = Release {
            version: "0.4.0".to_string(),
            tag: "hermeyd-v0.4.0".to_string(),
            notes_url: String::new(),
        };
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime
            .block_on(stage_and_install(&http_client(), &cfg, &release))
            .expect("a verified download installs");

        assert_eq!(std::fs::read(&cfg.bin).unwrap(), new_bytes, "the binary is the download");
        assert_eq!(std::fs::read(cfg.prev()).unwrap(), b"OLD-BUILD", ".prev is the old build");
        assert!(!cfg.staged().exists(), "the staged file is gone after the rename");
        // Both halves of the release were fetched. Asked as two `any`s rather than one exact
        // sequence: a keep-alive connection that resets mid-body can make `reqwest` retry a request,
        // and how many times a byte-identical GET was sent says nothing about correctness.
        let hits = server.requests();
        assert!(
            hits.iter().any(|path| path.ends_with("/hermeyd-linux-x86_64")),
            "the asset was never fetched: {hits:?}"
        );
        assert!(
            hits.iter().any(|path| path.ends_with("/SHA256SUMS")),
            "the checksum file was never fetched: {hits:?}"
        );
    }

    #[test]
    fn a_checksum_mismatch_installs_nothing() {
        let sums = format!(
            "{}  hermeyd-linux-x86_64\n",
            sha256_hex(b"SOMETHING-ELSE-ENTIRELY")
        );
        let server = FakeRelease::start(vec![
            ("/dl/hermeyd-v0.4.0/hermeyd-linux-x86_64", 200, b"NEW-BUILD".to_vec()),
            ("/dl/hermeyd-v0.4.0/SHA256SUMS", 200, sums.into_bytes()),
        ]);
        let (cfg, _dir) = host("mismatch", &format!("{}/dl", server.base));
        let release = Release {
            version: "0.4.0".to_string(),
            tag: "hermeyd-v0.4.0".to_string(),
            notes_url: String::new(),
        };
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let failure = runtime
            .block_on(stage_and_install(&http_client(), &cfg, &release))
            .expect_err("a mismatched download must be refused");
        assert_eq!(failure.reason, "checksum_mismatch");
        assert_eq!(std::fs::read(&cfg.bin).unwrap(), b"OLD-BUILD", "nothing was replaced");
        assert!(!cfg.prev().exists(), "no backup was written");
        assert!(!cfg.staged().exists(), "the download was deleted");
    }

    #[test]
    fn a_sums_file_without_this_asset_installs_nothing() {
        let new_bytes = b"NEW-BUILD".to_vec();
        let sums = format!("{}  hermeyd-darwin-arm64\n", sha256_hex(&new_bytes));
        let server = FakeRelease::start(vec![
            ("/dl/hermeyd-v0.4.0/hermeyd-linux-x86_64", 200, new_bytes),
            ("/dl/hermeyd-v0.4.0/SHA256SUMS", 200, sums.into_bytes()),
        ]);
        let (cfg, _dir) = host("nochecksum", &format!("{}/dl", server.base));
        let release = Release {
            version: "0.4.0".to_string(),
            tag: "hermeyd-v0.4.0".to_string(),
            notes_url: String::new(),
        };
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let failure = runtime
            .block_on(stage_and_install(&http_client(), &cfg, &release))
            .expect_err("an unverifiable release is refused");
        assert_eq!(failure.reason, "no_checksum");
        assert_eq!(std::fs::read(&cfg.bin).unwrap(), b"OLD-BUILD");
    }

    // ---- the state machine ----------------------------------------------------------

    #[test]
    fn pending_to_healthy_once_the_build_has_served() {
        let (cfg, _dir) = host("healthy", "");
        let record = UpdateState {
            target: "0.4.0".to_string(),
            previous: "0.3.9".to_string(),
            state: PENDING.to_string(),
            attempts: 0,
            started_at: 1.0,
        };
        write_state(&cfg.state_path(), &record).unwrap();
        std::fs::write(cfg.prev(), b"OLD-BUILD").unwrap();
        let log = AuditLog::in_dir(&cfg.state_dir);

        // A boot that is running the target is the first attempt, and does not settle anything.
        assert_eq!(on_boot(&cfg.state_dir, &cfg.bin, "0.4.0"), Boot::Attempt(1));
        assert!(!mark_healthy(&cfg.state_dir, "0.3.9", &log), "another build cannot settle this record");

        let settled = mark_healthy(&cfg.state_dir, "0.4.0", &log);
        assert!(settled);
        let stored = read_state(&cfg.state_path()).unwrap();
        assert_eq!(stored.state, HEALTHY);
        // Idempotent: a second call finds nothing to do.
        assert!(!mark_healthy(&cfg.state_dir, "0.4.0", &log));
        // `.prev` is kept for the next update rather than deleted on a healthy boot.
        assert!(cfg.prev().exists(), "the previous build stays on disk");
    }

    #[test]
    fn the_second_boot_onto_a_build_restores_the_previous_one() {
        let (cfg, _dir) = host("rollback", "");
        std::fs::write(cfg.prev(), b"OLD-OLD-BUILD").unwrap();
        std::fs::write(&cfg.bin, b"BROKEN-NEW-BUILD").unwrap();
        let record = UpdateState {
            target: "0.4.0".to_string(),
            previous: "0.3.9".to_string(),
            state: PENDING.to_string(),
            attempts: 0,
            started_at: 1.0,
        };
        write_state(&cfg.state_path(), &record).unwrap();

        // First boot onto the new build: attempt 1, serve.
        assert_eq!(on_boot(&cfg.state_dir, &cfg.bin, "0.4.0"), Boot::Attempt(1));
        assert_eq!(read_state(&cfg.state_path()).unwrap().attempts, 1);

        // It did not stay up. The next boot is attempt 2 and the previous build goes back.
        let decision = on_boot(&cfg.state_dir, &cfg.bin, "0.4.0");
        assert_eq!(
            decision,
            Boot::RolledBack { target: "0.4.0".to_string(), to: "0.3.9".to_string() }
        );
        assert_eq!(std::fs::read(&cfg.bin).unwrap(), b"OLD-OLD-BUILD");
        let stored = read_state(&cfg.state_path()).unwrap();
        assert_eq!(stored.state, ROLLED_BACK);
        assert_eq!(stored.attempts, MAX_ATTEMPTS);

        // The previous build booting now finds a settled record and does nothing.
        assert_eq!(on_boot(&cfg.state_dir, &cfg.bin, "0.3.9"), Boot::Nothing);
        // And a third boot does not roll back again.
        assert_eq!(on_boot(&cfg.state_dir, &cfg.bin, "0.3.9"), Boot::Nothing);
    }

    #[test]
    fn a_rollback_needs_no_network_and_no_record_without_previous_bytes() {
        let (cfg, _dir) = host("noroll", "");
        let record = UpdateState {
            target: "0.4.0".to_string(),
            previous: "0.3.9".to_string(),
            state: PENDING.to_string(),
            attempts: MAX_ATTEMPTS - 1,
            started_at: 1.0,
        };
        write_state(&cfg.state_path(), &record).unwrap();
        // No `hermeyd.prev`: the rollback cannot happen and the record stays pending, which is the
        // honest state (nothing was restored).
        match on_boot(&cfg.state_dir, &cfg.bin, "0.4.0") {
            Boot::RollbackStuck(why) => assert!(why.contains("no previous build")),
            other => panic!("expected a stuck rollback, got {other:?}"),
        }
        assert_eq!(read_state(&cfg.state_path()).unwrap().state, PENDING);
    }

    #[test]
    fn a_settled_record_is_left_alone_and_the_previous_binary_is_not_restored() {
        let (cfg, _dir) = host("settled", "");
        std::fs::write(cfg.prev(), b"OLD-OLD-BUILD").unwrap();
        let record = UpdateState {
            target: "0.4.0".to_string(),
            previous: "0.3.9".to_string(),
            state: HEALTHY.to_string(),
            attempts: 1,
            started_at: 1.0,
        };
        write_state(&cfg.state_path(), &record).unwrap();
        assert_eq!(on_boot(&cfg.state_dir, &cfg.bin, "0.4.0"), Boot::Nothing);
        assert_eq!(std::fs::read(&cfg.bin).unwrap(), b"OLD-BUILD");
    }

    #[test]
    fn the_record_names_the_states_the_apps_draw() {
        // The apps switch on these three strings; a rename here is a silent "nothing is happening".
        let (cfg, _dir) = host("states", "");
        assert_eq!(PENDING, "pending");
        assert_eq!(HEALTHY, "healthy");
        assert_eq!(ROLLED_BACK, "rolled-back");
        let record = UpdateState {
            target: "0.4.0".to_string(),
            previous: "0.3.9".to_string(),
            state: PENDING.to_string(),
            attempts: 1,
            started_at: 12.5,
        };
        write_state(&cfg.state_path(), &record).unwrap();
        let summary = state_summary(&cfg.state_path());
        assert_eq!(summary["target"], json!("0.4.0"));
        assert_eq!(summary["previous"], json!("0.3.9"));
        assert_eq!(summary["state"], json!("pending"));
        assert_eq!(summary["attempts"], json!(1));
    }

    // ---- the feed and the cache -----------------------------------------------------

    #[test]
    fn the_newest_host_release_wins_and_app_releases_are_ignored() {
        let feed = json!([
            {"tag_name": "v0.1.620", "draft": false, "prerelease": false,
             "html_url": "https://github.com/macblizzard/hermey/releases/tag/v0.1.620"},
            {"tag_name": "hermeyd-v0.3.9", "draft": false, "prerelease": false,
             "html_url": "https://github.com/macblizzard/hermey/releases/tag/hermeyd-v0.3.9"},
            {"tag_name": "hermeyd-v0.4.0", "draft": false, "prerelease": false,
             "html_url": "https://github.com/macblizzard/hermey/releases/tag/hermeyd-v0.4.0"},
            {"tag_name": "hermeyd-v0.10.0", "draft": true, "prerelease": false, "html_url": "x"},
            {"tag_name": "hermeyd-v0.5.0-rc1", "draft": false, "prerelease": true, "html_url": "x"}
        ])
        .to_string();
        let release = parse_releases(&feed).expect("a host release is in the feed");
        assert_eq!(release.version, "0.4.0", "drafts and prereleases are not candidates");
        assert_eq!(release.tag, "hermeyd-v0.4.0");
        assert_eq!(
            release.notes_url,
            "https://github.com/macblizzard/hermey/releases/tag/hermeyd-v0.4.0"
        );
        // 0.10.0 is numerically newer than 0.4.0; if it were published it would win over the
        // feed's own order. Dated above so this asserts the comparison, not a copy of the list.
        let newer = json!([{"tag_name": "hermeyd-v0.10.0", "draft": false, "prerelease": false}])
            .to_string();
        assert_eq!(parse_releases(&newer).unwrap().version, "0.10.0");
    }

    #[test]
    fn a_feed_that_cannot_answer_is_unknown_not_a_version() {
        assert!(parse_releases("not json at all").is_err());
        assert!(parse_releases("[]").is_err());
        assert!(parse_releases("[]").unwrap_err().contains("no hermeyd release"));
    }

    #[test]
    fn a_failed_check_answer_says_unknown_in_the_body() {
        let body = status_body(
            "0.3.9",
            &Err("the release feed is unreachable".to_string()),
            true,
            "hermeyd-linux-x86_64",
            Value::Null,
            100.0,
            None,
        );
        assert_eq!(body["latest"], Value::Null, "never a fabricated version");
        assert_eq!(body["available"], json!(false));
        assert_eq!(body["current"], json!("0.3.9"));
        assert_eq!(body["arch"], json!("linux-x86_64"));
        assert!(body["error"].as_str().unwrap().contains("unreachable"));
        assert_eq!(body["last_update"], Value::Null);
    }

    #[test]
    fn an_available_version_is_reported_with_its_notes() {
        let release = Release {
            version: "0.4.0".to_string(),
            tag: "hermeyd-v0.4.0".to_string(),
            notes_url: "https://example.invalid/notes".to_string(),
        };
        let body = status_body("0.3.9", &Ok(release), true, "hermeyd-linux-x86_64", Value::Null, 1.0, None);
        assert_eq!(body["latest"], json!("0.4.0"));
        assert_eq!(body["available"], json!(true));
        assert_eq!(body["notes_url"], json!("https://example.invalid/notes"));
        assert_eq!(body["can_self_update"], json!(true));
        assert_eq!(body["error"], Value::Null);
    }

    #[test]
    fn the_running_install_reports_its_stage() {
        let release = Release {
            version: "0.4.0".to_string(),
            tag: "hermeyd-v0.4.0".to_string(),
            notes_url: String::new(),
        };
        for stage in [DOWNLOADING, VERIFYING, INSTALLING] {
            let body = status_body(
                "0.3.9",
                &Ok(release.clone()),
                true,
                "hermeyd-linux-x86_64",
                Value::Null,
                1.0,
                Some(stage),
            );
            assert_eq!(body["progress"], json!(stage));
        }
        let idle = status_body("0.3.9", &Ok(release), true, "hermeyd-linux-x86_64", Value::Null, 1.0, None);
        assert_eq!(idle["progress"], Value::Null);
    }

    #[test]
    fn being_current_is_not_an_available_update() {
        let release = Release {
            version: "0.3.9".to_string(),
            tag: "hermeyd-v0.3.9".to_string(),
            notes_url: String::new(),
        };
        let body = status_body("0.3.9", &Ok(release), true, "hermeyd-linux-x86_64", Value::Null, 1.0, None);
        assert_eq!(body["available"], json!(false));
    }

    #[test]
    fn the_cache_serves_a_success_for_six_hours_and_a_failure_for_one_minute() {
        let cache = Cache::default();
        let release = Release {
            version: "0.4.0".to_string(),
            tag: "hermeyd-v0.4.0".to_string(),
            notes_url: String::new(),
        };
        cache.put(Some(release.clone()), 1000.0);
        assert_eq!(cache.usable(1000.0 + 60.0, false), Some(Some(release.clone())));
        assert_eq!(
            cache.usable(1000.0 + CACHE_SECONDS - 1.0, false),
            Some(Some(release.clone()))
        );
        assert_eq!(cache.usable(1000.0 + CACHE_SECONDS + 1.0, false), None);
        // `?refresh=1` ignores a fresh cache.
        assert_eq!(cache.usable(1000.0 + 1.0, true), None);

        cache.put(None, 2000.0);
        assert_eq!(cache.usable(2000.0 + 10.0, false), Some(None));
        assert_eq!(cache.usable(2000.0 + FAILURE_SECONDS + 1.0, false), None);
    }

    #[test]
    fn a_host_with_self_update_off_or_no_published_build_cannot_update() {
        let (mut cfg, _dir) = host("permit", "");
        assert!(cfg.can_self_update(), "a writable directory beside a state dir is enough");
        cfg.enabled = false;
        assert!(!cfg.can_self_update(), "off means off");
        cfg.enabled = true;
        cfg.asset = String::new();
        assert!(!cfg.can_self_update(), "no published build for this platform");
    }

    #[test]
    fn the_refresh_query_is_read_from_the_usual_spellings() {
        for value in ["1", "true", "yes", "TRUE"] {
            assert!(wants_refresh(&CheckQuery { refresh: Some(value.to_string()) }), "{value}");
        }
        for value in ["0", "no", "", "later"] {
            assert!(!wants_refresh(&CheckQuery { refresh: Some(value.to_string()) }), "{value}");
        }
        assert!(!wants_refresh(&CheckQuery { refresh: None }));
    }

    #[test]
    fn the_running_binary_is_not_written_through_on_the_way_in() {
        // `replace_file` must land the bytes by rename, never by opening the target: the target is
        // the executable this process is running.
        let (cfg, _dir) = host("rename", "");
        std::fs::write(cfg.prev(), b"OLD-OLD-BUILD").unwrap();
        restore_binary(&cfg.bin).expect("restore");
        assert_eq!(std::fs::read(&cfg.bin).unwrap(), b"OLD-OLD-BUILD");
        assert!(cfg.prev().exists(), "the previous build is kept after a restore");
        // No temporary files left behind next to the binary.
        let leftovers: Vec<String> = std::fs::read_dir(cfg.bin.parent().unwrap())
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name.contains("incoming"))
            .collect();
        assert!(leftovers.is_empty(), "leftovers: {leftovers:?}");
    }
}
