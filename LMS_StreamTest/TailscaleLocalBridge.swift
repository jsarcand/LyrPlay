// File: TailscaleLocalBridge.swift
// Listens on 127.0.0.1 and copies bytes to a connection the caller dials.
// SlimProto, the Material web view and BASS all keep using normal sockets.
// Only the far end of the copy goes through the tailnet.

import Darwin
import Foundation

final class TailscaleLocalBridge {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var stopped = false
    private let queue = DispatchQueue(label: "com.lmsstream.tailscale.bridge")

    /// Starts listening. `dial` is called for each accepted client and must
    /// return a connected socket, or -1 if the far end could not be reached.
    func start(dial: @escaping @Sendable () async -> Int32) throws -> UInt16 {
        stop()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socket }
        Self.setNoSigPipe(fd)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        let bound = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw BridgeError.bind
        }
        let port = Self.port(of: fd)
        guard port != 0 else {
            Darwin.close(fd)
            throw BridgeError.bind
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        lock.lock()
        stopped = false
        listenFD = fd
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptReady(listenFD: fd, dial: dial)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        acceptSource = source
        source.resume()
        return port
    }

    func stop() {
        lock.lock()
        stopped = true
        listenFD = -1
        let source = acceptSource
        acceptSource = nil
        lock.unlock()
        source?.cancel()
    }

    /// Writes `request` and reads the reply until the peer closes or the timeout.
    static func exchange(fd: Int32, request: String, timeoutSeconds: Int) -> String {
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
        setNoSigPipe(fd)
        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if wrote <= 0 { return "" }
            sent += wrote
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var collected = Data()
        while collected.count < 16384 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            collected.append(buffer, count: count)
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    /// True when a TCP handshake to `host` finishes within `timeout`.
    static func tcpReachable(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard let address = ipv4Address(host) else { return false }
        addr.sin_addr.s_addr = address
        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        if errno != EINPROGRESS { return false }
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let waited = poll(&pollFD, 1, Int32(timeout * 1000))
        guard waited > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    /// Opens a plain TCP connection. Used by tests and by nothing on the tailnet.
    static func connectTCP(host: String, port: UInt16) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        setNoSigPipe(fd)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard let address = ipv4Address(host) else {
            Darwin.close(fd)
            return -1
        }
        addr.sin_addr.s_addr = address
        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    private func acceptReady(listenFD: Int32, dial: @escaping @Sendable () async -> Int32) {
        while true {
            var clientAddr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenFD, sa, &length)
                }
            }
            if client < 0 {
                break
            }
            lock.lock()
            let closed = stopped
            lock.unlock()
            if closed {
                Darwin.close(client)
                break
            }
            Self.setNoSigPipe(client)
            var nodelay: Int32 = 1
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout.size(ofValue: nodelay)))
            Task.detached {
                let remote = await dial()
                guard remote >= 0 else {
                    Darwin.close(client)
                    return
                }
                Self.setNoSigPipe(remote)
                Self.splice(client, remote)
            }
        }
    }

    private static func splice(_ left: Int32, _ right: Int32) {
        let link = Link(left, right)
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async { copy(from: left, to: right, link: link) }
        queue.async { copy(from: right, to: left, link: link) }
    }

    private static func copy(from source: Int32, to destination: Int32, link: Link) {
        var buffer = [UInt8](repeating: 0, count: 32768)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count <= 0 { break }
            var sent = 0
            var failed = false
            while sent < count {
                let wrote = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(destination, base.advanced(by: sent), count - sent)
                }
                if wrote <= 0 {
                    failed = true
                    break
                }
                sent += wrote
            }
            if failed { break }
        }
        link.directionFinished(writingTo: destination)
    }

    private static func port(of fd: Int32) -> UInt16 {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard result == 0 else { return 0 }
        return UInt16(bigEndian: addr.sin_port)
    }

    private static func ipv4Address(_ host: String) -> in_addr_t? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return in_addr_t(value).bigEndian
    }

    private static func setNoSigPipe(_ fd: Int32) {
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }

    private final class Link: @unchecked Sendable {
        let left: Int32
        let right: Int32
        let lock = NSLock()
        var readers = 2

        init(_ left: Int32, _ right: Int32) {
            self.left = left
            self.right = right
        }

        /// Half-closes the side we were writing. Shutting both directions down
        /// aborts the socket and drops bytes the other end has not read yet.
        func directionFinished(writingTo destination: Int32) {
            lock.lock()
            readers -= 1
            let last = readers == 0
            lock.unlock()
            _ = Darwin.shutdown(destination, SHUT_WR)
            if last {
                Darwin.close(left)
                Darwin.close(right)
            }
        }
    }

    enum BridgeError: Error {
        case socket
        case bind
    }
}
