//! The pairing QR: the exact URL `hermeyd pair` prints, as half-block characters.
//!
//! A phone camera is pointed at a terminal, so polarity is not cosmetic — iOS's QR reader does not
//! decode an inverted code. A dark terminal is the default, so the *light* modules are the ones
//! drawn as blocks: the bright glyph is a light module and the terminal's own background is a dark
//! one, which reproduces the dark-on-light image a camera expects. A light terminal (detected from
//! `COLORFGBG`, which some terminals set) gets the inverse. `hermeyd pair` picks with
//! [`paint_light_modules`].
//!
//! Two module rows share one line of text (`▀`/`▄`/`█`), so the block stays square in a terminal
//! whose cells are about twice as tall as they are wide. The four-module quiet zone required by
//! ISO/IEC 18004 is included in the matrix, so nothing else has to remember to leave a margin.

use qrcode::{Color, QrCode};

/// The quiet zone, in modules, on every side. ISO/IEC 18004 asks for four.
pub const QUIET_ZONE: usize = 4;

/// The module grid, quiet zone included. `true` is a light module.
pub fn matrix(text: &str) -> Result<Vec<Vec<bool>>, String> {
    let code = QrCode::new(text.as_bytes()).map_err(|e| e.to_string())?;
    let width = code.width();
    let side = width + 2 * QUIET_ZONE;
    let colors = code.to_colors();
    let mut grid = vec![vec![true; side]; side];
    for row in 0..width {
        for col in 0..width {
            grid[row + QUIET_ZONE][col + QUIET_ZONE] =
                matches!(colors[row * width + col], Color::Light);
        }
    }
    Ok(grid)
}

/// One string per terminal line, ready to print. `paint_light` draws the light modules as blocks
/// (right for a dark terminal) and `false` draws the dark ones (right for a light one).
pub fn lines_with(text: &str, paint_light: bool) -> Result<Vec<String>, String> {
    let grid = matrix(text)?;
    let painted = |light: bool| light == paint_light;
    Ok(grid
        .chunks(2)
        .map(|pair| {
            (0..pair[0].len())
                .map(|col| {
                    let top = painted(pair[0][col]);
                    // A grid of odd height ends on a half row; that half is background, not modules.
                    let bottom = pair.get(1).map(|row| painted(row[col])).unwrap_or(false);
                    match (top, bottom) {
                        (true, true) => '█',
                        (true, false) => '▀',
                        (false, true) => '▄',
                        (false, false) => ' ',
                    }
                })
                .collect()
        })
        .collect())
}

/// Whether this terminal has a light background, from `COLORFGBG` (`fg;bg` or `fg;default;bg`).
/// Unknown or unset is treated as dark: that is the default everywhere and the case the owner's
/// terminals are in.
pub fn light_background() -> bool {
    let value = match std::env::var("COLORFGBG") {
        Ok(value) => value,
        Err(_) => return false,
    };
    let bg = match value.rsplit(';').next().and_then(|v| v.trim().parse::<u8>().ok()) {
        Some(bg) => bg,
        None => return false,
    };
    // 7 is light grey; 15 is bright white. Everything else is a dark background.
    bg == 7 || bg == 15
}

/// Which polarity to print on this terminal.
pub fn paint_light_modules() -> bool {
    !light_background()
}

/// The lines `hermeyd pair` prints, polarity already chosen for this terminal.
pub fn lines(text: &str) -> Result<Vec<String>, String> {
    lines_with(text, paint_light_modules())
}

#[cfg(test)]
mod tests {
    use super::*;

    const URL: &str = "https://hermes.example.ts.net/?code=123456";

    /// The decoder is a real QR reader (a port of quirc), fed the matrix as a grayscale image four
    /// pixels per module — so "a phone can read it" is asserted rather than assumed.
    fn decode(grid: &[Vec<bool>]) -> String {
        const SCALE: usize = 4;
        let side = grid.len();
        let pixels = side * SCALE;
        let mut gray = vec![255u8; pixels * pixels];
        for (row, modules) in grid.iter().enumerate() {
            for (col, light) in modules.iter().enumerate() {
                if *light {
                    continue;
                }
                for dy in 0..SCALE {
                    for dx in 0..SCALE {
                        gray[(row * SCALE + dy) * pixels + col * SCALE + dx] = 0;
                    }
                }
            }
        }
        let mut decoder = quircs::Quirc::default();
        let codes: Vec<_> = decoder.identify(pixels, pixels, &gray).collect();
        assert_eq!(codes.len(), 1, "the rendered matrix must contain exactly one QR code");
        let code = codes.into_iter().next().unwrap().expect("extract the QR grid");
        let data = code.decode().expect("decode the QR payload");
        String::from_utf8(data.payload).expect("payload is UTF-8")
    }

