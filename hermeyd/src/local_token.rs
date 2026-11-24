//! The local CLI bearer: one token, owned by the service, readable only by root / the service user.
//!
//! The bundled skill scripts (`bin/*.py`, installed by `skills.rs`) run on this host and drive a bot
//! through the same `/v1` routes the apps use. Those routes require a device bearer, so without a
//! credential of their own a script following its own examples gets a 401 — or, pointed at the
//! retired bridge's port, a connection refused. Loopback-exempting the routes would let *any*
//! process on the host drive a bot (and `tailscale serve` turns that into any tailnet peer), so the
//! credential is a file instead:
//!
//! * `<state>/local.token`, mode `0600`, created atomically on boot, never logged in full;
//! * on a host where the bots run as a different account than the service, `HERMEYD_LOCAL_TOKEN_GROUP`
//!   (or `HERMEYD_LOCAL_TOKEN_USER`) names that one principal: the file becomes `0640` owned by that
//!   group (or user) and is never world-readable. Unset means `0600`; a malformed value — empty,
//!   both set, a group or user that does not exist — keeps `0600` and is reported at boot rather
//!   than guessed at;
//! * accepted by `routes::require_device` as `Authorization: Bearer …` under the principal
//!   [`LOCAL_PRINCIPAL`];
//! * compared in constant time, from memory — the hot path reads no file and mutates no state;
//! * deleting the file and restarting the service invalidates it (the next boot mints another).
//!
//! This is deliberately **not** a device row: a device is revocable per device, refreshes with a
//! 30 s ticket and lives in the registry. A local token is a service-owned principal with no TTL of
//! its own; its lifetime is the file's lifetime. See `auth::random_token` for the entropy source —
//! the same primitive the pairing tokens use.

use std::io;
use std::path::{Path, PathBuf};

/// The `device_id` a local-token caller is reported as. Not a 16-char device id, so nothing can
/// mistake it for a paired device.
pub const LOCAL_PRINCIPAL: &str = "local-cli";

/// Environment variable carrying the token itself, read by the bundled scripts (the service never
/// reads it). Wins over the file, so a caller can pass one without a state directory being readable.
#[allow(dead_code)] // the contract is with `assets/agent-skills/bin/*.py`, not with this module
pub const TOKEN_ENV: &str = "HERMEYD_LOCAL_TOKEN";

/// Environment variable naming the token file, for a host whose state dir the caller does not know.
pub const TOKEN_FILE_ENV: &str = "HERMEYD_LOCAL_TOKEN_FILE";

/// `local.token` beside `bridge.db`, `bridge.salt` and `bin/` — the directory this process owns.
pub const TOKEN_FILE_NAME: &str = "local.token";

/// Opt-in: name the group whose members may read the token (set as the file's gid, mode `0640`).
/// Use this when hermeyd runs as one account and the bots it drives run as another.
pub const ACCESS_GROUP_ENV: &str = "HERMEYD_LOCAL_TOKEN_GROUP";

/// Opt-in: name the user who should own the token, still mode `0640` — for a deployment where the
/// service runs as root but the CLI runs as one unprivileged account.
pub const ACCESS_USER_ENV: &str = "HERMEYD_LOCAL_TOKEN_USER";

/// A token shorter than this cannot carry 256 bits of base64 entropy; a file that short is treated
/// as damaged and replaced, exactly as `auth::load_or_create_salt` treats a short salt.
const MIN_TOKEN_LEN: usize = 32;

/// Where the local CLI token lives for a given state directory.
pub fn token_path(state_home: &Path) -> PathBuf {
    resolve_path(state_home, std::env::var(TOKEN_FILE_ENV).ok().as_deref())
}

/// The pure half, so a test never has to mutate this process's environment (which races with a
/// concurrently spawned child and is exactly how a suite starts failing one run in twenty).
fn resolve_path(state_home: &Path, override_value: Option<&str>) -> PathBuf {
    match override_value {
        Some(value) if !value.trim().is_empty() => PathBuf::from(value.trim()),
        _ => state_home.join(TOKEN_FILE_NAME),
    }
}

/// Who, besides the service's own account, may read the token. `OwnerOnly` is the default and the
/// fallback for every malformed configuration.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum Access {
    #[default]
    OwnerOnly,
    Group { gid: u32, name: String },
    User { uid: u32, name: String },
}

