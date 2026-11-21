// The slice of @hermes/plugin-sdk the genui plugin touches, wired to the host app over postMessage.
export const TRANSCRIPT_DIRECTIVE_AREA = "transcript-directive";

const post = (message) => {
  try {
    window.webkit?.messageHandlers?.hermes?.postMessage(message);
  } catch {}
};

export const host = {
  composer: {
    submit(_sessionId, text) {
      post({ type: "send", text });
      return true;
    },
    async insertText(_sessionId, text) {
      post({ type: "fill", text });
      return true;
    },
    focus() {
      post({ type: "focus" });
    },
  },
};
