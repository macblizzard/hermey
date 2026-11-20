/**
 * Guards the viewer's zoom and pan — the full-screen picture's only way to be looked at closely.
 *
 * Run: node Tools/verify/novnc_zoom_pan.mjs
 *
 * The shipped page's own functions are lifted out of `botcomputer.html` and run in a sandbox, so this
 * checks the code that ships rather than a copy of it. Two things must hold:
 *   * the transform never lets the picture be dragged off its own edges (clampPan), and
 *   * a click still lands on the pixel it was aimed at, whatever the zoom and pan
 *     (`clientToElement()` is patched to divide the rendered rect back out).
 */
import fs from 'node:fs';
import vm from 'node:vm';
import { clientToElement } from '../../Apps/HermesMobile/Resources/novnc/core/util/element.js';

const PAGE = new URL('../../Apps/HermesMac/Resources/botcomputer.html', import.meta.url);
const html = fs.readFileSync(PAGE, 'utf8');
const module = /<script type="module">([\s\S]*?)<\/script>/.exec(html);
if (!module) {
  console.error('FAIL: the page lost its module script');
  process.exit(1);
}
const body = module[1];

const start = body.indexOf('const MIN_SCALE');
const end = body.indexOf("screen.addEventListener('touchstart'");
if (start < 0 || end < 0 || end <= start) {
  console.error('FAIL: the zoom block is no longer where this guard looks for it');
  process.exit(1);
}

// Everything from the range constants to the pinch listener: the state, applyTransform, clampPan and
// zoomAround. The DOM it touches is replaced with the few properties those functions read.
const sandbox = {
  screen: { style: {}, clientWidth: 390, clientHeight: 600 },
  zoomBadge: { style: {}, textContent: '' },
  isTouch: true,
  post: () => {},
  Date, setTimeout, clearTimeout,
};
vm.createContext(sandbox);
vm.runInContext(body.slice(start, end) +
  '\nglobalThis.__probe = () => ({ scale, tx, ty });' +
  '\nglobalThis.__set = (s, x, y) => { scale = s; tx = x; ty = y; };' +
  '\nglobalThis.__api = { zoomAround, clampPan, MIN_SCALE, MAX_SCALE };', sandbox);

const { zoomAround, clampPan, MIN_SCALE, MAX_SCALE } = sandbox.__api;
const state = () => sandbox.__probe();

let failures = 0;
function check(name, condition, detail) {
  if (!condition) {
    failures++;
    console.log(`FAIL ${name}: ${detail}`);
  } else {
    console.log(`ok   ${name}`);
  }
}
function near(actual, wanted, tolerance = 0.001) {
  return Math.abs(actual - wanted) <= tolerance;
}

// ---- the range both platforms promise -------------------------------------------------------
check('the range is 1x-5x', MIN_SCALE === 1 && MAX_SCALE === 5, `${MIN_SCALE}-${MAX_SCALE}`);

// ---- panning cannot leave the picture's own edges --------------------------------------------
sandbox.__set(2, 0, 0);
clampPan();
check('pan clamps a drag past the left edge to 0', state().tx === 0 && state().ty === 0,
      JSON.stringify(state()));

sandbox.__set(2, -1000, -2000);
clampPan();
check('pan clamps a drag past the right edge',
      near(state().tx, 390 - 780) && near(state().ty, 600 - 1200), JSON.stringify(state()));

sandbox.__set(1, -40, -40);
clampPan();
check('at 1x there is nowhere to pan', state().tx === 0 && state().ty === 0, JSON.stringify(state()));

// ---- zoom keeps the point it was aimed at under the pointer -----------------------------------
sandbox.__set(1, 0, 0);
zoomAround(2, 195, 300);
let s = state();
check('2x about the centre lands at 2x', near(s.scale, 2), JSON.stringify(s));
check('2x about the centre keeps the centre still',
      near((195 - s.tx) / s.scale, 195) && near((300 - s.ty) / s.scale, 300), JSON.stringify(s));

sandbox.__set(1, 0, 0);
zoomAround(2, 0, 0);
s = state();
check('zooming at the top-left corner leaves the pan alone', s.tx === 0 && s.ty === 0,
      JSON.stringify(s));

// A pinch is many small factors; they must accumulate to the same place as one big one.
sandbox.__set(1, 0, 0);
for (let i = 0; i < 10; i++) { zoomAround(1.2, 100, 100); }
s = state();
check('ten small steps clamp at the ceiling', near(s.scale, MAX_SCALE), JSON.stringify(s));

// Zooming out to (or past) 1x snaps flat rather than leaving a sub-pixel pan behind.
sandbox.__set(3, -500, -400);
zoomAround(0.1, 200, 200);
s = state();
check('zooming out to the floor resets to 1x with no pan',
      s.scale === 1 && s.tx === 0 && s.ty === 0, JSON.stringify(s));

// ---- a click still lands on the pixel it was aimed at ----------------------------------------
// The canvas is laid out at 390x600; the #screen transform scales and moves its rendered rect, and
// noVNC's patched clientToElement() has to give back layout coordinates.
function canvasFor(scale, tx, ty) {
  return {
    getBoundingClientRect: () => ({
      left: tx, top: ty,
      right: tx + 390 * scale, bottom: ty + 600 * scale,
      width: 390 * scale, height: 600 * scale,
    }),
    offsetWidth: 390, offsetHeight: 600,
  };
}

const plain = clientToElement(120, 90, canvasFor(1, 0, 0));
// The same framebuffer pixel, aimed at through a 2.5x transform panned by (-80,-140): its client
// coordinates are layout * scale + pan.
const zoomed = clientToElement(120 * 2.5 - 80, 90 * 2.5 - 140, canvasFor(2.5, -80, -140));
check('a click aimed at a pixel through a 2.5x panned transform maps back to that pixel',
      near(zoomed.x, plain.x) && near(zoomed.y, plain.y),
      `plain ${JSON.stringify(plain)} zoomed ${JSON.stringify(zoomed)}`);

// The same click, in the coordinates the page's own zoom produced for a centre-anchored 2x.
sandbox.__set(1, 0, 0);
zoomAround(2, 195, 300);
s = state();
const centre = clientToElement(195, 300, canvasFor(s.scale, s.tx, s.ty));
check('after a 2x zoom the centre of the screen is still the centre of the framebuffer',
      near(centre.x, 195) && near(centre.y, 300), JSON.stringify(centre));

if (failures) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log('\nall zoom/pan checks passed');
