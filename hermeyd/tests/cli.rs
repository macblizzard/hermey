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

// ---------------------------------------------------------------------------------------------
// The engine's own answer about needing a token, and the gateway line that says what happened
// ---------------------------------------------------------------------------------------------

/// The one place a child's environment is extended with engine settings: `child` clears everything,
/// so a test that needs `HERMEYD_ENGINE_WS` added says so here instead of growing another builder.
fn child_with_env(
    home: &Path,
    engine_home: &Path,
    port: u16,
    browser_port: u16,
    extra: &[(&str, &str)],
    args: &[&str],
) -> Command {
    let mut command = child(home, engine_home, port, browser_port, args);
    for (key, value) in extra {
        command.env(key, value);
    }
    command
}

/// Boot the service against whatever engine is at `extra`'s WS URL, wait for READY, and hand back
/// its stderr. Boot is where the token decision is made, so boot is where it has to be readable.
fn boot_and_collect(
    home: &Path,
    engine_home: &Path,
    port: u16,
    browser_port: u16,
    extra: &[(&str, &str)],
) -> (bool, String) {
    let mut spawned = child_with_env(home, engine_home, port, browser_port, extra, &[])
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
            sink.lock().unwrap().push_str(&format!("{line}\n"));
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
    (ready, log)
}

/// A loopback server that answers as both halves at once: an engine (`/api/health`, with whatever
/// `auth_required` this test wants) and the hermeyd service `status` talks to. One port, no live
/// install, and the decision under test is the one the binary actually reads.
fn fake_engine_and_service(auth_required: bool, devices: u16, devices_body: &'static str) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind fake engine");
    let port = listener.local_addr().expect("fake addr").port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = [0u8; 4096];
            let n = stream.read(&mut buffer).unwrap_or(0);
            let request = String::from_utf8_lossy(&buffer[..n]).into_owned();
            let path = request.split_whitespace().nth(1).unwrap_or("/").to_string();
            let (code, body): (u16, String) = match path.as_str() {
                "/api/health" => (
                    200,
                    format!("{{\"ok\":true,\"auth_required\":{auth_required}}}"),
                ),
                "/v1/health" => (200, "{\"protocol_version\":1,\"ws\":true}".to_string()),
                "/v1/pair/host" => (200, "{\"host\":\"hermes.example.ts.net\"}".to_string()),
                "/v1/devices" => (devices, devices_body.to_string()),
                _ => (404, "{}".to_string()),
            };
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

/// `status` asks the engine the same question boot does. Stock Hermes says `auth_required: false`, so
/// the line reads `ok engine auth not required` — and the token file, which is not there at all,
/// does not turn into a warning.
#[test]
fn status_reports_that_the_engine_needs_no_token() {
    let home = scratch("status-auth-off");
    fs::create_dir_all(&home).unwrap();
    fs::write(home.join("local.token"), "x".repeat(43)).unwrap();
    // No engine.token anywhere: with `auth_required: false` that is the expected state.
    let port = fake_engine_and_service(false, 200, "[]");

    let out = child_with_env(
        &home,
        &home.join("engine"),
        port,
        free_port(),
        &[("HERMEYD_ENGINE_WS", &format!("ws://127.0.0.1:{port}/api/ws"))],
        &["status"],
    )
    .output()
    .expect("run status");
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    assert_eq!(out.status.code(), Some(0), "stdout:\n{stdout}");

    let line = stdout
        .lines()
        .find(|line| line.contains("engine auth"))
        .unwrap_or_else(|| panic!("no engine auth line:\n{stdout}"));
    assert!(line.starts_with("ok"), "a token nobody needs is not a warning: {line}");
    assert!(line.contains("not required"), "{line}");
    assert!(line.contains("auth_required=false"), "{line}");

    // The same fact in the object a script reads, where `false` and "unknown" must stay different.
    let out = child_with_env(
        &home,
        &home.join("engine"),
        port,
        free_port(),
        &[("HERMEYD_ENGINE_WS", &format!("ws://127.0.0.1:{port}/api/ws"))],
        &["status", "--json"],
    )
    .output()
    .expect("run status --json");
    let facts: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&out.stdout)).expect("JSON");
    assert_eq!(facts["engine"]["auth"]["decision"], serde_json::json!("not-required"));
    assert_eq!(facts["engine"]["auth"]["required"], serde_json::json!(false));
    fs::remove_dir_all(&home).ok();
}

/// The other side: an engine that does require a token gets the file named, and the decision is
/// `required` — not `ok, nothing to see`.
#[test]
fn status_reports_that_the_engine_needs_the_token() {
    let home = scratch("status-auth-on");
    fs::create_dir_all(&home).unwrap();
    fs::write(home.join("local.token"), "x".repeat(43)).unwrap();
    let port = fake_engine_and_service(true, 200, "[]");

    let out = child_with_env(
        &home,
        &home.join("engine"),
        port,
        free_port(),
        &[("HERMEYD_ENGINE_WS", &format!("ws://127.0.0.1:{port}/api/ws"))],
        &["status"],
    )
    .output()
    .expect("run status");
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();

    let line = stdout
        .lines()
        .find(|line| line.contains("engine auth"))
        .unwrap_or_else(|| panic!("no engine auth line:\n{stdout}"));
    assert!(line.starts_with("ok"), "{line}");
    assert!(line.contains("token "), "{line}");
    assert!(line.contains("engine.token"), "the file it will send is named: {line}");

    let facts: serde_json::Value = serde_json::from_str(
        &String::from_utf8_lossy(
            &child_with_env(
                &home,
                &home.join("engine"),
                port,
                free_port(),
                &[("HERMEYD_ENGINE_WS", &format!("ws://127.0.0.1:{port}/api/ws"))],
                &["status", "--json"],
            )
            .output()
            .unwrap()
            .stdout,
        ),
    )
    .expect("JSON");
    assert_eq!(facts["engine"]["auth"]["decision"], serde_json::json!("required"));
    assert_eq!(facts["engine"]["auth"]["required"], serde_json::json!(true));
    // The *engine's* token file, never this service's own `local.token`: the two are different
    // credentials in different directories, and naming the wrong one sends an operator to the file
    // that was never in question.
    assert_eq!(
        facts["engine"]["auth"]["token_file"],
        serde_json::json!(home.join("engine.token").display().to_string()),
        "{facts}"
    );
    fs::remove_dir_all(&home).ok();
}

