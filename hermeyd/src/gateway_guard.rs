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
    scan_checked(proc_root, engine_home, self_pid).unwrap_or_default()
}

/// `scan`, but "I could not look" is `Err` instead of "nothing found".
///
/// The difference matters only where the answer is *reported* (`hermeyd status`): an unreadable
/// `/proc` and a home nobody ticks are opposite facts, and a line that prints the second when the
/// first is true is the kind of reassurance this service must not give. Boot keeps using [`scan`],
/// where nothing can be proven and nothing is claimed either way.
pub fn scan_checked(
    proc_root: &Path,
    engine_home: &Path,
    self_pid: u32,
) -> Result<Vec<Owner>, String> {
    let entries =
        std::fs::read_dir(proc_root).map_err(|e| format!("cannot read {}: {e}", proc_root.display()))?;
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
    Ok(owners)
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

// ---------------------------------------------------------------------------------------------
// What `hermeyd status` prints
// ---------------------------------------------------------------------------------------------

/// The severity of one reported line. Its own type so the wording can be unit-tested in this
/// module, with fabricated owners, instead of only by running the service against a live host.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Ok,
    Warn,
    Fail,
}

impl Verdict {
    pub fn as_str(&self) -> &'static str {
        match self {
            Verdict::Ok => "ok",
            Verdict::Warn => "warn",
            Verdict::Fail => "fail",
        }
    }
}

/// One `status` line about the cron ticker, plus the processes it names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub verdict: Verdict,
    pub detail: String,
    /// The pids whose command lines are printed under the line. Empty for every case that does not
    /// name a process.
    pub owners: Vec<Owner>,
}

/// The `status` answer, from the scan's result — no I/O, so every combination is testable.
///
/// The wording rule this replaces: `status` used to call `evaluate(home, true)`, i.e. it asked what a
/// *spawning* process would decide, on a host where `HERMEYD_SPAWN_GATEWAY` is off and nothing was
/// ever asked to spawn. It then printed "refused … must not spawn a second ticker" at a service that
/// had not attempted anything. Five cases, five honest sentences:
///
/// | spawning | another gateway | line |
/// |---|---|---|
/// | off | yes | `ok` — one gateway owns the ticker; expected, hermeyd does not spawn one |
/// | off | no  | `warn` — nothing ticks the cron store, so routines will not fire |
/// | on  | yes | `warn` — hermeyd will not spawn a duplicate |
/// | on  | no  | `ok` — hermeyd would spawn one |
/// | —   | cannot look | `fail` |
pub fn status(engine_home: &Path, spawn_requested: bool, found: Result<Vec<Owner>, String>) -> Status {
    let home = engine_home.display();
    let owners = match found {
        Ok(owners) => owners,
        Err(reason) => {
            return Status {
                verdict: Verdict::Fail,
                detail: format!(
                    "could not check {home} for a cron ticker ({reason}) — nothing is known about \
                     who ticks it"
                ),
                owners: Vec::new(),
            }
        }
    };
    let pids: Vec<String> = owners.iter().map(|o| o.pid.to_string()).collect();
    let one_owner = owners.len() == 1;
    match decide(spawn_requested, &owners) {
        Decision::NotRequested if !owners.is_empty() => Status {
            verdict: Verdict::Ok,
            detail: format!(
                "one gateway owns the ticker (pid {}) — expected; hermeyd does not spawn one \
                 (HERMEYD_SPAWN_GATEWAY is off in this shell)",
                pids.join(",")
            ),
            owners,
        },
        Decision::NotRequested => Status {
            verdict: Verdict::Warn,
            detail: format!(
                "no gateway ticks {home} — routines will not fire; start one, or set \
                 HERMEYD_SPAWN_GATEWAY=1 and let hermeyd spawn it"
            ),
            owners: Vec::new(),
        },
        Decision::Clear => Status {
            verdict: Verdict::Ok,
            detail: format!(
                "nothing owns {home} and HERMEYD_SPAWN_GATEWAY is on — hermeyd would spawn one \
                 (it has not, yet)"
            ),
            owners: Vec::new(),
        },
        Decision::Refuse(_) => Status {
            verdict: Verdict::Warn,
            detail: format!(
                "{} other gateway process{} already tick{} {home} (pid {}); spawning is enabled, so \
                 hermeyd will not spawn a duplicate",
                owners.len(),
                if one_owner { "" } else { "es" },
                if one_owner { "s" } else { "" },
                pids.join(",")
            ),
            owners,
        },
    }
}

