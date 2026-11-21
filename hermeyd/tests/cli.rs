//! What the binary does *before* it becomes a service.
//!
//! These run the real executable, because the bug they exist for lives in `main`: `hermeyd --help`
//! used to fall through to boot — creating the state dir, minting a salt and a local token,
//! installing skills, probing the engine and binding the port. A unit test of the parser would not
//! have caught that; a child process with a temp `HERMEY_HOME` and a spare port does.

use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

fn scratch(tag: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!("hermeyd-cli-{tag}-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn free_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind an ephemeral port");
    let port = listener.local_addr().expect("addr").port();
    drop(listener);
    port
}

/// A child with this test's environment stripped of everything hermeyd reads, so a developer's own
/// `HERMEYD_*` exports cannot make a test pass or fail for the wrong reason.
fn hermeyd(home: &Path, engine_home: &Path, port: u16, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_hermeyd"))
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("HERMEY_HOME", home)
        .env("HERMEYD_ENGINE_HOME", engine_home)
        .env("HERMEYD_PORT", port.to_string())
        .env("HERMEYD_BROWSER_PORT", free_port().to_string())
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("run hermeyd")
}

fn listing(dir: &Path) -> Vec<String> {
    if !dir.exists() {
        return Vec::new();
    }
    let mut names: Vec<String> = fs::read_dir(dir)
        .expect("read state dir")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn help_exits_zero_and_does_not_boot_the_daemon() {
    let home = scratch("help");
    let engine = home.join("engine");
    let port = free_port();

    let out = hermeyd(&home, &engine, port, &["--help"]);
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();

    assert_eq!(out.status.code(), Some(0), "stdout:\n{stdout}\nstderr:\n{stderr}");
    assert!(stdout.contains("USAGE"), "usage text missing:\n{stdout}");
    for needle in ["hermeyd pair", "hermeyd status", "--version", "--gateway-check"] {
        assert!(stdout.contains(needle), "usage does not mention {needle}:\n{stdout}");
    }
    // The old failure, stated as an assertion: a boot banner, a token line or a skills line on the
    // help path means the daemon started.
    assert!(!stdout.contains("HERMEYD_READY"), "help booted the service:\n{stdout}");
    assert!(!stdout.contains("HERMEYD_BROWSER_READY"), "help booted the service:\n{stdout}");
    assert!(!stderr.contains("local token"), "help minted a token:\n{stderr}");
    assert!(!stderr.contains("gateway-check:"), "help probed a gateway:\n{stderr}");

    // Nothing was written: no salt, no token, no database, not even a log dir.
    assert!(listing(&home).is_empty(), "help wrote state: {:?}", listing(&home));

    // And no listener was left behind or briefly held: the port (and the browser port) bind cleanly.
    TcpListener::bind(("127.0.0.1", port)).expect("help must not keep the service port");
    fs::remove_dir_all(&home).ok();
}

#[test]
fn help_works_with_no_state_dir_at_all() {
    // A fresh install: HERMEY_HOME points at a path that does not exist yet, and must stay that way.
    let base = scratch("absent");
    let home = base.join("not-created");
    let out = hermeyd(&home, &base.join("engine"), free_port(), &["-h"]);
    assert_eq!(out.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&out.stdout).contains("USAGE"));
    assert!(!home.exists(), "help created {:?}", home);
    fs::remove_dir_all(&base).ok();
}

#[test]
fn pair_against_nothing_says_the_service_is_not_running() {
    let home = scratch("pair-down");
    let out = hermeyd(&home, &home.join("engine"), free_port(), &["pair"]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(1), "stdout:\n{}", String::from_utf8_lossy(&out.stdout));
    assert!(stderr.contains("hermeyd is not running"), "{stderr}");
    assert!(stderr.contains("Start it with"), "no remedy offered:\n{stderr}");
    assert!(!stderr.contains("curl"), "the shell must not explain itself in curl:\n{stderr}");
    fs::remove_dir_all(&home).ok();
}

#[test]
fn an_unknown_command_is_a_usage_error_not_a_boot() {
    let home = scratch("unknown");
    let port = free_port();
    let out = hermeyd(&home, &home.join("engine"), port, &["pari"]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "{stderr}");
    assert!(stderr.contains("unknown command `pari`"), "{stderr}");
    assert!(stderr.contains("USAGE"), "usage is not repeated after an error:\n{stderr}");
    assert!(listing(&home).is_empty(), "a typo wrote state: {:?}", listing(&home));
    fs::remove_dir_all(&home).ok();
}

#[test]
fn version_prints_one_line_and_touches_nothing() {
    let home = scratch("version");
    let out = hermeyd(&home, &home.join("engine"), free_port(), &["--version"]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_eq!(out.status.code(), Some(0));
    assert!(stdout.trim().starts_with("hermeyd "), "{stdout}");
    assert_eq!(stdout.lines().count(), 1, "{stdout}");
    assert!(listing(&home).is_empty(), "version wrote state: {:?}", listing(&home));
    fs::remove_dir_all(&home).ok();
}
