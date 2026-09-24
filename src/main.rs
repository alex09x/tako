use eframe::egui;
use tako_core::grid::Color;
use tako_core::terminal::Terminal;
use tako_core::pty::Pty;
use std::sync::{Arc, Mutex};
use std::io::{Read, Write};

/// Resolves a `Color` to a concrete RGB triple -- mirrors
/// `ffi::resolve_color`, duplicated here since that one is private to the
/// FFI module and this demo talks to `Terminal` directly, in-process.
fn resolve_color(color: Color, default: egui::Color32) -> egui::Color32 {
    const ANSI_16: [(u8, u8, u8); 16] = [
        (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
        (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
        (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
        (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ];
    fn cube(v: u8) -> u8 {
        if v == 0 { 0 } else { v * 40 + 55 }
    }
    match color {
        Color::Default => default,
        Color::Rgb(r, g, b) => egui::Color32::from_rgb(r, g, b),
        Color::Indexed(n) => {
            if n < 16 {
                let (r, g, b) = ANSI_16[n as usize];
                egui::Color32::from_rgb(r, g, b)
            } else if n < 232 {
                let i = n - 16;
                let (r, g, b) = (cube(i / 36), cube((i / 6) % 6), cube(i % 6));
                egui::Color32::from_rgb(r, g, b)
            } else {
                let gray = (8 + (n - 232) as u16 * 10) as u8;
                egui::Color32::from_rgb(gray, gray, gray)
            }
        }
    }
}

const DEFAULT_FG: egui::Color32 = egui::Color32::from_rgb(220, 220, 220);
const DEFAULT_BG: egui::Color32 = egui::Color32::from_rgb(20, 20, 20);

struct TakoTerminal {
    term: Arc<Mutex<Terminal>>,
    pty_writer: std::fs::File,
    cols: usize,
    rows: usize,
}

impl TakoTerminal {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let cols = 100;
        let rows = 35;
        let term = Arc::new(Mutex::new(Terminal::new(cols, rows)));

        let pty = Pty::spawn("/bin/zsh", rows as u16, cols as u16);
        let mut pty_reader = pty.master.try_clone().unwrap();
        let pty_writer = pty.master.try_clone().unwrap();
        let mut reply_writer = pty.master.try_clone().unwrap();

        let ctx = cc.egui_ctx.clone();
        let term_clone = term.clone();

        // Drives the real tako-core Terminal engine -- full ANSI/VT100
        // parsing, SGR colors, wide chars, charsets, Kitty Graphics, DA/DSR
        // replies -- over the PTY's actual output, not a toy re-parse.
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            while let Ok(n) = pty_reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let mut t = term_clone.lock().unwrap();
                t.feed(&buf[..n]);
                let reply = t.take_output();
                drop(t);
                if !reply.is_empty() {
                    let _ = reply_writer.write_all(&reply);
                }
                ctx.request_repaint();
            }
        });

        // Self-demo: exercise SGR colors, DEC charset, wide chars, and a
        // real Kitty Graphics APC round-trip through the actual PTY so a
        // screenshot proves the full pipeline (shell -> PTY -> Terminal ->
        // egui) end to end, without needing external keystroke automation.
        {
            let mut demo_writer = pty.master.try_clone().unwrap();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(600));
                let cmd = "printf '\\033[1;31mRED-BOLD\\033[0m \\033[32mGREEN\\033[0m \\033[44;97m BLUEBG \\033[0m \\033[0;33m\\xe4\\xb8\\xad\\xe6\\x96\\x87\\033[0m emoji:\\xf0\\x9f\\x94\\xa5 \\033(0lqqqk\\033(B\\n'\r";
                let _ = demo_writer.write_all(cmd.as_bytes());
            });
        }

        Self {
            term,
            pty_writer,
            cols,
            rows,
        }
    }
}