    #[test]
    fn the_rendered_qr_decodes_to_the_pairing_url() {
        let grid = matrix(URL).expect("encode");
        assert_eq!(decode(&grid), URL);
    }

    #[test]
    fn the_quiet_zone_is_four_light_modules_on_every_side() {
        let grid = matrix(URL).expect("encode");
        let side = grid.len();
        assert!(side >= 21 + 2 * QUIET_ZONE, "a QR is at least 21 modules wide");
        for row in 0..side {
            for col in 0..side {
                let edge = row < QUIET_ZONE
                    || col < QUIET_ZONE
                    || row >= side - QUIET_ZONE
                    || col >= side - QUIET_ZONE;
                if edge {
                    assert!(grid[row][col], "quiet zone has a dark module at ({row}, {col})");
                }
            }
        }
        // And the interior starts at exactly QUIET_ZONE: the first row inside the zone carries the
        // code's own dark modules, so the margin is four and not five.
        let inside = &grid[QUIET_ZONE][QUIET_ZONE..side - QUIET_ZONE];
        assert!(inside.iter().any(|light| !light), "no code begins at the quiet zone's edge");
    }

    /// Turn the printed half-blocks back into a module grid — what a scanner sees, not what the
    /// encoder produced.
    fn grid_from_lines(lines: &[String], paint_light: bool) -> Vec<Vec<bool>> {
        let mut grid: Vec<Vec<bool>> = Vec::new();
        for (index, line) in lines.iter().enumerate() {
            let mut top = Vec::new();
            let mut bottom = Vec::new();
            for block in line.chars() {
                let (t, b) = match block {
                    '█' => (true, true),
                    '▀' => (true, false),
                    '▄' => (false, true),
                    ' ' => (false, false),
                    other => panic!("unexpected block {other:?}"),
                };
                // Inverting the renderer: a painted block is a light module exactly when the
                // renderer was asked to paint light ones.
                top.push(t == paint_light);
                bottom.push(b == paint_light);
            }
            grid.push(top);
            // The final text line of an odd-height grid has no lower half at all.
            if index + 1 < lines.len() {
                grid.push(bottom);
            }
        }
        grid
    }

    #[test]
    fn the_terminal_rendering_decodes_back_to_the_url() {
        for paint_light in [true, false] {
            let lines = lines_with(URL, paint_light).expect("render");
            let grid = grid_from_lines(&lines, paint_light);
            assert_eq!(decode(&grid), URL, "paint_light={paint_light}");
        }
    }

    #[test]
    fn every_line_covers_the_full_width_in_half_blocks() {
        let grid = matrix(URL).expect("encode");
        let lines = lines_with(URL, true).expect("render");
        assert_eq!(lines.len(), grid.len().div_ceil(2), "two module rows per text line");
        for line in &lines {
            // Each column is one character, none of them double-width.
            assert_eq!(line.chars().count(), grid[0].len());
            assert!(line.chars().all(|c| matches!(c, ' ' | '▀' | '▄' | '█')));
        }
    }

    #[test]
    fn light_and_dark_polarity_are_negatives_down_to_the_odd_last_row() {
        let light = lines_with(URL, true).expect("render");
        let dark = lines_with(URL, false).expect("render");
        assert_eq!(light.len(), dark.len());
        // The grid is square and odd, so the last text line carries only an upper half: it is the
        // quiet zone, drawn in one polarity and empty in the other, not a negative.
        let (body, tail) = light.split_at(light.len() - 1);
        for (l, d) in body.iter().zip(dark.iter()) {
            for (lc, dc) in l.chars().zip(d.chars()) {
                let inverse = match lc {
                    ' ' => '█',
                    '█' => ' ',
                    '▀' => '▄',
                    '▄' => '▀',
                    other => panic!("unexpected block {other:?}"),
                };
                assert_eq!(inverse, dc);
            }
        }
        assert!(tail[0].chars().all(|c| c == '▀'), "odd grid ends on the quiet zone's upper half");
        assert!(dark.last().unwrap().chars().all(|c| c == ' '));
    }

    #[test]
    fn a_dark_terminal_draws_the_light_modules() {
        // The polarity that a phone can read off a dark terminal: a light module becomes a bright
        // block. The top-left corner of the quiet zone is therefore ink, not a gap.
        let lines = lines_with(URL, true).expect("render");
        assert_eq!(lines[0].chars().next(), Some('█'));
    }
}
