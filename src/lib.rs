pub mod parser;
pub mod grid;
pub mod terminal;
pub mod ffi;
pub mod charset;
pub mod modes;
pub mod tabstops;
pub mod kitty_keyboard;
pub mod response;
pub mod graphics;
pub mod cursor_style;
pub mod palette;
pub mod title_stack;
pub mod key_encode;
pub mod mouse_encode;
pub mod paste;
pub mod capi;
#[cfg(feature = "pty")]
pub mod pty;
#[cfg(feature = "ssh")]
pub mod ssh;

uniffi::setup_scaffolding!();