impl Access {
    /// The mode this policy needs. Nothing here is ever world-readable, and a named principal only
    /// gets read access — never write.
    pub fn mode(&self) -> u32 {
        match self {
            Access::OwnerOnly => 0o600,
            Access::Group { .. } | Access::User { .. } => 0o640,
        }
    }

    /// One line for the boot log: which principal, and the mode it results in.
    pub fn describe(&self) -> String {
        match self {
            Access::OwnerOnly => "owner only, mode 0600".to_string(),
            Access::Group { gid, name } => format!("group \"{name}\" (gid {gid}), mode 0640"),
            Access::User { uid, name } => format!("user \"{name}\" (uid {uid}), mode 0640"),
        }
    }
}

/// The resolved policy plus, when the configuration was bad, the reason it fell back to `0600`.
#[derive(Clone, Debug, Default)]
pub struct AccessPlan {
    pub access: Access,
    pub warning: Option<String>,
}

impl AccessPlan {
    pub fn owner_only() -> Self {
        Self { access: Access::OwnerOnly, warning: None }
    }

    /// Read the opt-in from the environment. Both variables are read in one go so a host that sets
    /// two contradictory principals is refused rather than resolved by precedence.
    pub fn from_env() -> Self {
        plan_from(
            std::env::var(ACCESS_GROUP_ENV).ok().as_deref(),
            std::env::var(ACCESS_USER_ENV).ok().as_deref(),
        )
    }
}

/// The pure half of [`AccessPlan::from_env`], so tests never mutate this process's environment.
///
/// `None` means the variable was not set at all; `Some("")` or `Some("  ")` means it was set to
/// nothing, which is a mistake, not a request for the default.
fn plan_from(group: Option<&str>, user: Option<&str>) -> AccessPlan {
    match (group, user) {
        (None, None) => AccessPlan::owner_only(),
        (Some(_), Some(_)) => AccessPlan {
            access: Access::OwnerOnly,
            warning: Some(format!(
                "both {ACCESS_GROUP_ENV} and {ACCESS_USER_ENV} are set; \
                 refusing to guess which principal should read local.token, keeping 0600"
            )),
        },
        (Some(raw), None) => match trimmed(raw) {
            None => malformed(ACCESS_GROUP_ENV),
            Some(name) => match lookup_group(name) {
                Some(gid) => AccessPlan {
                    access: Access::Group { gid, name: name.to_string() },
                    warning: None,
                },
                None => unknown(ACCESS_GROUP_ENV, name),
            },
        },
        (None, Some(raw)) => match trimmed(raw) {
            None => malformed(ACCESS_USER_ENV),
            Some(name) => match lookup_user(name) {
                Some(uid) => AccessPlan {
                    access: Access::User { uid, name: name.to_string() },
                    warning: None,
                },
                None => unknown(ACCESS_USER_ENV, name),
            },
        },
    }
}

fn trimmed(value: &str) -> Option<&str> {
    let value = value.trim();
    if value.is_empty() { None } else { Some(value) }
}

fn malformed(var: &str) -> AccessPlan {
    AccessPlan {
        access: Access::OwnerOnly,
        warning: Some(format!("{var} is set but empty; keeping local.token at 0600")),
    }
}

fn unknown(var: &str, name: &str) -> AccessPlan {
    AccessPlan {
        access: Access::OwnerOnly,
        warning: Some(format!(
            "{var}=\"{name}\" names a principal this host does not have; \
             keeping local.token at 0600"
        )),
    }
}

#[cfg(unix)]
fn lookup_group(name: &str) -> Option<u32> {
    let c_name = std::ffi::CString::new(name).ok()?;
    let mut buffer = vec![0u8; 1024];
    loop {
        // `_r` variants fill caller storage instead of a process-global buffer, so two boots (or two
        // tests) resolving a principal at once cannot read each other's entry.
        let mut entry: libc::group = unsafe { std::mem::zeroed() };
        let mut found: *mut libc::group = std::ptr::null_mut();
        let rc = unsafe {
            libc::getgrnam_r(
                c_name.as_ptr(),
                &mut entry,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut found,
            )
        };
        if rc == libc::ERANGE && buffer.len() < 1 << 20 {
            buffer.resize(buffer.len() * 2, 0);
            continue;
        }
        if rc != 0 || found.is_null() {
            return None;
        }
        return Some(unsafe { (*found).gr_gid });
    }
}

