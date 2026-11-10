/**
 * Guards the local patch to noVNC's `clientToElement()`, documented in HERMEY-PATCHES.md inside
 * each app's Resources/novnc directory.
 *
 * Run: node Tools/verify/novnc_client_to_element.mjs
 *
 * The viewer zooms by CSS-transforming the element noVNC draws into. The original helper returned
 * CSS pixels inside the *rendered* rect, which Display.absX() then divided by noVNC's own scale —
 * so a transform was applied twice and every click while zoomed landed at the wrong place.
 */
import { clientToElement } from '../../Apps/HermesMobile/Resources/novnc/core/util/element.js';

let failures = 0;
function expect(name, actual, wanted) {
  const ok = Math.abs(actual.x - wanted.x) < 0.01 && Math.abs(actual.y - wanted.y) < 0.01;
  if (!ok) {
    failures++;
    console.log(`FAIL ${name}: got ${JSON.stringify(actual)}, wanted ${JSON.stringify(wanted)}`);
  } else {
    console.log(`ok   ${name} -> ${actual.x},${actual.y}`);
  }
}

// A canvas laid out at 390x600, rendered unscaled at the origin: the patch must be a no-op.
const plain = {
  getBoundingClientRect: () => ({ left: 0, top: 0, right: 390, bottom: 600, width: 390, height: 600 }),
  offsetWidth: 390, offsetHeight: 600,
};
expect('unzoomed centre', clientToElement(195, 300, plain), { x: 195, y: 300 });
expect('unzoomed bottom-right clips inside', clientToElement(390, 600, plain), { x: 389, y: 599 });

// 2x zoom from the top-left: same layout box, doubled rect.
const zoomed = {
  getBoundingClientRect: () => ({ left: 0, top: 0, right: 780, bottom: 1200, width: 780, height: 1200 }),
  offsetWidth: 390, offsetHeight: 600,
};
expect('2x centre', clientToElement(390, 600, zoomed), { x: 195, y: 300 });
expect('2x three-quarters', clientToElement(585, 900, zoomed), { x: 292.5, y: 450 });

// 2x zoom panned by (-200,-100).
const panned = {
  getBoundingClientRect: () => ({ left: -200, top: -100, right: 580, bottom: 1100, width: 780, height: 1200 }),
  offsetWidth: 390, offsetHeight: 600,
};
expect('2x panned centre', clientToElement(190, 500, panned), { x: 195, y: 300 });

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log('\nall checks passed');
