//! hermeyd — the Hermey host service.
//!
//! Owns pairing, the device registry, short-lived credentials and (later) the WS relay in front of
//! the engine. It holds **no agent logic**: the engine is a separate process behind a token, and
//! bots/sessions/transcripts never live here.
//!
//! Binding rules:
//!   * loopback only — plaintext, no TLS, no public listener (Tailscale Serve does exposure);
//!   * port defaults to 8788, deliberately not the production bridge's 8787, so both can run on one
//!     host without touching each other;
//!   * the browser channel has its own loopback listener (8788's port 8790, `HERMEYD_BROWSER_PORT`).
//!     Those three routes carry no device credential, so they must never be reachable through
//!     `tailscale serve`: the extension and the sign-in skill both run on this host.

mod attachments;
mod audit;
mod auth;
mod bot_admin;
mod bot_docs;
mod bot_message;
mod bot_sessions;
mod browser;
mod bridge_routes;
mod cards;
mod backup;
mod cli;
mod credentials;
mod search;
mod transfers;
mod gateway_guard;
mod genui;
mod history;
mod host_env;
mod integrations;
mod local_computers;
mod local_token;
mod display;
mod display_container;
mod engine_auth;
mod engine_client;
mod model_settings;
mod pairing;
mod parity_gaps;
mod preflight;
mod qr;
mod previews;
mod providers;
mod push;
mod relay;
mod routines;
mod rooms;
mod routes;
mod skills;
mod skills_dialect;
mod store;
mod voice;
mod workspace;

use axum::routing::{delete, get, post};
use axum::Router;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

const TICKET_TTL_SECONDS: f64 = 30.0;
const ACCESS_TTL_SECONDS: f64 = 300.0;

