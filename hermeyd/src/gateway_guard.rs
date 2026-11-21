//! One cron ticker per engine home.
//!
//! `hermes gateway run` is the process that owns the cron store: it schedules every profile under
//! `HERMES_HOME` and fires routines on a supervised thread. Our deploy launches it with `--force`,
//! which deliberately bypasses the full install's "a gateway is already running for this profile"
//! host lock. That flag is correct for a supervisor (systemd *is* the owner) and catastrophic when
//! a full Hermes install is also running a gateway for the same `HERMES_HOME`: both processes tick
//! the same store, and every routine fires twice.
//!
//! So this is a **detection**, not a lock: at boot, and before anything would spawn a gateway, scan
//! `/proc` for another `hermes gateway run` whose `HERMES_HOME` is this engine home. If there is
//! one and spawning was requested, the answer is `Refuse` — the caller must not start a second
//! ticker, and the log says exactly which process was found and what to do.
//!
//! Nothing here kills anything: the running gateway may be the one a human started, and taking it
//! down would be a worse outage than the duplicate. The remedy is always the operator's.

use std::path::{Path, PathBuf};

/// One process that appears to own the cron ticker for this engine home.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Owner {
    pub pid: u32,
    /// The process's command line, joined with single spaces (truncated for the log).
    pub cmdline: String,
    /// The `HERMES_HOME` that made it a match.
    pub home: PathBuf,
    /// How the home was found: `environ` or `cwd` — the two a service-managed process exposes.
    pub via: &'static str,
}

/// What boot (or a spawn site) should do.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Decision {
    /// No launcher was asked for (`HERMEYD_SPAWN_GATEWAY` is off): detection is informational.
    #[default]
    NotRequested,
    /// Nothing else owns the ticker: spawning one is safe.
    Clear,
    /// Another process owns it. Refuse to spawn and say what was found.
    Refuse(Vec<Owner>),
}

impl Decision {
    pub fn refused(&self) -> bool {
        matches!(self, Decision::Refuse(_))
    }

    /// The one-word outcome used in the boot line and the `--gateway-check` status.
    pub fn as_str(&self) -> &'static str {
        match self {
            Decision::NotRequested => "not-requested",
            Decision::Clear => "clear",
            Decision::Refuse(_) => "refused",
        }
    }
}

/// `true` for `1`, `true`, `yes`, `on` (any case); everything else, including unset, is off. A
/// malformed value must not turn a guard into a spawn.
pub fn truthy(value: Option<&str>) -> bool {
    matches!(
        value.map(|v| v.trim().to_ascii_lowercase()).as_deref(),
        Some("1") | Some("true") | Some("yes") | Some("on")
    )
}

/// Whether this process was configured to own a gateway/cron ticker.
pub fn spawn_requested() -> bool {
    truthy(std::env::var("HERMEYD_SPAWN_GATEWAY").ok().as_deref())
}

/// The decision, with no I/O — the test suite pins this.
pub fn decide(spawn_requested: bool, owners: &[Owner]) -> Decision {
    if !spawn_requested {
        return Decision::NotRequested;
    }
    if owners.is_empty() {
        Decision::Clear
    } else {
        Decision::Refuse(owners.to_vec())
    }
}

/// Whether one argv looks like `hermes gateway run`.
///
/// Deliberately narrow: `hermes serve` and `hermes dashboard` do **not** tick cron
/// (`web_server_app` starts the ticker for desktop-owned backends only — see
/// `docs/EDITION-A.md`), so counting them would refuse a correct deployment.
fn is_gateway_run(args: &[String]) -> bool {
    let has = |needle: &str| args.iter().any(|arg| arg == needle);
    if !(has("gateway") && has("run")) {
        return false;
    }
    // Three real spellings, all seen on this host:
    //   `.../venv/bin/hermes gateway run --force`              (our deploy, argv[0] is the script)
    //   `.../venv/bin/python -I -m hermes_cli.main gateway run`(a full install)
    //   `python -m hermes_agent gateway run`                   (older installs)
    // So the program is "named hermes" when argv[0]'s basename *or* any module argument does.
    let named_hermes = args.iter().any(|arg| {
        let base = Path::new(arg)
            .file_name()
            .map(|n| n.to_string_lossy().to_ascii_lowercase())
            .unwrap_or_default();
        base == "hermes" || base.starts_with("hermes_") || base.starts_with("hermes-")
    });
    named_hermes || args.first().map(|a| a.to_ascii_lowercase().contains("hermes")).unwrap_or(false)
}

