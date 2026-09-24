use tako_core::parser::{Parser, Perform};

struct DemoPerformer;

impl Perform for DemoPerformer {
    fn print(&mut self, c: char) { print!("{}", c); }
    fn execute(&mut self, byte: u8) { println!("\n[EXECUTE: {:#04X}]", byte); }
    fn hook(&mut self, params: &[u16], _: u32, intermediates: &[u8], _: bool, action: char) {
        println!("\n[HOOK: action={} params={:?} inter={:?}]", action, params, intermediates);
    }
    fn put(&mut self, byte: u8) { print!("{}", byte as char); }
    fn unhook(&mut self) { println!("\n[UNHOOK]"); }
    fn osc_dispatch(&mut self, params: &[&[u8]], bell: bool) {
        let strings: Vec<String> = params.iter().map(|p| String::from_utf8_lossy(p).into_owned()).collect();
        println!("\n[OSC: bell={} params={:?}]", bell, strings);
    }
    fn csi_dispatch(&mut self, params: &[u16], _: u32, intermediates: &[u8], _: bool, action: char) {
        println!("\n[CSI: action={} params={:?} inter={:?}]", action, params, intermediates);
    }
    fn esc_dispatch(&mut self, intermediates: &[u8], _: bool, byte: u8) {
        println!("\n[ESC: byte={} inter={:?}]", byte as char, intermediates);
    }
}

fn main() {
    let mut parser = Parser::new();
    let mut performer = DemoPerformer;

    // A sample string mimicking output from a program (e.g. `ls --color`)
    // It includes SGR color codes, cursor movements, and an OSC window title.
    let input = b"\x1B]0;My Rust Terminal\x07\x1B[31;1mHello\x1B[0m \x1B[32mWorld!\x1B[0m\x1B[2;10H";

    println!("Feeding ANSI string into the Rust VT100 FSM parser...\n");
    for &byte in input.iter() {
        parser.advance(&mut performer, byte);
    }
    println!("\n\nParsing complete!");
}
