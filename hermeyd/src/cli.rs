//! The command line, parsed before anything boots.
//!
//! Two rules, both learned the hard way on a live host:
//!
//! * **`--help` must never start the daemon.** Help is the first thing a person types after an
//!   install, on a box where the service is not running and the state directory may not be writable.
//!   Parsing therefore happens before `create_dir_all`, before the token is minted, before skills are
//!   installed, before any listener and before the engine is probed. A `--help` that prints a boot
//!   banner and holds a port is indistinguishable from a hang.
//! * **The shell needs the same two things the app does.** `pair` mints a code over the same loopback
//!   route the app's own host does (no second code path, no second TTL), and `status` answers the
//!   questions a person actually asks: is it up, is the engine up, where is the token, what host does
//!   pairing name, and does the gateway guard object.

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::gateway_guard;
use crate::local_token;

/// What the arguments asked for. `Serve` is the absence of a subcommand, which is how every existing
/// unit file and launcher already invokes the binary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    Serve,
    Help(Option<Topic>),
    Version,
    GatewayCheck,
    Pair { json: bool, host: Option<String> },
    Status { json: bool },
}

/// The subcommands `help <topic>` knows. Anything else is a usage error, not a silent full usage dump.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Topic {
    Pair,
    Status,
}

pub fn usage() -> String {
    format!(
        "hermeyd {version} — the Hermey host service (pairing, device registry, relay front door)

USAGE
  hermeyd                            Run the service in the foreground. This is what systemd does.
  hermeyd pair [--json] [--host H]
                                     Mint a pairing code and print the URL to open in the app.
  hermeyd status [--json]            One screen: service, engine, token, browser channel, gateway.
  hermeyd help [COMMAND]             Print this text (or one command's), then exit.

FLAGS
  -h, --help                         Print usage and exit. Starts nothing, mints nothing.
  -V, --version                      Print the version and exit.
      --gateway-check                Exit 0 when no other gateway owns the engine home, 75 when one
                                     does. Never spawns or kills a process.
      --json                         (pair, status) Print the object a script can parse.
      --host H                       (pair) Name this host in the pairing URL instead of the value
                                     the service reports (HERMEYD_PUBLIC_HOST).

ENVIRONMENT
  HERMEYD_HOME                       State directory: token, salt, database (default ~/.hermey).
  HERMEYD_PORT                       Service port (default 8788); pair/status dial this port.
  HERMEYD_BIND                       Bind address, loopback only (default 127.0.0.1).
  HERMEYD_BROWSER_PORT               Sign-in / browser channel port (default 8790).
  HERMEYD_PUBLIC_HOST                Host the pairing URL names (default localhost).
  HERMEYD_ENGINE_HOME                Engine home whose profiles, skills and cron store are used.
  HERMEYD_ENGINE_WS                  Engine WebSocket API (default ws://127.0.0.1:9121/api/ws).
  HERMEYD_LOCAL_TOKEN_FILE           Override the local CLI token path.

EXAMPLES
  hermeyd pair                       # code + https://<host>/?code=<code>
  hermeyd pair --json | jq -r .code
  hermeyd status                     # is the service, engine and token file healthy?
",
        version = crate::VERSION
    )
}

fn pair_usage() -> String {
    format!(
        "hermeyd pair — mint a pairing code from the shell

USAGE
  hermeyd pair [--json] [--host HOST]

Mints a code through POST /v1/pair/start on the running service (loopback only), authenticating
with the local token at <state>/local.token. Prints the code, when it expires, and a ready-to-paste
pairing URL: https://<host>/?code=<code>

  --json        Print the route's JSON object verbatim, for scripts.
  --host HOST   Override the host in the pairing URL (the service reports HERMEYD_PUBLIC_HOST).

ENVIRONMENT
  HERMEYD_PORT               Port the service is listening on (default 8788).
  HERMEYD_HOME               State directory holding local.token (default ~/.hermey).
  HERMEYD_LOCAL_TOKEN_FILE   Read the token from this path instead.
"
    )
}

fn status_usage() -> String {
    format!(
        "hermeyd status — one screen on this host's service

USAGE
  hermeyd status [--json]

Checks, each on its own line with an ok / warn / fail marker: the service answers, the engine's
WebSocket port accepts connections, the pairing host, the local token file and whether it is
readable, the browser channel port, paired devices, and the gateway guard's decision.

  --json        Print the same facts as one JSON object, for scripts.

ENVIRONMENT
  HERMEYD_PORT, HERMEYD_BROWSER_PORT, HERMEYD_PUBLIC_HOST, HERMEYD_ENGINE_HOME,
  HERMEYD_ENGINE_WS, HERMEYD_LOCAL_TOKEN_FILE — same defaults as the service itself.
"
    )
}

pub fn usage_for(topic: Option<Topic>) -> String {
    match topic {
        None => usage(),
        Some(Topic::Pair) => pair_usage(),
        Some(Topic::Status) => status_usage(),
    }
}

/// Parse `std::env::args().skip(1)`.
///
/// `--help` and `--version` win over everything else and are answered without touching the world:
/// they are the only flags that must work on a box where nothing has been installed yet.
pub fn parse(args: &[String]) -> Result<Command, String> {
    let mut help = false;
    let mut version = false;
    let mut gateway_check = false;
    let mut json = false;
    let mut host: Option<String> = None;
    let mut positional: Vec<String> = Vec::new();

    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        match arg {
            "-h" | "--help" | "help" => help = true,
            "-V" | "--version" => version = true,
            "--gateway-check" => gateway_check = true,
            "--json" => json = true,
            "--host" => {
                let value = args.get(i + 1).ok_or_else(|| {
                    "--host needs a value, e.g. `hermeyd pair --host my-mac.ts.net`".to_string()
                })?;
                host = Some(value.clone());
                i += 1;
            }
            _ if arg.starts_with("--host=") => {
                host = Some(arg["--host=".len()..].to_string());
            }
            _ if arg.starts_with('-') => {
                return Err(format!("unknown flag `{arg}`"));
            }
            _ => positional.push(arg.to_string()),
        }
        i += 1;
    }

    let command = positional.first().map(String::as_str);

    if help {
        let topic = match command {
            None | Some("help") => None,
            Some("pair") => Some(Topic::Pair),
            Some("status") => Some(Topic::Status),
            Some(other) => {
                return Err(format!("unknown command `{other}` (try `hermeyd --help`)"));
            }
        };
        return Ok(Command::Help(topic));
    }
    if version || command == Some("version") {
        return Ok(Command::Version);
    }

    let command = match command {
        None => {
            return Ok(if gateway_check { Command::GatewayCheck } else { Command::Serve });
        }
        Some(name) => name,
    };
    // A subcommand and nothing after it, except the flags that subcommand owns.
    let extra = positional.len().saturating_sub(1);
    match command {
        "pair" => {
            if extra > 0 {
                return Err(format!(
                    "`hermeyd pair` takes no arguments (got `{}`); see `hermeyd pair --help`",
                    positional[1]
                ));
            }
            if gateway_check {
                return Err("`--gateway-check` is a flag of the service, not of `pair`".to_string());
            }
            Ok(Command::Pair { json, host })
        }
        "status" => {
            if extra > 0 {
                return Err(format!(
                    "`hermeyd status` takes no arguments (got `{}`); see `hermeyd status --help`",
                    positional[1]
                ));
            }
            if host.is_some() {
                return Err("`--host` belongs to `hermeyd pair`, not `status`".to_string());
            }
            if gateway_check {
                return Err("`--gateway-check` is a flag of the service, not of `status`".to_string());
            }
            Ok(Command::Status { json })
        }
        other => Err(format!("unknown command `{other}` (try `hermeyd --help`)")),
    }
}

/// Everything `pair` and `status` need to reach the local service, resolved exactly as boot resolves
/// it — one source of truth for the port, the token path and the engine socket.
pub struct Target {
    pub home: PathBuf,
    pub engine_home: PathBuf,
    pub port: u16,
    pub browser_port: u16,
    pub public_host: String,
    pub engine_ws: String,
}

impl Target {
    pub fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn token_path(&self) -> PathBuf {
        local_token::token_path(&self.home)
    }

    /// The local CLI bearer, when it can be read. Its absence is not fatal: `pair/start` is loopback
    /// only, so an unreadable token still mints — but sending it is what a bearer-checked route in
    /// front would need, and it costs one `read_to_string`.
    pub fn token(&self) -> Option<String> {
        if let Ok(value) = std::env::var(local_token::TOKEN_ENV) {
            let value = value.trim();
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
        std::fs::read_to_string(self.token_path())
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }
}

fn epoch_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// A clock time, in the host's timezone, for a route's `expires_at` (seconds since the epoch).
/// `chrono` would be one more dependency for four numbers; `libc::localtime_r` is already here.
fn clock(epoch: f64) -> String {
    let secs = epoch as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let ok = unsafe { !libc::localtime_r(&secs, &mut tm).is_null() };
    if !ok {
        return format!("{secs} (epoch seconds)");
    }
    let offset = tm.tm_gmtoff;
    let sign = if offset < 0 { '-' } else { '+' };
    let offset = offset.abs();
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02} {sign}{:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        offset / 3600,
        (offset % 3600) / 60
    )
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
}

/// The single sentence for "the service is not running", said the same way in `pair` and `status`.
fn not_running(target: &Target) -> String {
    format!(
        "hermeyd is not running on 127.0.0.1:{} (connection refused).\n\
         Start it with `hermeyd` (or `sudo systemctl start hermeyd`), then try again.",
        target.port
    )
}

fn route_error(target: &Target, status: reqwest::StatusCode, body: &str) -> String {
    let detail = body.trim();
    if detail.is_empty() {
        format!(
            "the service on 127.0.0.1:{} answered {}",
            target.port, status
        )
    } else {
        format!(
            "the service on 127.0.0.1:{} answered {}: {}",
            target.port, status, detail
        )
    }
}

/// `hermeyd pair` — mint through the route the app's own host uses, then say how to use it.
/// Returns the process exit code.
pub async fn run_pair(target: &Target, json_out: bool, host_override: Option<String>) -> i32 {
    let url = format!("{}/v1/pair/start", target.base());
    let mut request = client().post(&url);
    if let Some(token) = target.token() {
        request = request.bearer_auth(token);
    }

    let response = match request.send().await {
        Ok(r) => r,
        Err(e) if e.is_connect() => {
            eprintln!("{}", not_running(target));
            return 1;
        }
        Err(e) => {
            eprintln!("could not reach the service on 127.0.0.1:{}: {e}", target.port);
            return 1;
        }
    };

    let status = response.status();
    let body = match response.text().await {
        Ok(b) => b,
        Err(e) => {
            eprintln!("the service answered {status} but the body could not be read: {e}");
            return 1;
        }
    };
    if !status.is_success() {
        eprintln!("could not mint a pairing code — {}", route_error(target, status, &body));
        if status == reqwest::StatusCode::FORBIDDEN {
            eprintln!("pairing codes are minted on the host itself; run this on the machine running hermeyd.");
        }
        return 1;
    }

    if json_out {
        // Verbatim: a script asked for the route's object, not this binary's opinion of it.
        println!("{}", body.trim());
        return 0;
    }

    let value: Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("the service answered 200 with a body that is not JSON ({e}): {body}");
            return 1;
        }
    };
    let code = value.get("code").and_then(Value::as_str).unwrap_or_default();
    if code.is_empty() {
        eprintln!("the service answered 200 without a `code` field: {body}");
        return 1;
    }
    let expires_at = value.get("expires_at").and_then(Value::as_f64).unwrap_or(0.0);
    let host = host_override
        .clone()
        .or_else(|| value.get("host").and_then(Value::as_str).map(str::to_string))
        .unwrap_or_else(|| "localhost".to_string());
    let protocol = value
        .get("protocol_version")
        .and_then(Value::as_u64)
        .map(|v| v.to_string())
        .unwrap_or_else(|| "?".to_string());

    // Rounded, not floored: a code just minted with a 600 s TTL is "10 min left", not "9".
    let minutes = ((expires_at - epoch_now()) / 60.0).max(0.0);
    let encoded = urlencoding::encode(code);
    println!("pairing code  {code}");
    println!("expires       {} ({minutes:.0} min left)", clock(expires_at));
    println!("pairing URL   https://{host}/?code={encoded}");
    println!("protocol      {protocol}");
    println!();
    println!("Open Hermey, or open that URL on a device on the same tailnet. The code is single-use.");
    0
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mark {
    Ok,
    Warn,
    Fail,
}

