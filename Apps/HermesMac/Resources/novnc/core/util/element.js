/*
 * noVNC: HTML5 VNC client
 * Copyright (C) 2020 The noVNC authors
 * Licensed under MPL 2.0 (see LICENSE.txt)
 *
 * See README.md for usage and integration instructions.
 */

/*
 * HTML element utility functions
 */

export function clientToElement(x, y, elem) {
    const bounds = elem.getBoundingClientRect();
    // Hermey: the bounding rect includes any CSS transform on an ancestor, while the element's
    // layout box (offsetWidth/offsetHeight) does not. Dividing by that ratio undoes a zoom applied
    // by a wrapping element, so pointer coordinates stay in noVNC's own layout space — the space
    // Display.absX() expects (it divides by its own scale, not by ours). Without this, pinching to
    // 2x sent every click at twice the distance from the top-left corner.
    const layoutWidth = elem.offsetWidth || bounds.width;
    const layoutHeight = elem.offsetHeight || bounds.height;
    const scaleX = bounds.width ? layoutWidth / bounds.width : 1;
    const scaleY = bounds.height ? layoutHeight / bounds.height : 1;

    let pos = { x: 0, y: 0 };
    // Clip to target bounds
    if (x < bounds.left) {
        pos.x = 0;
    } else if (x >= bounds.right) {
        pos.x = layoutWidth - 1;
    } else {
        pos.x = (x - bounds.left) * scaleX;
    }
    if (y < bounds.top) {
        pos.y = 0;
    } else if (y >= bounds.bottom) {
        pos.y = layoutHeight - 1;
    } else {
        pos.y = (y - bounds.top) * scaleY;
    }
    return pos;
}
