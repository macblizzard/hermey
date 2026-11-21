//! The bot desktop as a container — for hosts where the engine's Xvfb sandbox cannot run (macOS).
//!
//! Same product behaviour as the Linux path: `GET /v1/display/status|thumbnail`, `POST /v1/display/
//! start|stop|observe`, and a viewer socket. The difference is only *where* the sandbox lives: one
//! container per bot instead of a process tree.
//!
//! Chosen when `HERMEY_DISPLAY_BACKEND=container`, or automatically on a non-Linux host that has a
//! container runtime (a Mac). `HERMEY_DISPLAY_BACKEND=engine` forces the engine path, which is what
//! Linux uses.
//!
//! Isolation, which is the whole point of the container:
//!
//! * RFB is published as `127.0.0.1:<port>:5900` — loopback only, so nothing on the LAN or the tailnet
//!   reaches it directly; the viewer goes through this service and its single-use ticket.
//! * The container mounts nothing: no owner files, no `/tmp/.X11-unix`, no host `DISPLAY`.
//! * `stop` removes it, so a bot desktop leaves no state behind beyond its image.

use crate::routes::AppState;
use axum::extract::ws::{Message, WebSocket};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const RFB_PORT: u16 = 5900;
const PORT_BASE: u16 = 5910;
const PORT_SPAN: u16 = 40;
const TICKET_TTL: Duration = Duration::from_secs(60);

fn env(name: &str, default: &str) -> String {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty()).unwrap_or_else(|| default.to_string())
}

pub fn image() -> String {
    env("HERMEY_BOTDESKTOP_IMAGE", "hermey-botdesktop:1")
}

fn docker() -> &'static str {
    "docker"
}

fn has_runtime() -> bool {
    Command::new(docker()).arg("version").arg("--format").arg("{{.Server.Version}}").output().map(|o| o.status.success()).unwrap_or(false)
}

/// Whether this host should use the container backend.
pub fn active() -> bool {
    match env("HERMEY_DISPLAY_BACKEND", "auto").as_str() {
        "container" => has_runtime(),
        "engine" => false,
        _ => !cfg!(target_os = "linux") && has_runtime(),
    }
}

fn container_name(profile: &str) -> String {
    format!("hermey-botdesktop-{profile}")
}

fn run(args: &[&str]) -> (bool, String, String) {
    match Command::new(docker()).args(args).output() {
        Ok(out) => (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).trim().to_string(),
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ),
        Err(e) => (false, String::new(), format!("docker not runnable: {e}")),
    }
}

fn image_present() -> bool {
    run(&["image", "inspect", &image()]).0
}

fn container_running(profile: &str) -> bool {
    let name = container_name(profile);
    let (ok, out, _) = run(&["inspect", "-f", "{{.State.Running}}", &name]);
    ok && out == "true"
}

/// A free loopback port for this bot, stable while the container exists.
fn published_port(profile: &str) -> u16 {
    let name = container_name(profile);
    let (ok, out, _) = run(&["port", &name, &format!("{RFB_PORT}/tcp")]);
    if ok {
        // e.g. "127.0.0.1:5913"
        if let Some(port) = out.rsplit(':').next().and_then(|p| p.trim().parse::<u16>().ok()) {
            return port;
        }
    }
    // Not running: pick the first free port in our own range, so two bots never share a screen.
    for offset in 0..PORT_SPAN {
        let candidate = PORT_BASE + offset;
        if std::net::TcpListener::bind(("127.0.0.1", candidate)).is_ok() {
            return candidate;
        }
    }
    PORT_BASE
}

fn geometry(profile: &str) -> String {
    let name = container_name(profile);
    let (ok, out, _) = run(&["inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", &name]);
    if ok {
        for line in out.lines() {
            if let Some(value) = line.strip_prefix("GEOMETRY=") {
                return value.trim().to_string();
            }
        }
    }
    "1440x900".to_string()
}

/// Stop leftover containers whose name we own but which no longer answer — a restart leaves these.
pub fn status(profile: &str) -> Value {
    let running = container_running(profile);
    let installed = image_present();
    let blocker = if !has_runtime() {
        Some("no container runtime on this host — install Docker or Podman for the bot desktop".to_string())
    } else if !installed {
        Some(format!("the bot desktop image {} is not built", image()))
    } else {
        None
    };
    json!({
        "profile": profile,
        "running": running,
        "installed": installed && has_runtime(),
        "display": if running { Some(format!("container:{}", container_name(profile))) } else { None },
        "geometry": if running { Some(geometry(profile)) } else { Some("1440x900".to_string()) },
        "blocker": blocker,
        "lease": Value::Null,
    })
}