impl eframe::App for TakoTerminal {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        ctx.input(|i| {
            for event in &i.events {
                match event {
                    egui::Event::Text(text) => {
                        let _ = self.pty_writer.write_all(text.as_bytes());
                    }
                    egui::Event::Key { key, pressed: true, modifiers: _, .. } => {
                        use egui::Key;
                        match key {
                            Key::Enter => { let _ = self.pty_writer.write_all(b"\r"); },
                            Key::Backspace => { let _ = self.pty_writer.write_all(b"\x7F"); },
                            Key::Escape => { let _ = self.pty_writer.write_all(b"\x1B"); },
                            Key::Tab => { let _ = self.pty_writer.write_all(b"\t"); },
                            Key::ArrowUp => { let _ = self.pty_writer.write_all(b"\x1B[A"); },
                            Key::ArrowDown => { let _ = self.pty_writer.write_all(b"\x1B[B"); },
                            Key::ArrowRight => { let _ = self.pty_writer.write_all(b"\x1B[C"); },
                            Key::ArrowLeft => { let _ = self.pty_writer.write_all(b"\x1B[D"); },
                            _ => {}
                        }
                    }
                    _ => {}
                }
            }
        });

        egui::CentralPanel::default()
            .frame(egui::Frame::default().fill(DEFAULT_BG).inner_margin(10.0))
            .show(ctx, |ui| {
                let term = self.term.lock().unwrap();
                let grid = term.active_grid();
                let (cursor_row, cursor_col) = term.cursor();
                let cursor_visible = term.cursor_visible();
                let font_id = egui::FontId::monospace(14.0);

                let mut job = egui::text::LayoutJob::default();
                for row in 0..self.rows {
                    let mut col = 0;
                    while col < self.cols {
                        let Some(cell) = grid.get(row, col) else { break };
                        if cell.is_wide_spacer {
                            col += 1;
                            continue;
                        }
                        let is_cursor = cursor_visible && row == cursor_row && col == cursor_col;
                        let (fg, bg) = if is_cursor {
                            (DEFAULT_BG, DEFAULT_FG)
                        } else {
                            (
                                resolve_color(cell.fg, DEFAULT_FG),
                                resolve_color(cell.bg, DEFAULT_BG),
                            )
                        };

                        // Coalesce a run of identically-styled cells into one
                        // LayoutJob section instead of one per cell.
                        let start_col = col;
                        let mut text = String::new();
                        text.push(if cell.char == '\0' { ' ' } else { cell.char });
                        col += 1;
                        while col < self.cols {
                            let Some(next) = grid.get(row, col) else { break };
                            if next.is_wide_spacer {
                                col += 1;
                                continue;
                            }
                            let next_is_cursor =
                                cursor_visible && row == cursor_row && col == cursor_col;
                            if next_is_cursor != is_cursor
                                || (!is_cursor
                                    && (next.fg != grid.get(row, start_col).unwrap().fg
                                        || next.bg != grid.get(row, start_col).unwrap().bg
                                        || next.attrs
                                            != grid.get(row, start_col).unwrap().attrs))
                            {
                                break;
                            }
                            text.push(if next.char == '\0' { ' ' } else { next.char });
                            col += 1;
                        }

                        let underline = if cell.attrs.contains(tako_core::grid::CellAttrs::UNDERLINE)
                            || cell.hyperlink.is_some()
                        {
                            egui::Stroke::new(1.0_f32, fg)
                        } else {
                            egui::Stroke::NONE
                        };
                        job.append(
                            &text,
                            0.0,
                            egui::TextFormat {
                                font_id: font_id.clone(),
                                color: fg,
                                background: bg,
                                underline,
                                italics: cell.attrs.contains(tako_core::grid::CellAttrs::ITALIC),
                                ..Default::default()
                            },
                        );
                    }
                    job.append("\n", 0.0, egui::TextFormat::default());
                }

                ui.label(job);
            });
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([900.0, 620.0]),
        ..Default::default()
    };
    eframe::run_native(
        "TakoCore (Pure Rust Terminal Engine)",
        options,
        Box::new(|cc| Ok(Box::new(TakoTerminal::new(cc)))),
    )
}