/// The service's state directory — one resolution for boot, `pair` and `status`.
///
/// `HERMEYD_HOME` is what this binary's own help documents and what an operator types at a shell;
/// `HERMEY_HOME` is what the systemd unit and a full install set, and what the service has always
/// read. Both are accepted, `HERMEYD_HOME` first. The bug this replaces: the CLI read only one of
/// them, so `status` reported a token in a directory the service never wrote and the device count
/// answered 401.
pub fn state_home() -> PathBuf {
    for key in ["HERMEYD_HOME", "HERMEY_HOME"] {
        if let Ok(value) = std::env::var(key) {
            let value = value.trim();
            if !value.is_empty() {
                return PathBuf::from(value);
            }
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".hermey")
}

/// How [`state_home`] decided, in the words `status` and the first-run line print. A path alone is
/// not enough to debug the failure this exists for: two directories, one token, and no way to tell
/// from the output which one was read.
pub fn state_home_source() -> String {
    for key in ["HERMEYD_HOME", "HERMEY_HOME"] {
        if let Ok(value) = std::env::var(key) {
            let value = value.trim();
            if !value.is_empty() {
                return format!("{key}={value}");
            }
        }
    }
    format!("no HERMEYD_HOME or HERMEY_HOME set, so $HOME/.hermey")
}

/// The engine's home (profiles, memories, skills): the directory Hermes itself uses.
///
/// Resolution order, each candidate accepted only when it really holds `profiles/`:
///   1. beside this service's state (`$HERMEY_HOME/engine`) — a dev checkout beside `var/hermeyd`;
///   2. the development sibling (`var/hermey/engine`);
///   3. `~/.hermes` — where a normal Hermes install lives.
///
/// The old order returned the first *existing* directory without checking it was an engine home,
/// so a user who never set `HERMEYD_ENGINE_HOME` could be served from an empty folder and only
/// notice when their bots had no history. Resolving to the wrong home is exactly how a host ends
/// up with two fleets, so nothing is guessed: a candidate without `profiles/` is not a home.
fn default_engine_home(home: &std::path::Path) -> PathBuf {
    let mut candidates: Vec<PathBuf> = vec![home.join("engine")];
    if let Some(parent) = home.parent() {
        candidates.push(parent.join("hermey").join("engine"));
    }
    if let Some(user_home) = std::env::var_os("HOME").map(PathBuf::from) {
        candidates.push(user_home.join(".hermes"));
    }
    for candidate in &candidates {
        if candidate.join("profiles").is_dir() {
            return candidate.clone();
        }
    }
    // Nothing usable: say so loudly rather than serving an empty home. The caller keeps the
    // path (so `--gateway-check` and the status screen still answer), but the operator is told
    // what to do instead of silently getting bots with no profiles.
    eprintln!(
        "hermeyd: no Hermes engine home found — looked for profiles/ in {}. \
         Set HERMEYD_ENGINE_HOME to the directory Hermes uses (the one containing profiles/).",
        candidates
            .iter()
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    );
    home.join("engine")
}

/// Where the engine writes its per-boot token. Prefers a token beside this service's state, then the
/// sibling engine home used in development (`var/hermeyd` next to `var/hermey`).
pub(crate) fn default_engine_token_file(home: &std::path::Path) -> PathBuf {
    let beside = home.join("engine.token");
    if beside.exists() {
        return beside;
    }
    let sibling = home.parent().map(|p| p.join("hermey").join("engine.token"));
    if let Some(sib) = sibling {
        if sib.exists() {
            return sib;
        }
    }
    beside
}

/// One place for the version: Cargo.toml. `--version` prints it, the boot banner repeats it, and the
/// packages do not carry it (see docs/RELEASE.md).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Arguments first, world second. `--help` and `--version` must work on a box where the service is
    // not running, the state dir is unreadable and no engine was ever installed — so nothing below
    // this match has happened yet: no directory created, no token minted, no skills installed, no
    // engine probed, no listener bound. A help flag that boots the daemon is a bug, not a style
    // question: it printed a boot banner, held the port and read as a hang.
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = match cli::parse(&args) {
        Ok(command) => command,
        Err(message) => {
            eprintln!("hermeyd: {message}\n");
            eprint!("{}", cli::usage());
            std::process::exit(2);
        }
    };

    match command {
        cli::Command::Help(topic) => {
            print!("{}", cli::usage_for(topic));
            return Ok(());
        }
        cli::Command::Version => {
            println!("hermeyd {VERSION}");
            return Ok(());
        }
        // Both subcommands talk to the *running* service over loopback and never boot one. They
        // resolve the same port, token path and engine home boot does, and create nothing.
        cli::Command::Pair { json, host } => {
            let (home, engine_home) = cli::resolve_paths();
            let target = cli::target(home, engine_home);
            std::process::exit(cli::run_pair(&target, json, host).await);
        }
        cli::Command::Status { json } => {
            let (home, engine_home) = cli::resolve_paths();
            let target = cli::target(home, engine_home);
            std::process::exit(cli::run_status(&target, json).await);
        }
        cli::Command::Serve | cli::Command::GatewayCheck => {}
    }

    let home = state_home();
    let home_source = state_home_source();

    // The engine's home decides three things this process must get right before it serves: the
    // `.env` it reads, whether a cron ticker is already running for it, and — further down — which
    // profiles' skills it installs. Resolve it once, first, so an early exit (`--gateway-check`)
    // answers about the same home a real boot would use. Resolution stats, it never creates.
    let engine_home = std::env::var("HERMEYD_ENGINE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_engine_home(&home));

    // `--gateway-check` is what a launcher calls before `hermes gateway run --force`: exit 0 when
    // no other gateway owns this home, 75 (EX_TEMPFAIL) when one does. It never spawns or kills.
    if matches!(command, cli::Command::GatewayCheck) {
        let decision = gateway_guard::check(&engine_home, true);
        eprintln!(
            "gateway-check: {} for {}",
            decision.as_str(),
            engine_home.display()
        );
        std::process::exit(if decision.refused() { 75 } else { 0 });
    }

    let port: u16 = std::env::var("HERMEYD_PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8788);
    // The browser channel's own listener. Separate because the routes below carry no credential and
    // the main port is what `tailscale serve` publishes.
    let browser_port: u16 = std::env::var("HERMEYD_BROWSER_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8790);
    if browser_port == port {
        eprintln!(
            "hermeyd refuses HERMEYD_BROWSER_PORT={browser_port}: the browser channel must not share \
             the published port. Pick another loopback port."
        );
        std::process::exit(1);
    }
    let bind = std::env::var("HERMEYD_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());
    if bind != "127.0.0.1" && bind != "::1" && bind != "localhost" {
        eprintln!("hermeyd refuses to bind {bind}: loopback only. Expose it with `tailscale serve`.");
        std::process::exit(1);
    }

    // Pre-flight, before the first byte is written: the bind that used to fail *after* creating a
    // state directory, minting a token and installing skills is the cheap question, so it is asked
    // first. A refusal here leaves the filesystem exactly as it found it, including a state dir that
    // would have been stranded by the failed bind.
    let ports = preflight::Ports { bind: bind.clone(), port, browser_port };
    if let Err(refusal) = preflight::check(&home, &ports, &home_source) {
        eprintln!("{refusal}");
        std::process::exit(1);
    }

    // Say what is about to happen, and where, before it happens: one line, not a prompt.
    if !home.is_dir() {
        eprintln!(
            "hermeyd: first run — creating state directory {} ({home_source}); local.token, \
             bridge.salt and bridge.db will live there. Set HERMEYD_HOME to use another directory.",
            home.display()
        );
    }

    std::fs::create_dir_all(&home)?;

    // Named once at boot, so "integrations are not configured" always has the file it looked for
    // next to it in the log.
    host_env::log_choice_once(&host_env::select_from_process(&engine_home));
    // Detection only: this service does not own a gateway process, but a duplicate cron ticker is
    // exactly the failure a `--force` launch causes, and boot is where it can still be reported
    // before anything fires twice.
    gateway_guard::check(&engine_home, gateway_guard::spawn_requested());

    // The engine's socket, the file a token would come from, and — the new question — whether the
    // engine wants one at all. Resolved once here: boot, the relay and the display hub must all
    // agree, and the probe should be asked once, not once per connection.
    let engine_ws = std::env::var("HERMEYD_ENGINE_WS")
        .unwrap_or_else(|_| "ws://127.0.0.1:9121/api/ws".to_string());
    let engine_token_file = std::env::var("HERMEYD_ENGINE_TOKEN_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_engine_token_file(&home));
    // Stock Hermes answers `auth_required: false` on `/api/health` while its loopback `/api/ws`
    // still demands the per-boot token, so the probe asks the socket itself: one tokenless upgrade,
    // accepted or refused. A probe that cannot answer (engine down) is *not* permission to drop the
    // credential. The decision is printed either way — a silent change in whether a credential is
    // sent is undebuggable from a journal.
    let engine_auth = engine_auth::probe(&engine_ws).await;
    eprintln!("{}", engine_auth.boot_line(&engine_ws, &engine_token_file));

    let salt = auth::load_or_create_salt(&home.join("bridge.salt"))?;
    // The bearer the bundled skill scripts send. Created here, once per boot: deleting the file and
    // restarting is the one way to invalidate it, and it is never printed. A deployment whose bots
    // run as another account opts into group/user read access with `HERMEYD_LOCAL_TOKEN_GROUP` /
    // `..._USER`; anything unset or malformed stays 0600 and is reported below.
    let local_token_path = local_token::token_path(&home);
    let local_token_access = local_token::AccessPlan::from_env();
    let local_token = Arc::new(local_token::LocalToken::load_or_create_with(
        &local_token_path,
        &local_token_access,
    )?);
    let store = store::Store::open(&home.join("bridge.db"))?;

    let state = Arc::new(routes::AppState {
        store,
        pairing: pairing::Pairing::new(routes::PAIRING_CODE_TTL_SECONDS),
        tickets: auth::Tickets::new(TICKET_TTL_SECONDS, ACCESS_TTL_SECONDS),
        limiter: auth::RateLimiter::new(30, 60.0),
        salt,
        public_host: std::env::var("HERMEYD_PUBLIC_HOST").unwrap_or_else(|_| "localhost".to_string()),
        engine_ws: engine_ws.clone(),
        engine_token_file: engine_token_file.clone(),
        engine_auth: engine_auth.clone(),
        engine_home: engine_home.clone(),
        relay_sockets: relay::Registry::default(),
        local_computers: local_computers::Registry::default(),
        // Browser fill targets: the sign-in extension's socket registry (see browser.rs).
        browsers: browser::Registry::default(),
        // The token file is `None` when the engine said it needs none: the display socket is then
        // dialled bare, exactly like every other engine connection.
        display: display::DisplayHub::spawn(
            engine_ws,
            if engine_auth.send_token() { Some(engine_token_file) } else { None },
        ),
        attachments_dir: home.join("attachments"),
        local_token: Arc::clone(&local_token),
        // One bounded JSON-lines file beside `bridge.db`: who did what, how long, how many bytes.
        // No field can carry a prompt, a response or a credential (see audit.rs).
        audit: Arc::new(audit::AuditLog::in_dir(&home)),
    });

    // The instructions that make a capability real: a bot that cannot see how to reach the Mac will
    // try SSH and fail, so every bot needs those files before it can ask. This is the bridge's
    // `agent_skills.install()` at the point the bridge calls it — boot — and, like there, best
    // effort: a Hermes home this process cannot write must not stop it serving, and the next start
    // simply tries again.
    skills::install(
        &state.engine_home,
        &home,
        skills::host_os(),
        &skills::Endpoints::from_env(&bind, port, browser_port, local_token_path.clone()),
    );
    eprintln!("local token: {local_token}");
    if let Some(warning) = local_token.warning() {
        eprintln!("local token access: {warning}");
    }

    // Banners for replies that arrive while no app is open. See push.rs for why the watcher, not
    // the WS relay, is the hook: the relay only exists while a device is connected.
    push::spawn_watcher(Arc::clone(&state));

    // The browser channel lives on the second listener, not this router: `tailscale serve` publishes
    // this port, and `/v1/browser/*` needs no device credential (the extension and the on-host sign-in
    // skill hold none). Loopback-only is the whole boundary for those three routes.
    let browser_app = Router::new()
        .route("/v1/browser/act", post(browser::act))
        .route("/v1/browser/targets", get(browser::targets))
        .route("/v1/browser/ws", get(browser::channel))
        .layer(axum::middleware::from_fn_with_state(
            Arc::clone(&state),
            audit::log_http,
        ))
        .with_state(Arc::clone(&state));

    let app = Router::new()
        .route("/v1/health", get(routes::health))
        .route("/v1/pair/start", post(routes::pair_start))
        .route("/v1/pair/host", get(routes::pair_host))
        .route("/v1/pair/claim", post(routes::pair_claim))
        .route("/v1/token", post(routes::token))
        .route("/v1/devices", get(routes::devices))
        .route("/v1/devices/{device_id}", delete(routes::revoke))
        .route(
            "/v1/devices/{device_id}/revoked",
            // Delete a row that is already revoked: an active device answers 409, unknown 404.
            delete(routes::delete_revoked_device),
        )
        .route("/v1/ws", get(routes::ws_upgrade))
        // --- bridge-owned collections the apps read on connect ---
        .route(
            "/v1/bot-categories",
            get(bridge_routes::get_categories).post(bridge_routes::post_categories),
        )
        .route(
            "/v1/bot-categories/order",
            axum::routing::put(bridge_routes::put_category_order),
        )
        .route(
            "/v1/bot-categories/{category}",
            axum::routing::patch(bridge_routes::patch_category)
                .delete(bridge_routes::delete_category),
        )
        .route("/v1/bot-defaults", get(bridge_routes::get_defaults))
        .route(
            "/v1/bot-defaults/soul",
            axum::routing::put(bridge_routes::put_defaults_soul),
        )
        .route("/v1/bot-icons", get(bridge_routes::get_icons))
        .route(
            "/v1/bot-icons/{bot}",
            axum::routing::put(bridge_routes::put_icon),
        )
        .route("/v1/bots/disabled", get(bridge_routes::get_disabled))
        .route("/v1/bots/{profile}/memory", get(bot_docs::memory_get))
        .route(
            "/v1/bots/{profile}/session",
            // The shared pointer two paired devices agree on. An unknown bot answers 200/null,
            // never 404: "no conversation yet" is a normal answer.
            get(bot_sessions::get_session).put(bot_sessions::put_session),
        )
        .route(
            "/v1/bots/{profile}/message",
            // Loopback-only operator command (no device ticket, like /v1/pair/start): deliver a
            // message into a bot's canonical conversation. See bot_message.rs.
            post(bot_message::post_message),
        )
        .route(
            "/v1/bots/{profile}/ask",
            // Same delivery, then block until the owner answers in that same chat.
            post(bot_message::post_ask),
        )
        .route(
            "/v1/bots/{profile}/model-settings",
            get(model_settings::get_settings).put(model_settings::put_settings),
        )
        // Provider+model, as distinct from model-settings (effort/vision). The catalogue is the
        // engine's `model.options`; the pin is written through `profiles.configure`.
        .route("/v1/providers", get(providers::list_providers))
        .route(
            "/v1/bots/{profile}/model",
            get(providers::get_bot_model)
                // POST is accepted for clients that only speak POST; the body is identical.
                .put(providers::put_bot_model)
                .post(providers::put_bot_model),
        )
        .route(
            "/v1/bots/{profile}/routines",
            get(routines::list_routines).post(routines::create_routine),
        )
        .route(
            "/v1/bots/{profile}/routines/{job_id}/state",
            post(routines::set_routine_state),
        )
        .route(
            "/v1/bots/{profile}/routines/{job_id}",
            delete(routines::delete_routine),
        )
        .route(
            "/v1/bots/{profile}/notes",
            get(bot_docs::notes_get).put(bot_docs::notes_put),
        )
        .route("/v1/local-computers", get(local_computers::list))
        .route("/v1/local-computers/ws", get(local_computers::channel))
        .route(
            "/v1/local-computers/skill",
            // GET reports; POST is the Mac's Install button. Both exist so the button is answered
            // by a handler rather than a 405 the app ignores.
            get(local_computers::skill_placeholder).post(local_computers::skill_install),
        )
        .route("/v1/local-computers/{device_id}", delete(local_computers::revoke))
        .route("/v1/local-computers/{device_id}/enable", post(local_computers::enable))
        .route("/v1/local-computers/{device_id}/execute", post(local_computers::execute))
        .route("/v1/local-computers/{device_id}/act", post(local_computers::act))
        .route("/v1/local-computers/{device_id}/observe", post(local_computers::observe))
        .route(
            "/v1/local-computers/{device_id}/execute-stream",
            post(local_computers::execute_stream)
                .layer(axum::extract::DefaultBodyLimit::max(1024 * 1024)),
        )
        .route(
            "/v1/local-computers/{device_id}/file",
            post(local_computers::file_op)
                // A 4 MB write arrives as ~5.4 MB of base64 in a JSON envelope; the ceiling the
                // framework applies must sit above the one the handler answers with its own 413.
                .layer(axum::extract::DefaultBodyLimit::max(8 * 1024 * 1024)),
        )
        .route("/v1/local-computers/{device_id}/resume", post(local_computers::resume))
        .route("/v1/local-computers/{device_id}/browser", post(local_computers::browser))
        .route("/v1/integrations", get(integrations::list))
        .route("/v1/integrations/run", post(integrations::run))
        .route("/v1/integrations/{slug}/connect", post(integrations::connect))
        .route("/v1/integrations/{slug}/tools", get(integrations::tools))
        .route("/v1/integrations/{slug}/alias", post(integrations::set_alias))
        .route("/v1/integrations/{slug}/disconnect", post(integrations::disconnect))
        .route("/v1/integrations/{slug}/key-fields", get(integrations::key_fields))
        .route("/v1/integrations/{slug}/key-connect", post(integrations::key_connect))
        .route("/v1/genui/session", post(genui::mint))
        .route("/v1/genui/host", get(genui::host))
        .route("/v1/genui/plugin.js", get(genui::plugin_bundle))
        .route("/v1/genui/assets/{name}", get(genui::asset))
        .route("/v1/genui/blocks/{block_id}", get(genui::block))
        .route(
            "/v1/genui/blocks/{block_id}/state",
            get(genui::block_state).put(genui::save_block_state),
        )
        // Agent cards (`card.v1`): a third renderer, preferred only when its own marker is present.
        // The bot writes the file; the app sends the id from the marker and gets the JSON back.
        .route("/v1/cards/{card_id}", get(cards::get_card))
        .route("/v1/search", get(search::search))
        .route("/v1/bot-transfers", get(transfers::list_transfers))
        .route("/v1/backup", get(backup::export))
        .route("/v1/backup.zip", get(parity_gaps::backup_zip))
        .route("/v1/backup/import-prompt", get(parity_gaps::import_prompt))
        .route("/v1/backup/restore", post(backup::restore))
        .route(
            "/v1/backup/import",
            post(backup::import)
                // The body is the file itself. The 8 MiB ceiling that answers with its own detail
                // is backup::MAX_BACKUP_BYTES; the framework gets room above it so that is the
                // 413 a client sees, not an empty framework rejection.
                .layer(axum::extract::DefaultBodyLimit::max(16 * 1024 * 1024)),
        )
        .route("/v1/bots/{profile}/purge", post(bot_admin::purge))
        .route(
            "/v1/credentials/cards",
            get(credentials::list_cards).post(credentials::create_card),
        )
        .route("/v1/credentials/cards/{card_id}", get(credentials::get_card))
        .route("/v1/credentials/cards/{card_id}/answer", post(credentials::answer_card))
        .route("/v1/credentials/cards/{card_id}/cancel", post(credentials::cancel_card))
        .route("/v1/credentials/cards/{card_id}/consume", post(credentials::consume_card))
        .route("/v1/voice/transcribe", post(voice::transcribe))
        .route("/v1/voice/synthesize", post(voice::synthesize))
        .route(
            "/v1/display/status",
            get(display::status),
        )
        .route("/v1/display/thumbnail", get(display::thumbnail))
        .route("/v1/display/start", post(display::start))
        .route("/v1/display/stop", post(display::stop))
        .route("/v1/display/lease", post(display::lease))
        .route("/v1/display/observe", post(display::observe))
        .route("/v1/display/ws", get(display::display_ws))
        .route(
            "/v1/bots/previews",
            get(previews::previews_get).post(previews::previews_post),
        )
        .route(
            "/v1/bots/{profile}/category",
            axum::routing::put(bridge_routes::put_bot_category),
        )
        .route(
            "/v1/bots/approvals",
            get(bridge_routes::get_approvals).put(bridge_routes::put_approvals),
        )
        .route(
            "/v1/bots/{profile}/state",
            post(bridge_routes::post_bot_state),
        )
        .route("/v1/workspace/{profile}", get(workspace::list_workspace))
        .route("/v1/workspace/{profile}/file", get(workspace::workspace_file))
        .route("/v1/rooms", get(rooms::list_rooms).post(rooms::create_room))
        .route("/v1/rooms/{room_id}/log", get(rooms::room_log))
        .route("/v1/rooms/{room_id}/send", post(rooms::send_room))
        .route("/v1/rooms/{room_id}/rename", post(rooms::rename_room))
        .route("/v1/rooms/{room_id}/disband", post(rooms::disband_room))
        .route("/v1/push/presence", post(push::presence))
        .route("/v1/push/register", post(push::register))
        .route("/v1/push/test", post(push::test))
        .route(
            "/v1/push/icon/{bot}",
            get(parity_gaps::push_icon_get)
                .put(parity_gaps::push_icon_put)
                // Room for a 2 MiB image inside a base64 JSON envelope; the ceiling that answers is
                // parity_gaps::MAX_ICON_BYTES, which says why in its own words.
                .layer(axum::extract::DefaultBodyLimit::max(parity_gaps::ICON_BODY_LIMIT)),
        )
        .route(
            "/v1/attachments",
            post(routes::upload_attachment)
                // Body ceiling enforced by the framework, so an oversized upload is refused before
                // it is buffered into memory.
                .layer(axum::extract::DefaultBodyLimit::max(routes::MAX_ATTACHMENT_BYTES + 1024)),
        )
        .route("/v1/attachments/{attachment_id}", get(routes::download_attachment))
        .route("/v1/attachments/{attachment_id}", delete(routes::delete_attachment))
        .route("/v1/attachments/{profile}/{name}", get(parity_gaps::attachment_file))
        .layer(axum::middleware::from_fn_with_state(
            Arc::clone(&state),
            audit::log_http,
        ))
        .with_state(state);

    let addr: SocketAddr = format!("{bind}:{port}").parse()?;
    // Bound before the main listener prints READY: a service that boots with the sign-in channel
    // silently missing looks healthy while every sign-in gets "connection refused".
    let browser_addr: SocketAddr = format!("127.0.0.1:{browser_port}").parse()?;
    let browser_listener = tokio::net::TcpListener::bind(browser_addr).await.map_err(|e| {
        format!("cannot bind the browser channel on {browser_addr} (HERMEYD_BROWSER_PORT): {e}")
    })?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("HERMEYD_READY {addr} version={VERSION} home={} ticket_ttl={TICKET_TTL_SECONDS}s", home.display());
    println!("HERMEYD_BROWSER_READY {browser_addr} (loopback only — never add this port to tailscale serve)");

    tokio::spawn(async move {
        if let Err(e) = axum::serve(
            browser_listener,
            browser_app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        {
            eprintln!("browser channel listener stopped: {e}");
        }
    });

    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