#[cfg(not(unix))]
fn lookup_group(_name: &str) -> Option<u32> {
    None
}

#[cfg(unix)]
fn lookup_user(name: &str) -> Option<u32> {
    let c_name = std::ffi::CString::new(name).ok()?;
    let mut buffer = vec![0u8; 1024];
    loop {
        let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
        let mut found: *mut libc::passwd = std::ptr::null_mut();
        let rc = unsafe {
            libc::getpwnam_r(
                c_name.as_ptr(),
                &mut entry,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut found,
            )
        };
        if rc == libc::ERANGE && buffer.len() < 1 << 20 {
            buffer.resize(buffer.len() * 2, 0);
            continue;
        }
        if rc != 0 || found.is_null() {
            return None;
        }
        return Some(unsafe { (*found).pw_uid });
    }
}

#[cfg(not(unix))]
fn lookup_user(_name: &str) -> Option<u32> {
    None
}

/// Give the token to exactly one other principal. Anything that fails — including a `chown` this
/// process is not privileged enough to do — falls back to `0600` and returns the reason instead of
/// leaving a half-widened file behind.
fn apply_access(path: &Path, requested: &Access) -> (Access, u32, Option<String>) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let applied = (|| -> io::Result<()> {
            match requested {
                Access::OwnerOnly => set_mode(path, 0o600),
                Access::Group { gid, .. } => {
                    chown(path, None, Some(*gid))?;
                    set_mode(path, 0o640)
                }
                Access::User { uid, .. } => {
                    chown(path, Some(*uid), None)?;
                    set_mode(path, 0o640)
                }
            }
        })();

        match applied {
            Ok(()) => {
                let mode = std::fs::metadata(path)
                    .map(|m| m.permissions().mode() & 0o777)
                    .unwrap_or_else(|_| requested.mode());
                // A mode that came back wider than planned is not a success.
                if mode & 0o007 != 0 {
                    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
                    return (
                        Access::OwnerOnly,
                        0o600,
                        Some(format!(
                            "{} came back mode {:03o}; reset it to 0600",
                            path.display(),
                            mode
                        )),
                    );
                }
                (requested.clone(), mode, None)
            }
            Err(e) => {
                set_private(path);
                (
                    Access::OwnerOnly,
                    0o600,
                    Some(format!(
                        "could not give {} read access to {}: {e}; keeping 0600",
                        requested.describe(),
                        path.display()
                    )),
                )
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        match requested {
            Access::OwnerOnly => (Access::OwnerOnly, 0o600, None),
            other => (
                Access::OwnerOnly,
                0o600,
                Some(format!(
                    "{} requested, but this platform has no ownership API; keeping 0600",
                    other.describe()
                )),
            ),
        }
    }
}

#[cfg(unix)]
fn chown(path: &Path, uid: Option<u32>, gid: Option<u32>) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains a NUL byte"))?;
    // `(uid_t)-1` means "leave this field alone"; that is what makes setting only the gid possible.
    let rc = unsafe { libc::chown(c_path.as_ptr(), uid.unwrap_or(u32::MAX), gid.unwrap_or(u32::MAX)) };
    if rc == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

/// The service's own bearer, held in memory for the process's lifetime.
///
/// The value is never `Debug`-printed and never written to a log: `Display` shows the path, the
/// access policy and the mode on disk — never the token.
pub struct LocalToken {
    token: String,
    path: PathBuf,
    access: Access,
    mode: u32,
    warning: Option<String>,
}

impl std::fmt::Display for LocalToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} (local bearer, {} chars, {})",
            self.path.display(),
            self.token.len(),
            self.access.describe()
        )
        .and_then(|()| {
            if self.mode != self.access.mode() {
                write!(f, ", on disk mode {:03o}", self.mode)
            } else {
                Ok(())
            }
        })
    }
}

