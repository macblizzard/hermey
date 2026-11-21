//! The gate in front of the first write.
//!
//! A bare `hermeyd` used to boot first and bind second: it created `~/.hermey`, installed skills,
//! minted a token and wrote `bridge.db`, and only then discovered that the browser port was already
//! taken by the real service — leaving a second, wrong state directory in the operator's home, next
//! to a working install. The bind failure is the *cheap* question, so it is asked first, before any
//! file exists. Everything here is read-only: it connects, stats and looks; it never creates.
//!
//! Two refusals, in this order:
//!
//! 1. **A port is already accepting connections** — a service appears to be running, and a bare
//!    start would create a second state directory that the failed bind then strands on disk.
//! 2. **The state directory exists but is not ours** — no `bridge.db`, no `local.token`, but a
//!    `profiles/` directory: that is a Hermes home (agent profiles, memory, skills), and writing a
//!    `bridge.db` into it would put this service's state inside the engine's.

use std::fmt;
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The listeners a real boot would bind, resolved once from the environment `main` already read.
pub struct Ports {
    pub bind: String,
    pub port: u16,
    pub browser_port: u16,
}

impl Ports {
    /// The main listener's address, in the same shape `main` formats for `SocketAddr`.
    pub fn main_addr(&self) -> String {
        if self.bind.contains(':') {
            format!("[{}]:{}", self.bind, self.port)
        } else {
            format!("{}:{}", self.bind, self.port)
        }
    }

    /// The browser channel always binds loopback, whatever `HERMEYD_BIND` says.
    pub fn browser_addr(&self) -> String {
        format!("127.0.0.1:{}", self.browser_port)
    }
}

/// Why this start must not proceed. Both variants are pure description: nothing has been created
/// when one of them exists.
#[derive(Debug)]
pub enum Refusal {
    /// At least one of the two listeners already answers. `creates_state_dir` is true only when the
    /// boot would have created the directory, i.e. exactly the stranded-directory case this refusal
    /// exists for.
    Busy {
        listeners: Vec<(&'static str, String)>,
        state_dir: PathBuf,
        creates_state_dir: bool,
        state_dir_source: String,
    },
    /// The directory exists, is not a Hermey state dir, and looks like a Hermes home.
    NotHermey { path: PathBuf },
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::Busy { listeners, state_dir, creates_state_dir, state_dir_source } => {
                let addresses = listeners
                    .iter()
                    .map(|(env, addr)| format!("{addr} ({env})"))
                    .collect::<Vec<_>>()
                    .join(" and ");
                let verb = if listeners.len() == 1 { "is" } else { "are" };
                writeln!(
                    f,
                    "hermeyd refuses to start: {addresses} {verb} already accepting connections."
                )?;
                writeln!(
                    f,
                    "a hermeyd service appears to be running on this host; this would have been a second \
                     instance, so nothing was created or changed."
                )?;
                if *creates_state_dir {
                    writeln!(
                        f,
                        "this start would have created {} as its state directory ({state_dir_source}) — not \
                         the running service's, and it would have been left behind when the bind failed.",
                        state_dir.display()
                    )?;
                } else {
                    writeln!(
                        f,
                        "the state directory at {} was left untouched.",
                        state_dir.display()
                    )?;
                }
                writeln!(f, "inspect the running service:")?;
                writeln!(f, "  hermeyd status")?;
                writeln!(f, "  systemctl status hermeyd")?;
                writeln!(
                    f,
                    "to run a second instance deliberately, give it its own ports and state directory:"
                )?;
                write!(
                    f,
                    "  HERMEYD_PORT=8888 HERMEYD_BROWSER_PORT=8890 HERMEYD_HOME=/path/to/hermeyd-state hermeyd"
                )
            }
            Refusal::NotHermey { path } => {
                writeln!(
                    f,
                    "hermeyd refuses to use the state directory {}: it is not a Hermey state directory \
                     (no bridge.db, no local.token) and it contains a profiles/ directory, so it looks \
                     like a Hermes home — profiles, memories and skills live there.",
                    path.display()
                )?;
                writeln!(
                    f,
                    "nothing was created or changed. Point HERMEYD_HOME at a directory hermeyd owns \
                     (the default is ~/.hermey) and start again:"
                )?;
                write!(f, "  HERMEYD_HOME=/path/to/hermeyd-state hermeyd")
            }
        }
    }
}

