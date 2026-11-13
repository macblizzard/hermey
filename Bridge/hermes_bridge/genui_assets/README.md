# The genui card shell's vendored files

The Hermey apps draw the `hermes-genui` plugin's cards in a `WKWebView` that loads
`/v1/genui/host` from the bridge. That page needs React, because the plugin's bundle imports it as a
bare specifier — and React 19 ships no UMD build a page can just `<script src>`. These three files
are what the page loads, and the import map in `host.html` is what makes the bare imports resolve:

| file | what it is | where it comes from |
|---|---|---|
| `app.mjs` | React 19 + `react-dom/client`, ESM, minified: the named hooks the plugin imports, `createRoot`, `hydrateRoot`, `flushSync` | `node Tools/genui/build_assets.mjs` |
| `jsx.mjs` | the JSX runtime (`jsx`, `jsxs`, `Fragment`) built on **that same** React | hand-written, 15 lines |
| `sdk.mjs` | the slice of `@hermes/plugin-sdk` the plugin touches (`host.composer`, `TRANSCRIPT_DIRECTIVE_AREA`), wired to `postMessage` | hand-written |
| `host.html` | the one-card page: import map, palette, render, height reporting | hand-written |

React is MIT licensed (`facebook/react`); `app.mjs` is a verbatim build of it, not a modification.

## Why one bundle and not two

A page with two copies of React throws *Invalid hook call* on the first component that uses a hook —
and the plugin uses hooks everywhere. `app.mjs` is built from one entry so `react`, `react/jsx-runtime`
and `react-dom/client` all resolve to the same instance.

## Why the JSX runtime is hand-written

`createElement(type, props, key)` takes **children** as its third argument, not a key. Mapping the
runtime's `jsx(type, props, key)` straight onto it sets `props.children = undefined` — every card
then renders empty, with no error anywhere, which is exactly how this shipped broken the first time.
`jsx.mjs` puts the key in the props object instead.