impl LocalToken {
    /// The default policy: owner only. Used by tests and by any caller with no opt-in to apply.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn load_or_create(path: &Path) -> io::Result<Self> {
        Self::load_or_create_with(path, &AccessPlan::owner_only())
    }

    /// Read the token at `path`, creating it (atomically, mode set at creation) when it is missing
    /// or too short, then apply `plan` — which is also how a lowered policy tightens a file left
    /// `0640` by an earlier boot.
    pub fn load_or_create_with(path: &Path, plan: &AccessPlan) -> io::Result<Self> {
        let token = match read_token(path)? {
            Some(token) => token,
            None => {
                let token = crate::auth::random_token(32);
                write_atomically(path, &token)?;
                token
            }
        };
        let (access, mode, apply_warning) = apply_access(path, &plan.access);
        Ok(Self {
            token,
            path: path.to_path_buf(),
            access,
            mode,
            warning: plan.warning.clone().or(apply_warning),
        })
    }

    /// A token whose value is already known — tests, and the in-memory state they build.
    #[allow(dead_code)]
    pub fn from_value(token: impl Into<String>, path: impl Into<PathBuf>) -> Self {
        Self {
            token: token.into(),
            path: path.into(),
            access: Access::OwnerOnly,
            mode: 0o600,
            warning: None,
        }
    }

    /// The reason a configured principal was not applied, when there was one. Main prints this at
    /// boot; a `Some` always means the file stayed `0600`.
    pub fn warning(&self) -> Option<&str> {
        self.warning.as_deref()
    }

    /// The mode the token actually has on disk (as last applied).
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn mode(&self) -> u32 {
        self.mode
    }

    #[allow(dead_code)] // read by tests and by anything that wants to name the file
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Constant-time comparison. Lengths are not secret (the token is a fixed-size base64 string),
    /// so a length difference answers `false` immediately; every byte of an equal-length guess is
    /// compared regardless of where the first mismatch is.
    pub fn matches(&self, presented: &str) -> bool {
        if presented.is_empty() {
            return false;
        }
        constant_time_eq(self.token.as_bytes(), presented.trim().as_bytes())
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut diff = (a.len() != b.len()) as u8;
    let shorter = a.len().min(b.len());
    for i in 0..shorter {
        diff |= a[i] ^ b[i];
    }
    // Keep the loop's result from being folded away at compile time.
    std::hint::black_box(diff) == 0
}

/// `Some(token)` when the file holds a usable one, `None` when it is absent or too short.
fn read_token(path: &Path) -> io::Result<Option<String>> {
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let trimmed = text.trim();
            if trimmed.len() >= MIN_TOKEN_LEN {
                Ok(Some(trimmed.to_string()))
            } else {
                Ok(None)
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// Write a fresh token without ever exposing a partially-written or over-readable file: a temp
/// file in the same directory, mode set at creation, then `rename` over the target.
fn write_atomically(path: &Path, token: &str) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, format!("{} has no parent directory", path.display()))
    })?;
    std::fs::create_dir_all(parent)?;

    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| TOKEN_FILE_NAME.to_string());
    let tmp = parent.join(format!(
        ".{name}.{}.{}.tmp",
        std::process::id(),
        SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));

    let written = (|| -> io::Result<()> {
        use std::io::Write as _;
        #[cfg(unix)]
        let mut file = {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&tmp)?
        };
        #[cfg(not(unix))]
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        file.write_all(token.as_bytes())?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        set_private(&tmp);
        std::fs::rename(&tmp, path)
    })();

    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