/// `true` when something accepts a TCP connection there. A short deadline: this runs before the
/// service exists, so a firewalled or black-holed address must not read as a hang.
pub fn accepting(addr: &str) -> bool {
    let Ok(candidates) = addr.to_socket_addrs() else {
        return false;
    };
    candidates.into_iter().any(|socket| {
        TcpStream::connect_timeout(&socket, Duration::from_millis(400)).is_ok()
    })
}

/// The Hermes-home test, stated once: existing directory, none of this service's two marker files,
/// and a `profiles/` child. A directory with `bridge.db` or `local.token` is ours however it looks;
/// an empty directory is a fresh install, not a Hermes home.
pub fn looks_like_hermes_home(home: &Path) -> bool {
    home.is_dir()
        && !home.join("bridge.db").exists()
        && !home.join(crate::local_token::TOKEN_FILE_NAME).exists()
        && home.join("profiles").is_dir()
}

/// The whole pre-flight. `Ok(())` means the next thing this process may do is create files.
pub fn check(home: &Path, ports: &Ports, home_source: &str) -> Result<(), Refusal> {
    let mut listeners: Vec<(&'static str, String)> = Vec::new();
    if accepting(&ports.main_addr()) {
        listeners.push(("HERMEYD_PORT", ports.main_addr()));
    }
    if accepting(&ports.browser_addr()) {
        listeners.push(("HERMEYD_BROWSER_PORT", ports.browser_addr()));
    }
    if !listeners.is_empty() {
        return Err(Refusal::Busy {
            listeners,
            state_dir: home.to_path_buf(),
            creates_state_dir: !home.is_dir(),
            state_dir_source: home_source.to_string(),
        });
    }
    if looks_like_hermes_home(home) {
        return Err(Refusal::NotHermey { path: home.to_path_buf() });
    }
    Ok(())
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
            "hermeyd-preflight-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    #[test]
    fn a_hermes_home_is_recognised_and_a_hermey_state_dir_is_not() {
        let dir = scratch("shape");
        assert!(!looks_like_hermes_home(&dir), "an empty dir is a fresh install");

        std::fs::create_dir_all(dir.join("profiles").join("cody")).unwrap();
        assert!(looks_like_hermes_home(&dir), "profiles/ and no markers is a Hermes home");

        // Either marker makes it ours, whatever else is in there.
        std::fs::write(dir.join("bridge.db"), b"").unwrap();
        assert!(!looks_like_hermes_home(&dir));
        std::fs::remove_file(dir.join("bridge.db")).unwrap();
        std::fs::write(dir.join(crate::local_token::TOKEN_FILE_NAME), b"x").unwrap();
        assert!(!looks_like_hermes_home(&dir));

        // A directory that never existed is not a Hermes home either: it is about to be created.
        assert!(!looks_like_hermes_home(&dir.join("absent")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_busy_port_is_refused_and_names_the_state_dir_it_would_have_created() {
        let dir = scratch("busy");
        let home = dir.join("state");
        let busy = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = busy.local_addr().unwrap().port();
        let ports = Ports {
            bind: "127.0.0.1".to_string(),
            port,
            browser_port: 1,
        };

        let refusal = check(&home, &ports, "no HERMEYD_HOME or HERMEY_HOME set").unwrap_err();
        let text = refusal.to_string();
        for needle in [
            "already accepting connections",
            "a hermeyd service appears to be running",
            "nothing was created or changed",
            &home.display().to_string(),
            "hermeyd status",
            "systemctl status hermeyd",
            "HERMEYD_PORT",
            "HERMEYD_BROWSER_PORT",
            "HERMEYD_HOME",
        ] {
            assert!(text.contains(needle), "refusal is missing {needle:?}:\n{text}");
        }
        // The pre-flight itself never creates the directory it is talking about.
        assert!(!home.exists(), "the pre-flight created {:?}", home);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_quiet_port_lets_the_check_pass() {
        let dir = scratch("quiet");
        let home = dir.join("state");
        let ports = Ports {
            bind: "127.0.0.1".to_string(),
            port: 1,
            browser_port: 2,
        };
        assert!(check(&home, &ports, "test").is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
