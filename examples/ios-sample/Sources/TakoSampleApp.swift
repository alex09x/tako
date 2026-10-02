import SwiftUI
import TakoCoreUI
import UIKit

/// A pretend program on the other side of the terminal: it gets the bytes
/// the terminal produces from typing and answers with bytes to show.
final class EchoProgram {
    private var line = ""
    var output: (String) -> Void = { _ in }

    func start() {
        output("\u{1b}[1mTakoCore on iOS\u{1b}[0m: type, then return.\r\n$ ")
    }

    func input(_ data: Data) {
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            switch scalar {
            case "\r", "\n":
                output("\r\nyou typed: \u{1b}[32m\(line)\u{1b}[0m\r\n$ ")
                line = ""
            case "\u{7f}", "\u{8}":
                if !line.isEmpty {
                    line.removeLast()
                    output("\u{8} \u{8}")
                }
            default:
                guard scalar.value >= 0x20 else { continue }
                line.unicodeScalars.append(scalar)
                output(String(scalar))
            }
        }
    }
}

final class TerminalViewController: UIViewController, TakoTerminalViewDelegate {
    private let terminal = TakoTerminalView()
    private let program = EchoProgram()

    override func viewDidLoad() {
        super.viewDidLoad()
        terminal.delegate = self
        terminal.frame = view.bounds
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(terminal)
        program.output = { [weak self] text in self?.terminal.feed(data: Data(text.utf8)) }
        program.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminal.becomeFirstResponder()
    }

    // Typing: the program's input.
    func terminalView(_ view: TakoTerminalView, sendInputData data: Data) { program.input(data) }
    // Replies to the program's queries; this program asks none.
    func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data) {}
    // A real host tells the remote pty its new size here.
    func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int) {}
}

struct TerminalScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TerminalViewController { TerminalViewController() }
    func updateUIViewController(_ controller: TerminalViewController, context: Context) {}
}

@main
struct TakoSampleApp: App {
    var body: some Scene {
        WindowGroup { TerminalScreen().ignoresSafeArea(.keyboard) }
    }
}
