/*
 * tako — Native control transport fail-closed self-test
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
import Darwin
import Foundation

/// Only private socket pairs and a listener in this test's own directory.
/// No application is launched or signalled and no request reaches Tako.
func runControlRequestSocketSelfTest(work: URL) throws {
    var checks = 0
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure("control transport self-test: \(name)") }
        checks += 1
    }
    func refused(_ name: String, _ action: () throws -> Void) throws {
        var failed = false
        do { try action() } catch { failed = true }
        try check(failed, name)
    }
    let valid = Data("{\"ok\":true,\"result\":{\"echo\":\"yes\"}}\n".utf8)
    let decoded = try ControlRequestSocket.decode(valid)
    try check((decoded["result"] as? [String: String])?["echo"] == "yes", "a real successful reply is decoded")
    for text in ["{}\n", "{\"ok\":1,\"result\":{}}\n", "{\"ok\":\"true\",\"result\":{}}\n",
                 "{\"ok\":false,\"error\":{\"message\":\"probe\"}}\n", "{\"ok\":true}\n", "garbage\n",
                 "{\"ok\":true,\"result\":{}}", "{\"ok\":true,\"result\":{}}\n{}\n"] {
        try refused("invalid/refused reply cannot pass: \(text.prefix(45))") { _ = try ControlRequestSocket.decode(Data(text.utf8)) }
    }
    try refused("oversized replies cannot pass") {
        _ = try ControlRequestSocket.decode(Data(repeating: 32, count: ControlRequestSocket.maxBytes + 1))
    }

    var pair = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Failure("self-test socketpair failed") }
    defer { pair.forEach { close($0) } }
    let responseWritten = valid.withUnsafeBytes { send(pair[1], $0.baseAddress, $0.count, 0) }
    guard responseWritten == valid.count else { throw Failure("self-test response setup failed") }
    let request = try ControlRequestSocket.encode(["cmd": "workspace", "args": ["action": "switch", "name": "probe"]])
    _ = try ControlRequestSocket.exchange(pair[0], request: request, deadline: ControlRequestSocket.now + 1)
    var bytes = [UInt8](repeating: 0, count: 1024)
    let received = bytes.withUnsafeMutableBytes { recv(pair[1], $0.baseAddress, $0.count, 0) }
    try check(received == request.count && Data(bytes.prefix(max(0, received))) == request,
              "exchange actually writes the whole request and newline")
    let wire = try JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any]
    try check(request.last == 0x0a && wire?["cmd"] as? String == "workspace" &&
              (wire?["args"] as? [String: String])?["name"] == "probe", "request preserves public protocol fields")

    // The driver's existing lifecycle removes this on a proven pass and
    // retains it on failure; no separate best-effort cleanup can hide a leak.
    let root = work.appendingPathComponent("control-socket-selftest").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    let path = root + "/control.sock"
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw Failure("self-test listener failed") }
    defer { close(listener) }
    var address = try ControlRequestSocket.address(path)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 4) == 0 else { throw Failure("self-test listener setup failed") }
    let good = try ControlRequestSocket.open(path, expectedPID: getpid(), deadline: ControlRequestSocket.now + 1)
    close(good)
    try ControlRequestSocket.ready(listener, events: Int16(POLLIN), deadline: ControlRequestSocket.now + 1)
    let accepted = accept(listener, nil, nil)
    guard accepted >= 0 else { throw Failure("self-test accept failed") }
    close(accepted)
    try check(true, "the current process's real local socket is admitted")
    try refused("a different process cannot receive a race request") {
        let unexpected = try ControlRequestSocket.open(path, expectedPID: getpid() + 100_000,
                                                       deadline: ControlRequestSocket.now + 1)
        close(unexpected)
    }
    try ControlRequestSocket.ready(listener, events: Int16(POLLIN), deadline: ControlRequestSocket.now + 1)
    let rejected = accept(listener, nil, nil)
    guard rejected >= 0 else { throw Failure("self-test rejected connection was not observable") }
    defer { close(rejected) }
    var byte: UInt8 = 0
    try check(recv(rejected, &byte, 1, 0) == 0, "a wrong peer is refused before any request byte")
    let alias = root + "/alias.sock"
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
    try refused("a symlink is not a plain control endpoint") {
        let unexpected = try ControlRequestSocket.open(alias, expectedPID: getpid(), deadline: ControlRequestSocket.now + 1)
        close(unexpected)
    }
    guard checks == 16 else { throw Failure("control transport self-test executed only \(checks) controls") }
    print("control request transport self-test: \(checks) checks ok")
}
