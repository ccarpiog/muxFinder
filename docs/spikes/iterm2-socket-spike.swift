// Planning-session feasibility spike (2026-10-21) — reference only, not part of the build.
//
// Proves that a plain Swift process can talk to iTerm2's API (iTerm2 3.7.6) without Python:
// POSIX Unix socket + hand-written WebSocket handshake/framing + hand-encoded protobuf.
// Network.framework's NWProtocolWebSocket on a `.unix` endpoint failed with POSIX 53
// (ECONNABORTED), which is why this uses a raw socket.
//
// Observed output:
//   HTTP/1.1 101 Switching Protocols
//   list_sessions response: 682 bytes; head 08 01 d2 06 a4 05 0a e2
//   tmux list_connections response: 08 02 e2 07 02 20 00     (id=2, tmux_response{status=OK})
//
// Run (from a shell inside iTerm2, so no Automation prompt appears):
//   swiftc -O -o /tmp/spike docs/spikes/iterm2-socket-spike.swift
//   ITERM2_CK="$(osascript -e 'tell application "iTerm2" to request cookie and key for app named "muxFinder-spike"')" /tmp/spike
//
// Shortcuts taken that production code must not take: blocking I/O on the main thread, no
// timeouts, 16-bit max frame length on send, no continuation/ping/close handling, force unwraps.
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let parts = (ProcessInfo.processInfo.environment["ITERM2_CK"] ?? "").split(separator: " ")
guard parts.count == 2 else { print("need ITERM2_CK=\"<cookie> <key>\""); exit(2) }
let path = NSHomeDirectory() + "/Library/Application Support/iTerm2/private/socket"

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    path.utf8CString.withUnsafeBytes { src in memcpy(buf.baseAddress!, src.baseAddress!, min(buf.count - 1, src.count)) }
}
let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard rc == 0 else { print("connect failed", errno); exit(1) }

/// Writes every byte of `d` to the socket, exiting on error.
func writeAll(_ d: [UInt8]) {
    var off = 0
    while off < d.count {
        let n = d[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { print("write err"); exit(1) }
        off += n
    }
}

/// Performs one blocking read of up to 64 KiB.
func readSome() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 65536)
    let n = read(fd, &b, b.count)
    return n > 0 ? Array(b[0..<n]) : []
}

// Handshake. iTerm2 checks the subprotocol and the x-iterm2-* headers; the reply headers can
// arrive across several reads, so read until the blank line.
let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
let req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: api.iterm2.com\r\n"
    + "Origin: ws://localhost/\r\nx-iterm2-library-version: python 2.11\r\nx-iterm2-disable-auth-ui: true\r\n"
    + "x-iterm2-cookie: \(parts[0])\r\nx-iterm2-key: \(parts[1])\r\nx-iterm2-advisory-name: muxFinder-spike\r\n\r\n"
writeAll(Array(req.utf8))
var buf = readSome()
while buf.firstRange(of: Array("\r\n\r\n".utf8)) == nil {
    let more = readSome()
    if more.isEmpty { print("eof in headers"); exit(1) }
    buf += more
}
let headerEnd = buf.firstRange(of: Array("\r\n\r\n".utf8))!
print(String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self).split(separator: "\r\n").first!)
buf = Array(buf[headerEnd.upperBound...])

/// Sends one masked binary frame (client frames must be masked per RFC 6455).
func sendFrame(_ payload: [UInt8]) {
    var f: [UInt8] = [0x82]  // FIN + binary
    let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
    if payload.count < 126 {
        f.append(0x80 | UInt8(payload.count))
    } else {
        f.append(0x80 | 126)
        f += [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
    }
    f += mask
    f += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    writeAll(f)
}

/// Reads one unmasked server frame and returns its payload (no fragmentation support).
func readFrame() -> [UInt8] {
    while buf.count < 2 { buf += readSome() }
    var len = Int(buf[1] & 0x7f)
    var hdr = 2
    if len == 126 {
        while buf.count < 4 { buf += readSome() }
        len = Int(buf[2]) << 8 | Int(buf[3])
        hdr = 4
    } else if len == 127 {
        while buf.count < 10 { buf += readSome() }
        len = buf[2..<10].reduce(0) { $0 << 8 | Int($1) }
        hdr = 10
    }
    while buf.count < hdr + len { buf += readSome() }
    let p = Array(buf[hdr..<hdr + len])
    buf = Array(buf[(hdr + len)...])
    return p
}

// ClientOriginatedMessage{id=1, list_sessions_request(106)={}}: tag (106<<3|2)=850 → D2 06.
sendFrame([0x08, 0x01, 0xD2, 0x06, 0x00])
let r1 = readFrame()
print("list_sessions response:", r1.count, "bytes; head", r1.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))
// ClientOriginatedMessage{id=2, tmux_request(124)={list_connections(1)={}}}: tag 994 → E2 07.
sendFrame([0x08, 0x02, 0xE2, 0x07, 0x02, 0x0A, 0x00])
let r2 = readFrame()
print("tmux list_connections response:", r2.map { String(format: "%02x", $0) }.joined(separator: " "))
close(fd)