impl Mark {
    fn word(&self) -> &'static str {
        match self {
            Mark::Ok => "ok",
            Mark::Warn => "warn",
            Mark::Fail => "fail",
        }
    }
    fn failed(&self) -> bool {
        matches!(self, Mark::Fail)
    }
}

/// TCP reachability with a short deadline: the cheap, honest question for "is something listening".
async fn listening(addr: &str) -> Result<(), String> {
    match tokio::time::timeout(Duration::from_millis(900), tokio::net::TcpStream::connect(addr)).await {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("timed out".to_string()),
    }
}

/// `host:port` out of a `ws://` / `wss://` / `http://` URL. Defaults to the engine's own port so a
/// malformed value still answers something a person can act on.
fn socket_of(url: &str) -> String {
    let rest = url
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(url);
    let authority = rest.split('/').next().unwrap_or(rest);
    if authority.contains(':') {
        authority.to_string()
    } else if url.starts_with("wss://") || url.starts_with("https://") {
        format!("{authority}:443")
    } else {
        format!("{authority}:80")
    }
}

/// `hermeyd status` — one line per fact, with a marker a person can scan.
pub async fn run_status(target: &Target, json_out: bool) -> i32 {
    let http = client();

    // 1. The service itself. Unauthenticated by design; says only that it is alive.
    let health = http.get(format!("{}/v1/health", target.base())).send().await;
    let (service, service_detail, protocol): (Mark, String, Option<u64>) = match health {
        Ok(r) if r.status().is_success() => match r.json::<Value>().await {
            Ok(v) => (
                Mark::Ok,
                "answers /v1/health".to_string(),
                v.get("protocol_version").and_then(Value::as_u64),
            ),
            Err(e) => (Mark::Warn, format!("answered but the body is not JSON: {e}"), None),
        },
        Ok(r) => (Mark::Fail, format!("answered {}", r.status()), None),
        Err(e) if e.is_connect() => (Mark::Fail, "not reachable (connection refused)".to_string(), None),
        Err(e) => (Mark::Fail, format!("not reachable: {e}"), None),
    };

    // 2. The engine's WebSocket port — the relay's other half.
    let engine_addr = socket_of(&target.engine_ws);
    let (engine, engine_detail) = match listening(&engine_addr).await {
        Ok(()) => (Mark::Ok, format!("{engine_addr} accepts connections")),
        Err(e) => (
            Mark::Warn,
            format!("nothing listening on {engine_addr} ({e}) — start `hermes gateway run`"),
        ),
    };

    // A pairing URL naming `localhost` is only useful on the host itself.
    let pairing_host = target.public_host.clone();
    let pairing_mark = if pairing_host == "localhost" || pairing_host.is_empty() {
        Mark::Warn
    } else {
        Mark::Ok
    };
    let pairing_detail = if pairing_host == "localhost" {
        "— URLs will only work on this host; set HERMEYD_PUBLIC_HOST to the tailnet name".to_string()
    } else {
        format!("— https://{pairing_host}/?code=…")
    };

    // 3. The credential the shell and the bundled scripts use.
    let token_path = target.token_path();
    let token_readable = std::fs::read_to_string(&token_path)
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false);
    let token_mark = if token_readable { Mark::Ok } else { Mark::Warn };
    let token_detail = if token_readable {
        format!("{} (readable)", token_path.display())
    } else if token_path.exists() {
        format!("{} exists but is empty or unreadable (run as the service's user)", token_path.display())
    } else {
        format!("{} not found — minted at the first boot", token_path.display())
    };

    // 4. The browser channel: separate listener, loopback only, no credential.
    let browser_addr = format!("127.0.0.1:{}", target.browser_port);
    let browser = match listening(&browser_addr).await {
        Ok(()) => Mark::Ok,
        Err(_) => Mark::Warn,
    };
    let browser_detail = if matches!(browser, Mark::Ok) {
        format!("{browser_addr} accepts connections")
    } else {
        format!("nothing listening on {browser_addr} (HERMEYD_BROWSER_PORT)")
    };

    // 5. Devices, if the token lets us ask. `devices` needs a bearer; a missing one costs a line, not
    //    the whole screen.
    let (device_mark, device_detail, devices_total, devices_active) =
        match (!service.failed(), target.token()) {
            (true, Some(token)) => {
                let response = http
                    .get(format!("{}/v1/devices", target.base()))
                    .bearer_auth(token)
                    .send()
                    .await;
                match response {
                    Ok(r) if r.status().is_success() => match r.json::<Value>().await {
                        Ok(Value::Array(rows)) => {
                            let total = rows.len();
                            let active = rows
                                .iter()
                                .filter(|row| {
                                    !row.get("revoked")
                                        .and_then(Value::as_bool)
                                        .unwrap_or(false)
                                })
                                .count();
                            (
                                if active > 0 { Mark::Ok } else { Mark::Warn },
                                format!("{active} active, {total} total"),
                                Some(total),
                                Some(active),
                            )
                        }
                        Ok(other) => (
                            Mark::Warn,
                            format!("unexpected /v1/devices body: {other}"),
                            None,
                            None,
                        ),
                        Err(e) => (Mark::Warn, format!("unreadable /v1/devices body: {e}"), None, None),
                    },
                    Ok(r) => (Mark::Warn, format!("/v1/devices answered {}", r.status()), None, None),
                    Err(e) => (Mark::Warn, format!("/v1/devices failed: {e}"), None, None),
                }
            }
            (true, None) => (
                Mark::Warn,
                "not asked — no local token to authenticate with".to_string(),
                None,
                None,
            ),
            (false, _) => (Mark::Warn, "not asked — the service is not answering".to_string(), None, None),
        };

    // 6. Exactly what `--gateway-check` decides, for the home a boot would use. `evaluate`, not
    //    `check`: the decision is this command's output, so it must not also be logged to stderr.
    let decision = gateway_guard::evaluate(&target.engine_home, true);
    let gateway = if decision.refused() { Mark::Fail } else { Mark::Ok };
    let gateway_detail = format!("{} for {}", decision.as_str(), target.engine_home.display());
    let gateway_explain = match &decision {
        gateway_guard::Decision::Refuse(owners) => {
            Some(gateway_guard::refusal_message(&target.engine_home, owners))
        }
        _ => None,
    };

    let failed = service.failed() || gateway.failed();

    if json_out {
        let facts = json!({
            "version": crate::VERSION,
            "ok": !failed,
            "port": target.port,
            "service": {
                "reachable": !service.failed(),
                "url": target.base(),
                "detail": service_detail,
                "protocol_version": protocol,
            },
            "engine": {
                "url": target.engine_ws,
                "reachable": matches!(engine, Mark::Ok),
                "detail": engine_detail,
            },
            "pairing_host": pairing_host,
            "token": {
                "path": token_path.display().to_string(),
                "readable": token_readable,
            },
            "browser_channel": {
                "addr": browser_addr,
                "reachable": matches!(browser, Mark::Ok),
            },
            "devices": {
                "active": devices_active,
                "total": devices_total,
            },
            "gateway_check": {
                "decision": decision.as_str(),
                "home": target.engine_home.display().to_string(),
                "detail": gateway_explain,
            },
        });
        println!("{}", serde_json::to_string_pretty(&facts).unwrap_or_else(|_| "{}".to_string()));
    } else {
        println!("hermeyd {} — status on 127.0.0.1:{}", crate::VERSION, target.port);
        println!();
        let line = |mark: &Mark, label: &str, detail: &str| {
            println!("{:<5} {:<16} {}", mark.word(), label, detail);
        };
        // The protocol only means something when the service answered with one.
        let service_line = match protocol {
            Some(p) => format!("{service_detail} (protocol {p})"),
            None => service_detail.clone(),
        };
        line(&service, "service", &service_line);
        line(&engine, "engine", &engine_detail);
        line(&pairing_mark, "pairing host", &format!("{pairing_host} {pairing_detail}"));
        line(&token_mark, "local token", &token_detail);
        line(&browser, "browser channel", &browser_detail);
        line(&device_mark, "devices", &device_detail);
        line(&gateway, "gateway-check", &gateway_detail);
        // A refusal names the pids that own the ticker and the remedy; that is the whole value of the
        // check, so it is printed rather than folded into one line.
        if let Some(explain) = &gateway_explain {
            for detail in explain.lines() {
                println!("      {detail}");
            }
        }
    }

    if failed {
        1
    } else {
        0
    }
}