/// The `HERMES_HOME` a process was launched with, from `/proc/<pid>/environ`.
fn environ_home(proc_root: &Path, pid: u32) -> Option<PathBuf> {
    let bytes = std::fs::read(proc_root.join(pid.to_string()).join("environ")).ok()?;
    for entry in bytes.split(|b| *b == 0) {
        let text = String::from_utf8_lossy(entry);
        if let Some(value) = text.strip_prefix("HERMES_HOME=") {
            let value = value.trim();
            if !value.is_empty() {
                return Some(PathBuf::from(value));
            }
        }
    }
    None
}

/// The process's working directory. A `gateway run` launched from an engine home without
/// `HERMES_HOME` in its environment still resolves profiles from that home.
fn cwd_of(proc_root: &Path, pid: u32) -> Option<PathBuf> {
    std::fs::read_link(proc_root.join(pid.to_string()).join("cwd")).ok()
}

fn same_home(found: &Path, engine_home: &Path) -> bool {
    if found == engine_home {
        return true;
    }
    match (found.canonicalize(), engine_home.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// Every other `hermes gateway run` that resolves to `engine_home`.
///
/// `proc_root` is a parameter so the tests can build a fake `/proc` out of temp dirs; production
/// passes [`Path::new("/proc")`]. `self_pid` is excluded: this process is never the duplicate.
pub fn scan(proc_root: &Path, engine_home: &Path, self_pid: u32) -> Vec<Owner> {
    let Ok(entries) = std::fs::read_dir(proc_root) else {
        // No /proc (a sandbox, a non-Linux host): nothing can be proven, so nothing is claimed.
        return Vec::new();
    };
    let mut owners = Vec::new();
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_string_lossy().parse::<u32>().ok() else {
            continue;
        };
        if pid == self_pid {
            continue;
        }
        let Ok(raw) = std::fs::read(proc_root.join(pid.to_string()).join("cmdline")) else {
            continue;
        };
        let args: Vec<String> = raw
            .split(|b| *b == 0)
            .map(|part| String::from_utf8_lossy(part).to_string())
            .filter(|part| !part.is_empty())
            .collect();
        if !is_gateway_run(&args) {
            continue;
        }
        let cmdline = args.join(" ");
        let (home, via) = match environ_home(proc_root, pid) {
            Some(home) => (home, "environ"),
            None => match cwd_of(proc_root, pid) {
                Some(home) => (home, "cwd"),
                None => continue,
            },
        };
        if same_home(&home, engine_home) {
            owners.push(Owner {
                pid,
                cmdline,
                home,
                via,
            });
        }
    }
    owners.sort_by_key(|owner| owner.pid);
    owners
}

/// What was found, and what to do about it. Stable wording on purpose: an operator reads this in
/// `journalctl`, and a test asserts it names the pid, the home and the remedy.
pub fn refusal_message(engine_home: &Path, owners: &[Owner]) -> String {
    let mut out = format!(
        "gateway: refusing to spawn a cron ticker for {}: another gateway already owns this engine home",
        engine_home.display()
    );
    for owner in owners {
        out.push_str(&format!(
            "\n  found pid {}: {} (HERMES_HOME={}, via {})",
            owner.pid,
            owner.cmdline,
            owner.home.display(),
            owner.via
        ));
    }
    out.push_str(
        "\n  what to do: the process above is already ticking this cron store, so a second one \
         would fire every routine twice. Leave it running and set HERMEYD_SPAWN_GATEWAY=0, or \
         stop it first (systemctl --user stop hermes-gateway) if this service is meant to own the \
         ticker. Nothing was killed.",
    );
    out
}

/// The informational line for a detected gateway when no spawn was requested — boot still says
/// what it saw, because "routines fire twice" is only diagnosable if the duplicate was named.
pub fn detected_line(engine_home: &Path, owners: &[Owner]) -> String {
    let pids: Vec<String> = owners.iter().map(|o| o.pid.to_string()).collect();
    format!(
        "gateway: {} already owns {} (pid {}); hermeyd is not spawning one (HERMEYD_SPAWN_GATEWAY is off)",
        if owners.len() == 1 { "a gateway" } else { "gateways" },
        engine_home.display(),
        pids.join(",")
    )
}

/// The boot-time check: scan the real `/proc`, then log and answer.
///
/// Logging is part of the contract: a refusal nobody can see is the same as a silent double-fire.
pub fn check(engine_home: &Path, spawn_requested: bool) -> Decision {
    let owners = scan(Path::new("/proc"), engine_home, std::process::id());
    let decision = decide(spawn_requested, &owners);
    match &decision {
        Decision::Refuse(found) => eprintln!("{}", refusal_message(engine_home, found)),
        Decision::Clear => eprintln!(
            "gateway: no other gateway for {}; spawning one is permitted",
            engine_home.display()
        ),
        Decision::NotRequested if !owners.is_empty() => {
            eprintln!("{}", detected_line(engine_home, &owners))
        }
        Decision::NotRequested => {}
    }
    decision
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
            "hermeyd-gateway-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    /// A fake `/proc/<pid>` entry. `environ` is `None` for a process that does not export
    /// `HERMES_HOME` (the cwd fallback then decides).
    fn fake_process(
        proc_root: &Path,
        pid: u32,
        args: &[&str],
        environ: Option<&str>,
        cwd: Option<&Path>,
    ) {
        let dir = proc_root.join(pid.to_string());
        std::fs::create_dir_all(&dir).unwrap();
        let mut cmdline = Vec::new();
        for arg in args {
            cmdline.extend_from_slice(arg.as_bytes());
            cmdline.push(0);
        }
        std::fs::write(dir.join("cmdline"), cmdline).unwrap();
        std::fs::write(
            dir.join("environ"),
            environ.unwrap_or("PATH=/usr/bin").as_bytes(),
        )
        .unwrap();
        if let Some(cwd) = cwd {
            #[cfg(unix)]
            std::os::unix::fs::symlink(cwd, dir.join("cwd")).unwrap();
            #[cfg(not(unix))]
            let _ = cwd;
        }
    }

    fn engine_dir(root: &Path) -> PathBuf {
        let engine = root.join("engine");
        std::fs::create_dir_all(&engine).unwrap();
        engine
    }

    /// The live failure this guard exists for: another `gateway run --force` for the same home.
    #[test]
    fn a_second_gateway_for_the_same_home_is_refused() {
        let root = scratch("duplicate");
        let proc_root = root.join("proc");
        let engine = engine_dir(&root);
        fake_process(
            &proc_root,
            4242,
            &["/opt/hermes/venv/bin/hermes", "gateway", "run", "--force"],
            Some(&format!("HERMES_HOME={}\0PATH=/usr/bin\0", engine.display())),
            None,
        );

        let owners = scan(&proc_root, &engine, 1);
        assert_eq!(owners.len(), 1, "{owners:?}");
        assert_eq!(owners[0].pid, 4242);
        assert_eq!(owners[0].via, "environ");

        let decision = decide(true, &owners);
        assert!(decision.refused(), "{decision:?}");
        assert_eq!(decision.as_str(), "refused");

        let message = refusal_message(&engine, &owners);
        assert!(message.contains("4242"), "{message}");
        assert!(message.contains(&engine.display().to_string()), "{message}");
        assert!(message.contains("gateway run --force"), "{message}");
        assert!(message.contains("what to do"), "{message}");
        assert!(message.contains("Nothing was killed"), "{message}");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A full install spells the same process `python -I -m hermes_cli.main gateway run`; argv[0]
    /// is not `hermes` at all, and this is the exact shape that double-fires with our deploy.
    #[test]
    fn a_module_style_full_install_gateway_is_recognised() {
        let root = scratch("module-style");
        let proc_root = root.join("proc");
        let engine = engine_dir(&root);
        fake_process(
            &proc_root,
            3325432,
            &[
                "/opt/hermes/venv/bin/python3",
                "-I",
                "-m",
                "hermes_cli.main",
                "gateway",
                "run",
            ],
            Some(&format!("HERMES_HOME={}\0", engine.display())),
            None,
        );

        let owners = scan(&proc_root, &engine, 1);
        assert_eq!(owners.len(), 1, "{owners:?}");
        assert!(decide(true, &owners).refused());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A gateway for a *different* HERMES_HOME is not a duplicate: this host may legitimately run
    /// two engines, and refusing here would break a correct install.
    #[test]
    fn a_gateway_for_another_home_does_not_block_the_spawn() {
        let root = scratch("other");
        let proc_root = root.join("proc");
        let engine = engine_dir(&root);
        let elsewhere = root.join("other-home");
        std::fs::create_dir_all(&elsewhere).unwrap();
        fake_process(
            &proc_root,
            500,
            &["/usr/local/bin/hermes", "gateway", "run", "--force"],
            Some(&format!("HERMES_HOME={}\0", elsewhere.display())),
            None,
        );

        let owners = scan(&proc_root, &engine, 1);
        assert!(owners.is_empty(), "{owners:?}");
        assert_eq!(decide(true, &owners), Decision::Clear);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// `hermes serve` is the WS surface, not the cron ticker — it must never count as an owner.
    #[test]
    fn serve_and_this_process_are_not_owners() {
        let root = scratch("serve");
        let proc_root = root.join("proc");
        let engine = engine_dir(&root);
        let environ = format!("HERMES_HOME={}\0", engine.display());
        fake_process(&proc_root, 10, &["/usr/bin/hermes", "serve"], Some(&environ), None);
        fake_process(
            &proc_root,
            11,
            &["/usr/bin/hermes", "gateway", "run"],
            Some(&environ),
            None,
        );

        let owners = scan(&proc_root, &engine, 11);
        assert!(owners.is_empty(), "self is never the duplicate: {owners:?}");
        let owners = scan(&proc_root, &engine, 1);
        assert_eq!(owners.len(), 1);
        assert_eq!(owners[0].pid, 11);
        assert_eq!(owners[0].via, "environ");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A process started without `HERMES_HOME` in its environment is still detected by its cwd —
    /// the shape a systemd unit with `WorkingDirectory=<engine home>` produces.
    #[test]
    #[cfg(unix)]
    fn a_gateway_is_found_by_its_cwd_when_the_environment_is_silent() {
        let root = scratch("cwd");
        let proc_root = root.join("proc");
        let engine = engine_dir(&root);
        fake_process(
            &proc_root,
            77,
            &["/opt/hermes/venv/bin/hermes", "gateway", "run", "--force"],
            None,
            Some(&engine),
        );

        let owners = scan(&proc_root, &engine, 1);
        assert_eq!(owners.len(), 1, "{owners:?}");
        assert_eq!(owners[0].via, "cwd");
        assert_eq!(owners[0].home, engine);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The same /proc with the guard not configured to spawn: detection is reported, nothing is
    /// refused, and no spawn is implied.
    #[test]
    fn detection_is_informational_when_no_spawn_was_requested() {
        let root = scratch("informational");
        let proc_root = root.join("proc");
        let engine = engine_dir(&root);
        fake_process(
            &proc_root,
            9,
            &["/opt/hermes/venv/bin/hermes", "gateway", "run"],
            Some(&format!("HERMES_HOME={}\0", engine.display())),
            None,
        );
        let owners = scan(&proc_root, &engine, 1);
        let decision = decide(false, &owners);
        assert_eq!(decision, Decision::NotRequested);
        assert!(!decision.refused());
        let line = detected_line(&engine, &owners);
        assert!(line.contains("pid 9"), "{line}");
        assert!(line.contains("HERMEYD_SPAWN_GATEWAY is off"), "{line}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn only_an_explicit_affirmative_requests_a_spawn() {
        for value in ["1", "true", "TRUE", "yes", " on "] {
            assert!(truthy(Some(value)), "{value}");
        }
        for value in [None, Some(""), Some("0"), Some("false"), Some("no"), Some("off")] {
            assert!(!truthy(value), "{value:?}");
        }
    }

    /// An unreadable/absent `/proc` must not invent an owner.
    #[test]
    fn a_missing_proc_root_finds_nothing() {
        let root = scratch("noproc");
        let engine = engine_dir(&root);
        assert!(scan(&root.join("no-such-proc"), &engine, 1).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }
}
