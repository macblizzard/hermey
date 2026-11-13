// Rebuilds the vendored React the genui card shell needs (`Bridge/hermes_bridge/genui_assets/`).
//
// Why vendored: the shell runs in a WKWebView, which cannot install npm packages, and the plugin's
// bundle imports `react` / `react/jsx-runtime` as bare specifiers that an import map has to resolve.
// React 19 ships no UMD build, so the two files here are ESM builds of exactly the names the plugin
// imports — one React instance for the whole page.
//
//   node Tools/genui/build_assets.mjs
//
// Needs a scratch install: `npm i react@19 react-dom@19 esbuild`. The two output files are
// `app.mjs` (React + ReactDOM/client + the named hooks the plugin uses) and `jsx.mjs` (the JSX
// runtime, built on that same React). `sdk.mjs` and `host.html` are hand-written and not produced
// here.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, "../../Bridge/hermes_bridge/genui_assets");

const common = {
  bundle: true,
  format: "esm",
  target: "es2022",
  minify: true,
  legalComments: "none",
  logLevel: "warning",
};

// One entry, one bundle: a second copy of React in the page makes every hook throw
// ("Invalid hook call"), which is what a per-package build would produce.
const appEntry = `
import React, {
  Children, Fragment, StrictMode, cloneElement, createContext, createElement, forwardRef,
  isValidElement, memo, useCallback, useContext, useEffect, useId, useLayoutEffect, useMemo,
  useReducer, useRef, useState, useSyncExternalStore,
} from "react";
import { createRoot, hydrateRoot } from "react-dom/client";
import { flushSync } from "react-dom";
export {
  React as default, Children, Fragment, StrictMode, cloneElement, createContext, createElement,
  createRoot, flushSync, forwardRef, hydrateRoot, isValidElement, memo, useCallback, useContext,
  useEffect, useId, useLayoutEffect, useMemo, useReducer, useRef, useState, useSyncExternalStore,
};
`;

await build({ ...common, stdin: { contents: appEntry, resolveDir: process.cwd(), loader: "js" }, outfile: path.join(out, "app.mjs") });
console.log("wrote", path.join(out, "app.mjs"));