/// Resolve the target once, from the same environment boot reads. Never creates the state directory:
/// `status` must be safe to run on a host where nothing has started yet.
pub fn target(home: PathBuf, engine_home: PathBuf) -> Target {
    Target {
        home,
        engine_home,
        port: std::env::var("HERMEYD_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(8788),
        browser_port: std::env::var("HERMEYD_BROWSER_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(8790),
        public_host: std::env::var("HERMEYD_PUBLIC_HOST").unwrap_or_else(|_| "localhost".to_string()),
        engine_ws: std::env::var("HERMEYD_ENGINE_WS")
            .unwrap_or_else(|_| "ws://127.0.0.1:9121/api/ws".to_string()),
    }
}

/// Paths as `pair`/`status` should discover them, without the side effects of boot.
pub fn resolve_paths() -> (PathBuf, PathBuf) {
    let home = crate::hermes_home();
    let engine_home = std::env::var("HERMEYD_ENGINE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| crate::default_engine_home(&home));
    (home, engine_home)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(line: &str) -> Vec<String> {
        line.split_whitespace().map(str::to_string).collect()
    }

    #[test]
    fn no_arguments_is_serve() {
        assert_eq!(parse(&[]).unwrap(), Command::Serve);
    }

    #[test]
    fn help_wins_and_takes_the_subcommand_as_topic() {
        assert_eq!(parse(&args("--help")).unwrap(), Command::Help(None));
        assert_eq!(parse(&args("-h")).unwrap(), Command::Help(None));
        assert_eq!(parse(&args("help")).unwrap(), Command::Help(None));
        assert_eq!(parse(&args("pair --help")).unwrap(), Command::Help(Some(Topic::Pair)));
        assert_eq!(parse(&args("help status")).unwrap(), Command::Help(Some(Topic::Status)));
        // `--help` before the subcommand, and help beats a version flag: nothing may boot.
        assert_eq!(parse(&args("--help pair")).unwrap(), Command::Help(Some(Topic::Pair)));
        assert_eq!(parse(&args("--version --help")).unwrap(), Command::Help(None));
    }

    #[test]
    fn version_still_works_alone_and_after_a_subcommand() {
        assert_eq!(parse(&args("--version")).unwrap(), Command::Version);
        assert_eq!(parse(&args("-V")).unwrap(), Command::Version);
        assert_eq!(parse(&args("version")).unwrap(), Command::Version);
    }

    #[test]
    fn pair_and_status_take_their_own_flags() {
        assert_eq!(
            parse(&args("pair")).unwrap(),
            Command::Pair { json: false, host: None }
        );
        assert_eq!(
            parse(&args("pair --json --host mac.ts.net")).unwrap(),
            Command::Pair { json: true, host: Some("mac.ts.net".to_string()) }
        );
        assert_eq!(
            parse(&args("pair --host=mac.ts.net")).unwrap(),
            Command::Pair { json: false, host: Some("mac.ts.net".to_string()) }
        );
        assert_eq!(
            parse(&args("status --json")).unwrap(),
            Command::Status { json: true }
        );
        assert_eq!(parse(&args("status")).unwrap(), Command::Status { json: false });
    }

    #[test]
    fn gateway_check_is_still_a_bare_flag() {
        assert_eq!(parse(&args("--gateway-check")).unwrap(), Command::GatewayCheck);
    }

    #[test]
    fn unknown_input_is_refused_with_a_pointer_to_help() {
        let err = parse(&args("frobnicate")).unwrap_err();
        assert!(err.contains("unknown command `frobnicate`"), "{err}");
        assert!(err.contains("hermeyd --help"), "{err}");
        let err = parse(&args("--nope")).unwrap_err();
        assert!(err.contains("unknown flag `--nope`"), "{err}");
        assert!(parse(&args("pair --host")).is_err());
        assert!(parse(&args("pair extra")).is_err());
        assert!(parse(&args("pair --gateway-check")).is_err());
        assert!(parse(&args("status --host mac.ts.net")).is_err());
    }

    #[test]
    fn usage_names_every_command_and_never_boots() {
        let text = usage();
        for needle in ["hermeyd pair", "hermeyd status", "hermeyd help", "--gateway-check", "--version", "HERMEYD_PORT"] {
            assert!(text.contains(needle), "usage is missing {needle:?}:\n{text}");
        }
        assert!(pair_usage().contains("--json"));
        assert!(status_usage().contains("--json"));
    }

    #[test]
    fn a_ws_url_becomes_a_socket_address() {
        assert_eq!(socket_of("ws://127.0.0.1:9121/api/ws"), "127.0.0.1:9121");
        assert_eq!(socket_of("wss://engine.example/api/ws"), "engine.example:443");
        assert_eq!(socket_of("127.0.0.1:9121"), "127.0.0.1:9121");
    }

    #[test]
    fn a_clock_time_is_rendered_from_epoch_seconds() {
        // 2026-11-21T12:00:00Z, whatever the host's zone: the shape must be a date and a time.
        let rendered = clock(1_795_262_400.0);
        assert_eq!(rendered.len(), "2026-11-21 13:00:00 +01:00".len(), "{rendered}");
        assert!(rendered.starts_with("2026-11-21"), "{rendered}");
        assert!(rendered.contains(':'));
    }
}
