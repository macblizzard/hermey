// The JSX runtime the plugin imports, built on the one React instance this page loads.
// A separate copy of `react/jsx-runtime` would give the page two Reacts and every hook would throw.
// createElement's third argument is a *child*, not a key: passing the runtime's key there wipes out
// the children the JSX already put in props, which renders an empty card with no error at all.
import { createElement, Fragment as ReactFragment } from "react";
export const jsx = (type, props, key) => {
  const config = props ?? {};
  return key === undefined ? createElement(type, config) : createElement(type, { ...config, key });
};
export const jsxs = jsx;
export const Fragment = ReactFragment;
