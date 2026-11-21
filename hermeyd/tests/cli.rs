//! What the binary does *before* it becomes a service.
//!
//! These run the real executable, because the bug they exist for lives in `main`: `hermeyd --help`
//! used to fall through to boot — creating the state dir, minting a salt and a local token,
//! installing skills, probing the engine and binding the port. A unit test of the parser would not
//! have caught that; a child process with a temp `HERMEY_HOME` and a spare port does.

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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

/// The one place a child's environment is built: everything hermeyd reads is set or cleared here, so
/// a developer's own `HERMEYD_*` exports cannot make a test pass or fail for the wrong reason.
fn child(home: &Path, engine_home: &Path, port: u16, browser_port: u16, args: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_hermeyd"));
    command
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("HERMEY_HOME", home)
        .env("HERMEYD_ENGINE_HOME", engine_home)
        .env("HERMEYD_PORT", port.to_string())
        .env("HERMEYD_BROWSER_PORT", browser_port.to_string())
        .env("PATH", std::env::var("PATH").unwrap_or_default());
    command
}

fn hermeyd(home: &Path, engine_home: &Path, port: u16, args: &[&str]) -> Output {
    child(home, engine_home, port, free_port(), args)
        .output()
        .expect("run hermeyd")
}

/// A loopback HTTP server that answers by path, with a fixed status and body. Status checks are
/// requests, so the hermetic way to test the answer to a 401 is a service that sends one — not a
/// live install, and not a unit test of the formatter.
fn fake_service(reply: fn(&str) -> Option<(u16, &'static str)>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind fake service");
    let port = listener.local_addr().expect("fake addr").port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = [0u8; 4096];
            let n = stream.read(&mut buffer).unwrap_or(0);
            let request = String::from_utf8_lossy(&buffer[..n]).into_owned();
            let path = request.split_whitespace().nth(1).unwrap_or("/").to_string();
            let (code, body) = reply(&path).unwrap_or((404, "{}"));
            let response = format!(
                "HTTP/1.1 {code} ANSWER\r\ncontent-type: application/json\r\n\
                 content-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });
    port
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

#[test]
fn a_busy_port_refuses_before_creating_any_state() {
    // The bug this is for: a bare `hermeyd` booted, created a state dir, minted a token and wrote a
    // database, and only the bind failed — leaving the wrong state behind in the operator's home.
    let base = scratch("busy");
    let home = base.join("state");
    fs::create_dir_all(&home).unwrap();
    let busy = TcpListener::bind("127.0.0.1:0").expect("occupy a port");
    let port = busy.local_addr().unwrap().port();

    let out = hermeyd(&home, &base.join("engine"), port, &[]);
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    assert_eq!(
        out.status.code(),
        Some(1),
        "a busy port must exit non-zero; stdout:\n{stdout}\nstderr:\n{stderr}"
    );

    for needle in [
        "already accepting connections",
        "a hermeyd service appears to be running",
        "nothing was created or changed",
        "hermeyd status",
        "systemctl status hermeyd",
        "HERMEYD_PORT",
        "HERMEYD_BROWSER_PORT",
        "HERMEYD_HOME",
    ] {
        assert!(stderr.contains(needle), "refusal is missing {needle:?}:\n{stderr}");
    }
    assert!(!stdout.contains("HERMEYD_READY"), "the refusal still booted:\n{stdout}");
    assert!(!stderr.contains("local token:"), "the refusal minted a token:\n{stderr}");
    assert!(listing(&home).is_empty(), "the refusal wrote state: {:?}", listing(&home));

    // And a state directory that did not exist is not created either — that is the exact stranding
    // this pre-flight exists to prevent.
    let absent = base.join("absent");
    let out = hermeyd(&absent, &base.join("engine"), port, &[]);
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert_ne!(out.status.code(), Some(0), "{stderr}");
    assert!(!absent.exists(), "the refusal created {:?}", absent);
    assert!(stderr.contains("would have created"), "{stderr}");

    drop(busy);
    fs::remove_dir_all(&base).ok();
}

#[test]
fn a_state_dir_that_looks_like_a_hermes_home_is_refused() {
    let base = scratch("hermes-home");
    let home = base.join("hermes");
    fs::create_dir_all(home.join("profiles").join("cody")).unwrap();
    fs::write(home.join("profiles").join("cody").join("SOUL.md"), "not ours").unwrap();

    let out = hermeyd(&home, &base.join("engine"), free_port(), &[]);
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert_eq!(out.status.code(), Some(1), "stderr:\n{stderr}");
    for needle in ["refuses to use the state directory", "looks like a Hermes home", "profiles/", "HERMEYD_HOME"] {
        assert!(stderr.contains(needle), "refusal is missing {needle:?}:\n{stderr}");
    }
    // Nothing of this service's was written into the engine home.
    for marker in ["bridge.db", "local.token", "bridge.salt", "bin", "attachments"] {
        assert!(
            !home.join(marker).exists(),
            "the refusal wrote {marker} into a Hermes home: {:?}",
            listing(&home)
        );
    }
    assert_eq!(
        fs::read_to_string(home.join("profiles").join("cody").join("SOUL.md")).unwrap(),
        "not ours",
        "the refusal changed a file in the Hermes home"
    );
    fs::remove_dir_all(&base).ok();
}

#[test]
fn status_with_a_rejected_token_says_so_and_is_not_ok() {
    let home = scratch("status-rejected");
    let token_path = home.join("local.token");
    fs::write(&token_path, "x".repeat(43)).unwrap();
    let port = fake_service(|path| match path {
        "/v1/health" => Some((200, r#"{"protocol_version":2}"#)),
        "/v1/pair/host" => Some((200, r#"{"host":"hermes.example.ts.net"}"#)),
        "/v1/devices" => Some((401, r#"{"error":"unauthorized"}"#)),
        _ => None,
    });

    let out = child(&home, &home.join("engine"), port, free_port(), &["status"]).output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert_eq!(out.status.code(), Some(1), "stdout:\n{stdout}\nstderr:\n{stderr}");

    // The exact sentence: what happened, which credential, and the remedy.
    assert!(stdout.contains("the service is running, but the token at"), "{stdout}");
    assert!(stdout.contains("was refused"), "{stdout}");
    assert!(stdout.contains("that is not the service's token"), "{stdout}");
    assert!(stdout.contains("point HERMEYD_HOME at the running service's state"), "{stdout}");
    // The path that was sent is named, and it is this state dir's token — never the secret.
    assert!(stdout.contains(&token_path.display().to_string()), "{stdout}");
    assert!(!stdout.contains(&"x".repeat(43)), "the token itself was printed:\n{stdout}");

    // The authentication line is a failure, not `ok`, and the state dir it read is on screen.
    let auth_line = stdout
        .lines()
        .find(|line| line.contains("authentication"))
        .unwrap_or_else(|| panic!("no authentication line:\n{stdout}"));
    let auth_mark = auth_line.split_whitespace().next().unwrap_or_default();
    assert_eq!(auth_mark, "fail", "an unauthenticated request must not read as ok: {auth_line}");
    let state_line = stdout
        .lines()
        .find(|line| line.contains("state dir"))
        .unwrap_or_else(|| panic!("no state dir line:\n{stdout}"));
    assert!(state_line.contains(&home.display().to_string()), "{state_line}");
    assert!(state_line.contains("HERMEY_HOME"), "the source is not stated:\n{state_line}");

    // The same facts in the object a script reads: `ok` is false, and why.
    let out = child(&home, &home.join("engine"), port, free_port(), &["status", "--json"])
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let facts: serde_json::Value = serde_json::from_str(&stdout).expect("status --json is JSON");
    assert_eq!(facts["ok"], serde_json::json!(false), "{stdout}");
    assert_eq!(facts["authenticated"], serde_json::json!(false), "{stdout}");
    assert_eq!(facts["auth"]["authenticated"], serde_json::json!(false), "{stdout}");
    assert_eq!(facts["state_dir"]["path"], serde_json::json!(home.display().to_string()));
    assert_eq!(facts["state_dir"]["source"], serde_json::json!(format!("HERMEY_HOME={}", home.display())));
    assert_eq!(
        facts["auth"]["detail"],
        serde_json::json!(format!(
            "the service is running, but the token at {} was refused — that is not the service's \
             token; point HERMEYD_HOME at the running service's state",
            token_path.display()
        )),
        "{stdout}"
    );
    assert_eq!(out.status.code(), Some(1), "{stdout}");
    fs::remove_dir_all(&home).ok();
}

#[test]
fn status_names_the_state_dir_and_token_it_used_when_nothing_runs() {
    let home = scratch("status-inputs");
    let out = hermeyd(&home, &home.join("engine"), free_port(), &["status"]);
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    assert_eq!(out.status.code(), Some(1), "no service must be a failure:\n{stdout}");

    let state_line = stdout
        .lines()
        .find(|line| line.contains("state dir"))
        .unwrap_or_else(|| panic!("no state dir line:\n{stdout}"));
    assert!(state_line.contains(&home.display().to_string()), "{state_line}");
    assert!(state_line.contains("HERMEY_HOME"), "the source is not stated:\n{state_line}");
    let token_line = stdout
        .lines()
        .find(|line| line.contains("local token"))
        .unwrap_or_else(|| panic!("no token line:\n{stdout}"));
    assert!(token_line.contains(&home.join("local.token").display().to_string()), "{token_line}");

    let out = hermeyd(&home, &home.join("engine"), free_port(), &["status", "--json"]);
    let facts: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).expect("JSON");
    assert_eq!(facts["state_dir"]["path"], serde_json::json!(home.display().to_string()));
    assert_eq!(facts["state_dir"]["source"], serde_json::json!(format!("HERMEY_HOME={}", home.display())));
    assert_eq!(facts["state_dir"]["token_path"], serde_json::json!(home.join("local.token").display().to_string()));
    assert_eq!(facts["ok"], serde_json::json!(false), "an unanswered service is not ok");
    fs::remove_dir_all(&home).ok();
}

#[test]
fn a_normal_first_run_announces_the_directory_then_boots() {
    let base = scratch("first-run");
    let home = base.join("state");
    let engine = base.join("engine");
    let port = free_port();
    let browser_port = free_port();

    let mut spawned = child(&home, &engine, port, browser_port, &[])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn hermeyd");

    let stdout = spawned.stdout.take().expect("stdout");
    let stderr = spawned.stderr.take().expect("stderr");
    let stderr_log = Arc::new(Mutex::new(String::new()));
    let sink = Arc::clone(&stderr_log);
    let stderr_reader = std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            let mut log = sink.lock().unwrap();
            log.push_str(&line);
            log.push('\n');
        }
    });
    let (tx, rx) = mpsc::channel();
    let stdout_reader = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    let mut ready = false;
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    while std::time::Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(line) if line.contains("HERMEYD_READY") => {
                ready = true;
                break;
            }
            Ok(_) => continue,
            Err(_) => break,
        }
    }
    let _ = spawned.kill();
    let _ = spawned.wait();
    let _ = stdout_reader.join();
    let _ = stderr_reader.join();
    let log = stderr_log.lock().unwrap().clone();

    assert!(ready, "the service never reported READY; stderr:\n{log}");
    // It said what it was about to do and where, before doing it.
    assert!(log.contains("creating state directory"), "{log}");
    assert!(log.contains(&home.display().to_string()), "{log}");
    // And then it did create the state a boot needs.
    assert!(home.join("bridge.db").is_file(), "no bridge.db in {:?}: {:?}", home, listing(&home));
    assert!(home.join("local.token").is_file(), "no local.token in {:?}: {:?}", home, listing(&home));
    fs::remove_dir_all(&base).ok();
}