pub fn start(profile: &str) -> Result<Value, String> {
    if !has_runtime() {
        return Err("no container runtime on this host".to_string());
    }
    if !image_present() {
        return Err(format!("the bot desktop image {} is not built (scripts/build-botdesktop-image.sh)", image()));
    }
    if container_running(profile) {
        return Ok(status(profile));
    }
    // A stopped container with our name would make `docker run` fail: remove it and start clean.
    let _ = run(&["rm", "-f", &container_name(profile)]);
    let port = published_port(profile);
    let publish = format!("127.0.0.1:{port}:{RFB_PORT}");
    let geometry = format!("GEOMETRY={}", env("HERMEY_BOTDESKTOP_GEOMETRY", "1440x900"));
    let (ok, _, err) = run(&[
        "run", "-d", "--rm",
        "--name", &container_name(profile),
        "-p", &publish,
        "-e", &geometry,
        &image(),
    ]);
    if !ok {
        return Err(format!("docker run failed: {err}"));
    }
    // Wait for the RFB *greeting*, not merely a TCP connect: docker-proxy accepts the connection the
    // instant the container is created, so a connect-only check reports "running" while x11vnc is still
    // starting — and the first viewer then gets a socket that closes with no frames (measured).
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Ok(mut stream) = std::net::TcpStream::connect(("127.0.0.1", port)) {
            let _ = stream.set_read_timeout(Some(Duration::from_millis(700)));
            let mut greeting = [0u8; 12];
            if let Ok(n) = std::io::Read::read(&mut stream, &mut greeting) {
                if n >= 4 && &greeting[..4] == b"RFB " {
                    return Ok(status(profile));
                }
            }
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    Err("the desktop started but its screen never answered".to_string())
}

pub fn stop(profile: &str) -> Value {
    let _ = run(&["rm", "-f", &container_name(profile)]);
    status(profile)
}

/// One JPEG of the sandbox screen, as a data URL.
pub fn thumbnail(profile: &str) -> Option<String> {
    if !container_running(profile) {
        return None;
    }
    let script = "import -window root /tmp/hermey-shot.jpg 2>/dev/null && base64 -w0 /tmp/hermey-shot.jpg";
    let (ok, out, _) = run(&["exec", &container_name(profile), "sh", "-c", script]);
    if !ok || out.is_empty() {
        return None;
    }
    Some(format!("data:image/jpeg;base64,{out}"))
}

// ---- viewer tickets: single use, bound to a profile and its port -------------------------------

struct TicketEntry {
    profile: String,
    port: u16,
    expires: Instant,
}

fn tickets() -> &'static Mutex<Vec<(String, TicketEntry)>> {
    static TICKETS: OnceLock<Mutex<Vec<(String, TicketEntry)>>> = OnceLock::new();
    TICKETS.get_or_init(|| Mutex::new(Vec::new()))
}

pub fn mint_ticket(profile: &str) -> Option<(String, String, u16)> {
    if !container_running(profile) {
        return None;
    }
    let port = published_port(profile);
    let ticket = crate::auth::random_token(18);
    let mut list = tickets().lock().unwrap();
    list.retain(|(_, e)| e.expires > Instant::now());
    list.push((ticket.clone(), TicketEntry { profile: profile.to_string(), port, expires: Instant::now() + TICKET_TTL }));
    Some((ticket, profile.to_string(), port))
}

fn redeem(ticket: &str) -> Option<u16> {
    let mut list = tickets().lock().unwrap();
    list.retain(|(_, e)| e.expires > Instant::now());
    let index = list.iter().position(|(t, _)| t == ticket)?;
    let (_, entry) = list.remove(index);
    Some(entry.port)
}

/// Reserve a bring-up scratch dir (unused today, kept so the engine path and this one share a struct).
#[allow(dead_code)]
fn scratch(profile: &str) -> PathBuf {
    PathBuf::from(format!("/tmp/hermey-botdesktop-{profile}"))
}

/// The viewer socket for the container backend: dial the sandbox's RFB and carry RFB in binary frames,
/// exactly like the engine path does, so the app's viewer does not change.
pub async fn splice_viewer(mut client: WebSocket, ticket: String) {
    let redeemed = redeem(&ticket);
    let Some(port) = redeemed else {
        let _ = client
            .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                code: 4401,
                reason: "ticket invalid or already used".to_string().into(),
            })))
            .await;
        return;
    };
    let Ok(mut stream) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await else {
        let _ = client
            .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                code: 1011,
                reason: "the bot desktop is not answering".to_string().into(),
            })))
            .await;
        return;
    };
    let (mut tcp_read, mut tcp_write) = stream.split();
    let mut buffer = [0u8; 16 * 1024];
    loop {
        tokio::select! {
            from_client = client.recv() => {
                let Some(Ok(message)) = from_client else { break };
                let bytes: Vec<u8> = match message {
                    Message::Binary(b) => b.to_vec(),
                    Message::Text(t) => t.to_string().into_bytes(),
                    Message::Close(_) => break,
                    _ => continue,
                };
                if tokio::io::AsyncWriteExt::write_all(&mut tcp_write, &bytes).await.is_err() {
                    break;
                }
            }
            from_sandbox = tokio::io::AsyncReadExt::read(&mut tcp_read, &mut buffer) => {
                match from_sandbox {
                    Ok(0) => break,
                    Err(_) => break,
                    Ok(n) => {
                        if client.send(Message::Binary(buffer[..n].to_vec().into())).await.is_err() {
                            break;
                        }
                    }
                }
            }
        }
    }
}

/// Kept for callers that want the sandbox's RFB address (diagnostics, tests).
#[allow(dead_code)]
pub fn rfb_endpoint(profile: &str) -> String {
    format!("127.0.0.1:{}", published_port(profile))
}

#[allow(dead_code)]
fn _unused(_: &AppState) {}
