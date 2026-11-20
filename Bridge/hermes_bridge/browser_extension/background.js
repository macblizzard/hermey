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
    // A one-time code is often six boxes, not one field (Doctolib's Keycloak does exactly this). Typing
    // the whole code into the first box is silently wrong, so spread it when the page asks that way.
    if (field.name === "one-time code") {
      const boxes = Array.from(document.querySelectorAll(
        'input[autocomplete*=one-time-code i], input[name*=otp i], input[id*=otp i]'
      )).filter(visible);
      const chars = String(field.value).replace(/\s/g, "").split("");
      if (boxes.length > 1 && chars.length >= 1) {
        const perBox = boxes.length >= chars.length
          ? chars.map((c) => c)
          : [chars.join("")];
        boxes.forEach((box, index) => {
          if (perBox[index] !== undefined) setValue(box, perBox[index]);
        });
        touched += 1;
        continue;
      }
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


// Reports what the active page shows, so a scripted login can decide the next step without the bot
// reading the page itself: how many password boxes, whether a one-time code is being asked for, and the
// visible buttons with their text.
function probePage() {
  const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const inputs = Array.from(document.querySelectorAll("input")).filter(visible);
  const buttons = Array.from(document.querySelectorAll("button, input[type=submit], a[role=button]"))
    .filter(visible)
    .map((el) => (el.innerText || el.value || "").trim())
    .filter((text) => text && text.length < 40);
  return {
    url: location.href,
    passwordFields: inputs.filter((el) => el.type === "password").length,
    otpBoxes: inputs.filter((el) => /one-time-code/i.test(el.autocomplete || "")).length,
    textFields: inputs.filter((el) => el.type === "text" || el.type === "email").length,
    buttons: [...new Set(buttons)],
  };
}

// Clicks the first visible button whose text matches, so a login can advance a step. Matching is on the
// page's own labels — the caller passes a locale it expects to see.
function clickButton(match) {
  const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const wanted = String(match || "").toLowerCase();
  const candidates = Array.from(document.querySelectorAll("button, input[type=submit], a[role=button]"))
    .filter(visible)
    .map((el) => ({ el, text: (el.innerText || el.value || "").trim().toLowerCase() }))
    .filter((row) => row.text && row.text.includes(wanted));
  if (!candidates.length) return false;
  candidates[0].el.click();
  return true;
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
    if (!message.type || !message.id) return;
    let reply = { ok: false };
    try {
      if (message.type === "fill") {
        reply = { ok: await applyFill(message.fields || []) };
      } else if (message.type === "probe") {
        const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
        const [out] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: probePage });
        reply = { ok: true, page: (out && out.result) || null };
      } else if (message.type === "goto") {
        const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
        await chrome.tabs.update(tab.id, { url: String(message.url || "") });
        reply = { ok: true };
      } else if (message.type === "click") {
        const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
        const [out] = await chrome.scripting.executeScript({
          target: { tabId: tab.id }, func: clickButton, args: [message.match || ""],
        });
        reply = { ok: Boolean(out && out.result) };
      }
    } catch (err) {
      reply = { ok: false };
    }
    // The reply carries the id, a boolean and, for a probe, the page's shape. Never a value.
    send({ id: message.id, ...reply });
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
