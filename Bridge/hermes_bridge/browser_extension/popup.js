// Status only. The popup never shows, stores or asks for a value.
const dot = document.getElementById("dot");
const state = document.getElementById("state");
chrome.storage.local.get(["connected", "lastError"]).then(({ connected, lastError }) => {
  dot.className = "dot " + (connected ? "on" : "off");
  state.textContent = connected ? "Connected to the bridge" : lastError || "Not connected";
});
