// Hermey Sign-in — the browser half of a login card.
//
// The bridge sends {type:"fill", fields:[{name, value}]} and this puts the values on the page. It never
// reports what they were: the reply is {id, ok}. Nothing here logs a value, stores one, or sends one
// anywhere except into the form.
//
// Connection: loopback WebSocket to the bridge. No native-messaging host, so there is nothing to install
// per browser and no second credential to leak. If the bridge is down the worker retries with backoff.

const BRIDGE_URL = "ws://127.0.0.1:8787/v1/browser/ws";
const RETRY_MIN_MS = 1000;
const RETRY_MAX_MS = 30000;

let socket = null;
let retryMs = RETRY_MIN_MS;
let lastError = "";

// Runs in the page. Kept as a standalone function so chrome.scripting can serialise it.
function fillFields(fields) {
  const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const setValue = (el, value) => {
    const proto = el instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
    // The native setter, then the events a framework listens for. Plain `el.value = …` leaves React
    // and friends believing the field is still empty, which looks exactly like a rejected password.
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    el.focus();
  };
  const pickers = {
    password: "input[type=password]",
    username:
      "input[type=text], input[type=email], input[name*=user i], input[name*=email i]," +
      " input[id*=user i], input[id*=email i]",
    "one-time code":
      "input[autocomplete*=one-time-code i], input[name*=otp i], input[name*=code i]," +
      " input[id*=otp i], input[id*=token i]",
  };
  let touched = 0;
  for (const field of fields) {
    if (!field || !field.name || !field.value) continue;
    if (field.name === "choice") {
      const wanted = String(field.value).toLowerCase();
      const clickable = Array.from(
        document.querySelectorAll("button, a, [role=button], input[type=submit]")
      ).filter(visible);
      const match = clickable.find((el) =>
        (el.innerText || el.value || "").toLowerCase().includes(wanted)
      );
      if (match) {
        match.click();
        touched += 1;
      }
      continue;
    }
    const selector = pickers[field.name] || "input[type=text]";
    const el = Array.from(document.querySelectorAll(selector)).filter(visible)[0];
    if (el) {
      setValue(el, field.value);
      touched += 1;
    }
  }
  return touched > 0;
}

async function applyFill(fields) {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab || tab.id === undefined) return false;
  const [result] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: fillFields,
    args: [fields],
  });
  return Boolean(result && result.result);
}

function send(payload) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload));
}

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
    return;
  }
  try {
    socket = new WebSocket(BRIDGE_URL);
  } catch (err) {
    scheduleRetry();
    return;
  }
  socket.onopen = () => {
    retryMs = RETRY_MIN_MS;
    lastError = "";
    chrome.storage.local.set({ connected: true });
    send({ type: "hello", label: (navigator.userAgent || "browser").slice(0, 60) });
  };
  socket.onmessage = async (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (err) {
      return;
    }
    if (message.type !== "fill" || !message.id) return;
    let ok = false;
    try {
      ok = await applyFill(message.fields || []);
    } catch (err) {
      ok = false;
    }
    // The reply carries the id and a boolean. Never a value.
    send({ id: message.id, ok });
  };
  socket.onclose = () => {
    chrome.storage.local.set({ connected: false });
    scheduleRetry();
  };
  socket.onerror = () => {
    lastError = "bridge unreachable";
    chrome.storage.local.set({ connected: false, lastError });
  };
}

function scheduleRetry() {
  setTimeout(connect, retryMs);
  retryMs = Math.min(retryMs * 2, RETRY_MAX_MS);
}

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms?.create?.("hermey-keepalive", { periodInMinutes: 0.5 });
chrome.alarms?.onAlarm?.addListener((alarm) => {
  if (alarm.name === "hermey-keepalive") connect();
});
connect();