fn set_private(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
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
            "hermeyd-localtoken-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    #[cfg(unix)]
    fn mode(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn a_fresh_token_is_created_private_and_reused() {
        let dir = scratch("fresh");
        let path = dir.join(TOKEN_FILE_NAME);

        let first = LocalToken::load_or_create(&path).expect("token created");
        assert!(path.is_file(), "the token file must exist where a script looks for it");
        #[cfg(unix)]
        {
            assert_eq!(mode(&path), 0o600, "the local bearer must not be readable by others");
        }
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert!(first.matches(on_disk.trim()));
        assert!(on_disk.trim().len() >= MIN_TOKEN_LEN);

        // A second boot reads the same value: the token is the file, not a per-boot secret.
        let second = LocalToken::load_or_create(&path).expect("token reused");
        assert!(second.matches(on_disk.trim()));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), on_disk);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_over_readable_file_is_tightened_on_boot() {
        let dir = scratch("tighten");
        let path = dir.join(TOKEN_FILE_NAME);
        std::fs::write(&path, "x".repeat(43)).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        }

        let token = LocalToken::load_or_create(&path).expect("loaded");
        assert!(token.matches(&"x".repeat(43)));
        #[cfg(unix)]
        assert_eq!(mode(&path), 0o600);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn deleting_the_file_and_reloading_invalidates_the_old_token() {
        let dir = scratch("rotate");
        let path = dir.join(TOKEN_FILE_NAME);
        let first = LocalToken::load_or_create(&path).unwrap();
        let old = std::fs::read_to_string(&path).unwrap();

        std::fs::remove_file(&path).unwrap();
        let second = LocalToken::load_or_create(&path).unwrap();

        assert!(!second.matches(old.trim()), "a deleted token must not come back");
        assert!(!first.matches(std::fs::read_to_string(&path).unwrap().trim()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn only_the_exact_token_matches() {
        let dir = scratch("exact");
        let token = LocalToken::load_or_create(&dir.join(TOKEN_FILE_NAME)).unwrap();
        let value = std::fs::read_to_string(token.path()).unwrap().trim().to_string();

        assert!(token.matches(&value));
        assert!(token.matches(&format!("{value}\n")), "a trailing newline is not part of the secret");
        assert!(!token.matches(""));
        assert!(!token.matches(&value[..value.len() - 1]), "a prefix must not pass");
        assert!(!token.matches(&format!("{value}x")), "a suffix must not pass");
        // The guess must differ in its first byte even when the random token happens to start
        // with `x` — base64's alphabet makes that a 1-in-64 flake, not a matcher bug.
        let wrong_first = format!(
            "{}{}",
            if value.starts_with('x') { 'y' } else { 'x' },
            &value[1..]
        );
        assert!(!token.matches(&wrong_first), "one wrong byte must not pass");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_state_dir_path_is_the_default_and_an_override_wins() {
        let dir = scratch("path");
        assert_eq!(token_path(&dir), dir.join(TOKEN_FILE_NAME));
        assert_eq!(resolve_path(&dir, None), dir.join(TOKEN_FILE_NAME));
        assert_eq!(resolve_path(&dir, Some("   ")), dir.join(TOKEN_FILE_NAME));
        assert_eq!(
            resolve_path(&dir, Some("/elsewhere/keyring.token")),
            PathBuf::from("/elsewhere/keyring.token")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_default_policy_is_owner_only_and_never_world_readable() {
        let dir = scratch("policy-default");
        let path = dir.join(TOKEN_FILE_NAME);
        let plan = plan_from(None, None);

        assert_eq!(plan.access, Access::OwnerOnly);
        assert!(plan.warning.is_none(), "no opt-in is not a misconfiguration");

        let token = LocalToken::load_or_create_with(&path, &plan).unwrap();
        assert!(token.warning().is_none());
        #[cfg(unix)]
        {
            assert_eq!(mode(&path), 0o600);
            assert_eq!(token.mode(), 0o600);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    fn current_group_name() -> String {
        // SAFETY: `getgrgid` returns either null or a pointer to a static entry; it is read once,
        // in the test's own thread, before the next lookup.
        unsafe {
            let entry = libc::getgrgid(libc::getegid());
            assert!(!entry.is_null(), "the process's own group must exist");
            std::ffi::CStr::from_ptr((*entry).gr_name).to_string_lossy().into_owned()
        }
    }

    #[cfg(unix)]
    fn current_user_name() -> String {
        unsafe {
            let entry = libc::getpwuid(libc::geteuid());
            assert!(!entry.is_null(), "the process's own user must exist");
            std::ffi::CStr::from_ptr((*entry).pw_name).to_string_lossy().into_owned()
        }
    }

    #[cfg(unix)]
    fn gid_of(path: &Path) -> u32 {
        std::os::unix::fs::MetadataExt::gid(&std::fs::metadata(path).unwrap())
    }

    #[cfg(unix)]
    fn uid_of(path: &Path) -> u32 {
        std::os::unix::fs::MetadataExt::uid(&std::fs::metadata(path).unwrap())
    }

    #[cfg(unix)]
    #[test]
    fn a_configured_existing_group_gets_read_access_and_nothing_else() {
        let dir = scratch("group");
        let path = dir.join(TOKEN_FILE_NAME);
        let name = current_group_name();
        let plan = plan_from(Some(&name), None);

        assert!(matches!(plan.access, Access::Group { .. }), "resolved: {plan:?}");
        assert!(plan.warning.is_none(), "{:?}", plan.warning);

        let token = LocalToken::load_or_create_with(&path, &plan).unwrap();
        assert!(token.warning().is_none(), "{:?}", token.warning());
        assert_eq!(mode(&path), 0o640, "group read, never world-readable");
        assert_eq!(mode(&path) & 0o007, 0, "no world bits");
        let expected = match plan.access {
            Access::Group { gid, .. } => gid,
            _ => unreachable!(),
        };
        assert_eq!(gid_of(&path), expected, "the file carries the configured group");
        assert_eq!(token.mode(), 0o640);

        // The group that can read it is the one named in the boot log.
        assert!(token.to_string().contains(&name), "{token}");
        assert!(token.to_string().contains("0640"), "{token}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_configured_existing_user_owns_the_token_and_group_can_read() {
        let dir = scratch("user");
        let path = dir.join(TOKEN_FILE_NAME);
        let name = current_user_name();
        let plan = plan_from(None, Some(&name));

        assert!(matches!(plan.access, Access::User { .. }), "resolved: {plan:?}");
        let token = LocalToken::load_or_create_with(&path, &plan).unwrap();
        assert!(token.warning().is_none(), "{:?}", token.warning());
        assert_eq!(mode(&path), 0o640);
        let expected = match plan.access {
            Access::User { uid, .. } => uid,
            _ => unreachable!(),
        };
        assert_eq!(uid_of(&path), expected);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_missing_group_fails_closed_and_says_so() {
        let dir = scratch("missing-group");
        let path = dir.join(TOKEN_FILE_NAME);
        let plan = plan_from(Some("hermeyd-no-such-group"), None);

        assert_eq!(plan.access, Access::OwnerOnly, "must not guess a gid");
        let warning = plan.warning.as_deref().expect("the fallback must be explained");
        assert!(warning.contains("hermeyd-no-such-group"), "{warning}");

        let token = LocalToken::load_or_create_with(&path, &plan).unwrap();
        assert_eq!(mode(&path), 0o600);
        assert!(token.warning().is_some(), "the boot log must carry the warning");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_missing_user_fails_closed_and_says_so() {
        let dir = scratch("missing-user");
        let path = dir.join(TOKEN_FILE_NAME);
        let plan = plan_from(None, Some("hermeyd-no-such-user"));

        assert_eq!(plan.access, Access::OwnerOnly);
        assert!(plan.warning.as_deref().unwrap().contains("hermeyd-no-such-user"));

        LocalToken::load_or_create_with(&path, &plan).unwrap();
        assert_eq!(mode(&path), 0o600);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_malformed_principal_never_widens_the_file() {
        let dir = scratch("malformed");
        let path = dir.join(TOKEN_FILE_NAME);

        for (group, user) in [(Some(""), None), (Some("   "), None), (None, Some("")), (Some("x"), Some("y"))]
        {
            let plan = plan_from(group, user);
            assert_eq!(plan.access, Access::OwnerOnly, "input {group:?}/{user:?}");
            assert!(plan.warning.is_some(), "input {group:?}/{user:?}");

            let token = LocalToken::load_or_create_with(&path, &plan).unwrap();
            assert_eq!(mode(&path), 0o600, "input {group:?}/{user:?}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_reboot_with_a_narrowed_policy_tightens_the_token_again() {
        let dir = scratch("narrow");
        let path = dir.join(TOKEN_FILE_NAME);
        let widened = plan_from(Some(&current_group_name()), None);
        let token = LocalToken::load_or_create_with(&path, &widened).unwrap();
        assert_eq!(mode(&path), 0o640);

        // Same file, same value, but the opt-in is gone: boot must take the group bit back.
        let narrowed = LocalToken::load_or_create_with(&path, &AccessPlan::owner_only()).unwrap();
        assert_eq!(mode(&path), 0o600);
        assert!(narrowed.matches(&std::fs::read_to_string(&path).unwrap().trim()));
        assert_eq!(narrowed.mode(), 0o600);
        // The previous boot's value is still the token: only the permissions changed.
        assert!(token.matches(&std::fs::read_to_string(&path).unwrap().trim()));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