/// [`status`] against the real `/proc`.
pub fn evaluate_status(engine_home: &Path, spawn_requested: bool) -> Status {
    let found = scan_checked(Path::new("/proc"), engine_home, std::process::id());
    status(engine_home, spawn_requested, found)
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
        // …but it *is* a failure to look, and `status` must be able to say so.
        assert!(scan_checked(&root.join("no-such-proc"), &engine, 1).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    fn owner(pid: u32, engine: &Path) -> Owner {
        Owner {
            pid,
            cmdline: "/opt/hermes/venv/bin/hermes gateway run --force".to_string(),
            home: engine.to_path_buf(),
            via: "environ",
        }
    }

    /// The live shape this wording exists for: one systemd-managed gateway ticks the engine home and
    /// spawning is off. Nothing was refused, so nothing may say "refused".
    #[test]
    fn status_says_one_gateway_is_expected_when_nothing_was_asked_to_spawn() {
        let root = scratch("status-expected");
        let engine = engine_dir(&root);
        let owners = vec![owner(4093283, &engine)];

        let reported = status(&engine, false, Ok(owners.clone()));
        assert_eq!(reported.verdict, Verdict::Ok, "{reported:?}");
        assert!(
            reported.detail.contains("one gateway owns the ticker (pid 4093283)"),
            "{}",
            reported.detail
        );
        assert!(reported.detail.contains("expected"), "{}", reported.detail);
        assert!(reported.detail.contains("hermeyd does not spawn one"), "{}", reported.detail);
        assert!(
            !reported.detail.contains("refused"),
            "nothing was refused: {}",
            reported.detail
        );
        assert!(
            !reported.detail.contains("must not spawn a second ticker"),
            "the old claim is still there: {}",
            reported.detail
        );
        // The pid is still printed underneath, with its command line: that is the value of the check.
        assert_eq!(reported.owners, owners);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Spawning enabled and a gateway already there: this is the one case where a spawn really would
    /// be a duplicate, so it keeps today's meaning — as a warning, not a refusal.
    #[test]
    fn status_warns_when_spawning_is_enabled_and_a_gateway_already_owns_the_ticker() {
        let root = scratch("status-duplicate");
        let engine = engine_dir(&root);
        let owners = vec![owner(4242, &engine)];

        let reported = status(&engine, true, Ok(owners.clone()));
        assert_eq!(reported.verdict, Verdict::Warn, "{reported:?}");
        assert!(reported.detail.contains("pid 4242"), "{}", reported.detail);
        assert!(reported.detail.contains("will not spawn a duplicate"), "{}", reported.detail);
        assert!(reported.detail.contains(&engine.display().to_string()), "{}", reported.detail);
        assert_eq!(reported.owners, owners);

        // Two owners read as plural, and both pids are named.
        let reported = status(&engine, true, Ok(vec![owner(1, &engine), owner(2, &engine)]));
        assert!(reported.detail.contains("2 other gateway processes"), "{}", reported.detail);
        assert!(reported.detail.contains("pid 1,2"), "{}", reported.detail);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Spawning enabled, nothing there: hermeyd *would* spawn one, and the line has to say which of
    /// the two things is true rather than leave it ambiguous.
    #[test]
    fn status_says_hermeyd_would_spawn_when_spawning_is_enabled_and_nothing_owns_it() {
        let root = scratch("status-clear");
        let engine = engine_dir(&root);

        let reported = status(&engine, true, Ok(Vec::new()));
        assert_eq!(reported.verdict, Verdict::Ok, "{reported:?}");
        assert!(reported.detail.contains("hermeyd would spawn one"), "{}", reported.detail);
        assert!(reported.detail.contains("it has not, yet"), "{}", reported.detail);
        assert!(reported.owners.is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Spawning off and nothing ticking the store is the mirror image of the expected case: routines
    /// silently stop firing, which is a warning even though nothing is duplicated.
    #[test]
    fn status_warns_when_nothing_ticks_the_store_and_spawning_is_off() {
        let root = scratch("status-nothing");
        let engine = engine_dir(&root);

        let reported = status(&engine, false, Ok(Vec::new()));
        assert_eq!(reported.verdict, Verdict::Warn, "{reported:?}");
        assert!(reported.detail.contains("routines will not fire"), "{}", reported.detail);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A check that could not be evaluated is a failure, never a quiet `ok`.
    #[test]
    fn status_fails_when_the_scan_itself_failed() {
        let root = scratch("status-unreadable");
        let engine = engine_dir(&root);

        let reported = status(&engine, false, Err("cannot read /proc: permission denied".to_string()));
        assert_eq!(reported.verdict, Verdict::Fail, "{reported:?}");
        assert_eq!(reported.verdict.as_str(), "fail");
        assert!(reported.detail.contains("could not check"), "{}", reported.detail);
        assert!(reported.detail.contains("permission denied"), "{}", reported.detail);
        assert!(reported.owners.is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }
}