/// Inconclusive is not permission. An engine that is down cannot say `auth_required: false`, so the
/// token stays required and `status` says it could not tell — a `warn`, never an `ok`.
#[test]
fn status_says_unknown_when_the_engine_cannot_be_probed() {
    let home = scratch("status-auth-unknown");
    fs::create_dir_all(&home).unwrap();
    fs::write(home.join("local.token"), "x".repeat(43)).unwrap();
    // The service answers; the engine port nothing listens on.
    let port = fake_engine_and_service(false, 200, "[]");
    let dead = free_port();

    let out = child_with_env(
        &home,
        &home.join("engine"),
        port,
        free_port(),
        &[("HERMEYD_ENGINE_WS", &format!("ws://127.0.0.1:{dead}/api/ws"))],
        &["status"],
    )
    .output()
    .expect("run status");
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();

    let line = stdout
        .lines()
        .find(|line| line.contains("engine auth"))
        .unwrap_or_else(|| panic!("no engine auth line:\n{stdout}"));
    assert!(line.starts_with("warn"), "an unanswered probe is not ok: {line}");
    assert!(line.contains("unknown"), "{line}");
    assert!(line.contains("as before"), "the fallback must be stated: {line}");
    assert!(line.contains("engine.token"), "{line}");
    fs::remove_dir_all(&home).ok();
}

/// The boot line: one statement, at the moment the decision is made, naming the socket. Without it,
/// "no `?token=` on the URL" is a change nobody can date from a journal.
#[test]
fn boot_says_no_token_is_required_when_the_engine_asks_for_none() {
    let base = scratch("boot-auth-off");
    let home = base.join("state");
    let engine = base.join("engine");
    let ws_port = fake_engine_and_service(false, 200, "[]");
    let ws = format!("ws://127.0.0.1:{ws_port}/api/ws");

    let (ready, log) = boot_and_collect(&home, &engine, free_port(), free_port(), &[
        ("HERMEYD_ENGINE_WS", &ws),
    ]);
    assert!(ready, "the service never reported READY; stderr:\n{log}");
    assert!(
        log.contains(&format!("engine: no token required by {ws} (auth_required=false)")),
        "the decision is not on stderr:\n{log}"
    );
    // No warning about a token file that is not there: it is not needed, which is the whole point.
    assert!(!log.contains("engine.token"), "a token nobody needs was mentioned:\n{log}");
    // Not "token required by": that substring is inside "no token required by". The claim being
    // ruled out is the *other* decision, which must be prefixed by the socket it applies to.
    assert!(!log.contains("engine: token required by"), "{log}");
    fs::remove_dir_all(&base).ok();
}

/// And the strict half: an engine that is down makes the probe inconclusive, so boot says so and
/// keeps requiring the token exactly as before.
#[test]
fn boot_states_that_an_unanswered_probe_keeps_requiring_the_token() {
    let base = scratch("boot-auth-unknown");
    let home = base.join("state");
    let engine = base.join("engine");
    let dead = free_port();
    let ws = format!("ws://127.0.0.1:{dead}/api/ws");

    let (ready, log) = boot_and_collect(&home, &engine, free_port(), free_port(), &[
        ("HERMEYD_ENGINE_WS", &ws),
    ]);
    assert!(ready, "an unreachable engine must not stop boot; stderr:\n{log}");
    assert!(
        log.contains(&format!(
            "engine: could not confirm the token is unnecessary — \
             http://127.0.0.1:{dead}/api/health did not answer"
        )),
        "the probe's URL and its failure are not named:\n{log}"
    );
    assert!(log.contains("requiring the token at"), "{log}");
    assert!(log.contains("engine.token"), "{log}");
    assert!(!log.contains("auth_required=false"), "nothing proved that:\n{log}");
    fs::remove_dir_all(&base).ok();
}

/// The installer and every script depend on this: `--gateway-check` still exits 0 when no other
/// gateway owns the home, and 75 when one does. Only the wording was allowed to change.
#[test]
fn gateway_check_keeps_its_exit_codes() {
    let base = scratch("gateway-exit");
    let home = base.join("state");
    let engine = base.join("engine");
    fs::create_dir_all(&home).unwrap();

    let out = hermeyd(&home, &engine, free_port(), &["--gateway-check"]);
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert_eq!(out.status.code(), Some(0), "nothing ticks this home; stderr:\n{stderr}");
    assert!(stderr.contains("gateway-check: clear"), "{stderr}");
    fs::remove_dir_all(&base).ok();
}
