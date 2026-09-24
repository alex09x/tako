//! Feeds real ANSI/VT100 output through the full `Terminal` engine and
//! re-renders the resulting grid to this process's own stdout using real
//! truecolor SGR codes derived from the stored `Cell` state -- a round-trip
//! proof that what's stored is what was meant, not a screenshot of a GUI.

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

fn resolve(color: Color, default: (u8, u8, u8)) -> (u8, u8, u8) {
    const ANSI_16: [(u8, u8, u8); 16] = [
        (0, 0, 0), (170, 0, 0), (0, 170, 0), (170, 85, 0),
        (0, 0, 170), (170, 0, 170), (0, 170, 170), (170, 170, 170),
        (85, 85, 85), (255, 85, 85), (85, 255, 85), (255, 255, 85),
        (85, 85, 255), (255, 85, 255), (85, 255, 255), (255, 255, 255),
    ];
    match color {
        Color::Default => default,
        Color::Rgb(r, g, b) => (r, g, b),
        Color::Indexed(n) if n < 16 => ANSI_16[n as usize],
        Color::Indexed(_) => default,
    }
}

fn main() {
    let cols = 40;
    let rows = 10;
    let mut term = Terminal::new(cols, rows);

    // Real-world-shaped output: SGR truecolor + indexed colors, bold,
    // underline, DEC Special Graphics box drawing, wide CJK + emoji, a tab
    // stop, and a Primary Device Attributes query (answered via take_output).
    let input = [
        "\x1b[1;38;2;255;80;0mBOLD ORANGE\x1b[0m ",
        "\x1b[42;30mGREEN-BG\x1b[0m ",
        "\x1b[4mUNDERLINE\x1b[0m\n",
        "\x1b(0lqqqqqqk\x1b(B\n",  // ┌──────┐
        "\x1b(0x\x1b(B box \x1b(0x\x1b(B\n", // │ box │
        "\x1b(0mqqqqqqj\x1b(B\n",  // └──────┘
        "col0\tcol8(tab)\n",
        "\u{4e2d}\u{6587} + emoji \u{1f680}\n",
        "\x1b[c",  // DA1 query -- answered via Terminal::take_output()
    ]
    .concat();

    term.feed(input.as_bytes());

    let da_reply = term.take_output();
    println!(
        "DA1 query -> queued reply: {:?} ({})\n",
        String::from_utf8_lossy(&da_reply),
        if da_reply == b"\x1b[?62;22c" { "correct" } else { "WRONG" }
    );

    println!("cursor: {:?}  autowrap: {}\n", term.cursor(), term.modes().autowrap);

    let grid = term.active_grid();
    for row in 0..rows {
        for col in 0..cols {
            let Some(cell) = grid.get(row, col) else { continue };
            if cell.is_wide_spacer {
                continue;
            }
            let (fr, fg, fb) = resolve(cell.fg, (220, 220, 220));
            let (br, bg, bb) = resolve(cell.bg, (0, 0, 0));
            let bold = if cell.attrs.contains(tako_core::grid::CellAttrs::BOLD) { "1;" } else { "" };
            let underline = if cell.attrs.contains(tako_core::grid::CellAttrs::UNDERLINE) { "4;" } else { "" };
            print!(
                "\x1b[{}{}38;2;{};{};{};48;2;{};{};{}m{}\x1b[0m",
                bold, underline, fr, fg, fb, br, bg, bb, cell.char
            );
        }
        println!();
    }

    println!(
        "\nKitty Graphics placements: {:?}",
        term.graphics_placements()
    );
}
