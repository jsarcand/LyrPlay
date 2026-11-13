// File: TailscaleRemotePlanTests.swift
// The dial plan and the localhost bridge have no Tailscale library dependency,
// so they can be checked without a tailnet or an xcframework.
import Darwin
import Foundation
import Testing
@testable import LMS_StreamTest

struct TailscaleRemotePlanTests {
    private func peer(_ name: String, os: String = "linux", online: Bool = true,
                      expired: Bool = false, routes: [String] = [], dns: String? = nil) -> TailscalePeer {
        TailscalePeer(hostName: name, dnsName: dns ?? "\(name).tailnet.ts.net",
                      os: os, online: online, expired: expired, routes: routes)
    }

    private func snapshot(_ peers: [TailscalePeer], suffix: String = "tailnet.ts.net",
                          selfName: String = "phone.tailnet.ts.net") -> TailscaleSnapshot {
        TailscaleSnapshot(backendState: "Running", authURL: nil, magicDNSSuffix: suffix,
                          selfDNSName: selfName, peers: peers)
    }

    @Test func magicDNSAndCGNAT() {
        #expect(TailscaleRemotePlan.isMagicDNS("Audio.Tailnet.ts.net."))
        #expect(TailscaleRemotePlan.isMagicDNS("audio.example.com", suffix: "example.com"))
        #expect(!TailscaleRemotePlan.isMagicDNS("10.4.4.4"))
        #expect(TailscaleRemotePlan.isTailscaleCGNAT("100.64.0.1"))
        #expect(TailscaleRemotePlan.isTailscaleCGNAT("100.127.255.254"))
        #expect(!TailscaleRemotePlan.isTailscaleCGNAT("100.128.0.1"))
        #expect(!TailscaleRemotePlan.isTailscaleCGNAT("10.4.4.4"))
    }

    @Test func cidrBounds() {
        #expect(TailscaleRemotePlan.cidrContains("192.168.1.0/24", host: "192.168.1.0"))
        #expect(TailscaleRemotePlan.cidrContains("192.168.1.0/24", host: "192.168.1.255"))
        #expect(!TailscaleRemotePlan.cidrContains("192.168.1.0/24", host: "192.168.2.1"))
        #expect(TailscaleRemotePlan.cidrContains("100.64.0.0/10", host: "100.64.0.1"))
        #expect(!TailscaleRemotePlan.cidrContains("100.64.0.0/10", host: "100.128.0.1"))
        #expect(TailscaleRemotePlan.cidrContains("192.168.1.5/32", host: "192.168.1.5"))
        #expect(!TailscaleRemotePlan.cidrContains("192.168.1.5/32", host: "192.168.1.6"))
        #expect(TailscaleRemotePlan.cidrContains("0.0.0.0/0", host: "8.8.8.8"))
        #expect(!TailscaleRemotePlan.cidrContains("nope", host: "192.168.1.1"))
        #expect(!TailscaleRemotePlan.cidrContains("192.168.1.0/33", host: "192.168.1.1"))
    }

    @Test func rememberedHostWins() {
        let plan = TailscaleRemotePlan.dialPlan(
            savedHost: "10.4.4.4", webPort: 9000, slimPort: 3483,
            rememberedHost: "Audio.Tailnet.ts.net.",
            snapshot: snapshot([peer("audio", routes: ["10.4.4.0/24"])]))
        #expect(plan == .direct(host: "audio.tailnet.ts.net", web: 9000, slim: 3483, label: "audio.tailnet.ts.net"))
    }

    @Test func savedMagicDNSAndCoveredLANDialDirect() {
        let magic = TailscaleRemotePlan.dialPlan(
            savedHost: "audio.tailnet.ts.net:9000", webPort: 9000, slimPort: 3483,
            rememberedHost: "", snapshot: snapshot([]))
        #expect(magic == .direct(host: "audio.tailnet.ts.net", web: 9000, slim: 3483, label: "audio.tailnet.ts.net"))

        let lan = TailscaleRemotePlan.dialPlan(
            savedHost: "10.4.4.4", webPort: 9000, slimPort: 3483,
            rememberedHost: "  ",
            snapshot: snapshot([peer("nas", routes: ["10.4.4.0/24"])]))
        #expect(lan == .direct(host: "10.4.4.4", web: 9000, slim: 3483, label: "10.4.4.4"))
    }

    @Test func probeSkipsPhonesSelfAndExpiredAndRanksServers() {
        var crowd: [TailscalePeer] = [
            peer("phone", os: "iOS"),
            peer("tablet", os: "android"),
            peer("box", os: "tvos"),
            peer("old", expired: true),
            peer("down", online: false),
            peer("me", dns: "phone.tailnet.ts.net"),
        ]
        for index in 0..<20 {
            crowd.append(peer("node\(index)"))
        }
        crowd.append(peer("audio", routes: ["10.1.0.0/16"]))
        let plan = TailscaleRemotePlan.dialPlan(
            savedHost: "10.9.9.9", webPort: 9000, slimPort: 3483,
            rememberedHost: "", snapshot: snapshot(crowd))
        guard case .probe(let hosts, 9000, 3483) = plan else {
            Issue.record("expected a probe, got \(plan)")
            return
        }
        #expect(hosts.count == 16)
        #expect(hosts.first == "audio.tailnet.ts.net")
        #expect(!hosts.contains("phone.tailnet.ts.net"))
        #expect(!hosts.contains("tablet.tailnet.ts.net"))
        #expect(!hosts.contains("old.tailnet.ts.net"))
    }

    @Test func uncoveredLANWithNoPeersProbesNobody() {
        let plan = TailscaleRemotePlan.dialPlan(
            savedHost: "10.9.9.9", webPort: 9000, slimPort: 3483,
            rememberedHost: "", snapshot: snapshot([]))
        #expect(plan == .probe(hosts: [], web: 9000, slim: 3483))
    }

    @Test func looksLikeLMSAndProbeRequest() {
        #expect(TailscaleRemotePlan.looksLikeLMS("{\"result\":{\"_version\":\"9.0.2\"}}"))
        #expect(TailscaleRemotePlan.looksLikeLMS("Lyrion Music Server"))
        #expect(TailscaleRemotePlan.looksLikeLMS("Logitech Media Server"))
        #expect(!TailscaleRemotePlan.looksLikeLMS("{\"ok\":true}"))
        #expect(!TailscaleRemotePlan.looksLikeLMS(""))
        let request = TailscaleRemotePlan.lmsProbeRequest(host: "audio.tailnet.ts.net", port: 9000)
        #expect(request.contains("POST /jsonrpc.js HTTP/1.1"))
        #expect(request.contains("Host: audio.tailnet.ts.net:9000"))
        #expect(request.contains("\"version\",\"?\""))
    }

    @Test func statusJSONReadsPeersRoutesAndAuthURL() throws {
        let json = """
        {"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/example",
         "CurrentTailnet":{"MagicDNSSuffix":"tailnet.ts.net"},
         "Self":{"DNSName":"phone.tailnet.ts.net."},
         "Peer":{
            "n1":{"HostName":"Audio","DNSName":"audio.tailnet.ts.net.","OS":"linux","Online":true,
                  "PrimaryRoutes":["192.168.1.0/24"],"AllowedIPs":["100.1.2.3/32"]},
            "n2":{"HostName":"OnlyAllowed","DNSName":"nas.tailnet.ts.net.","OS":"linux","Online":true,
                  "AllowedIPs":["10.0.0.0/8","100.9.9.9/32","fd7a::1/128"]}
         }}
        """.data(using: .utf8)!
        let parsed = try #require(TailscaleRemotePlan.snapshot(from: json))
        #expect(parsed.backendState == "NeedsLogin")
        #expect(parsed.authURL == "https://login.tailscale.com/a/example")
        #expect(parsed.magicDNSSuffix == "tailnet.ts.net")
        #expect(parsed.selfDNSName == "phone.tailnet.ts.net.")
        let audio = try #require(parsed.peers.first { $0.hostName == "Audio" })
        #expect(audio.routes == ["192.168.1.0/24"])
        let nas = try #require(parsed.peers.first { $0.hostName == "OnlyAllowed" })
        #expect(nas.routes == ["10.0.0.0/8"])
    }

    @Test func blankAuthURLIsAbsent() throws {
        let json = "{\"BackendState\":\"Running\",\"AuthURL\":\"  \",\"Peer\":{}}".data(using: .utf8)!
        let parsed = try #require(TailscaleRemotePlan.snapshot(from: json))
        #expect(parsed.authURL == nil)
        #expect(parsed.peers.isEmpty)
    }

    @Test func localBridgeEchoesBytes() throws {
        let echo = EchoServer()
        let echoPort = try echo.start()
        defer { echo.stop() }
        let bridge = TailscaleLocalBridge()
        let local = try bridge.start {
            TailscaleLocalBridge.connectTCP(host: "127.0.0.1", port: echoPort)
        }
        defer { bridge.stop() }
        let fd = TailscaleLocalBridge.connectTCP(host: "127.0.0.1", port: local)
        #expect(fd >= 0)
        defer { if fd >= 0 { Darwin.close(fd) } }
        let reply = TailscaleLocalBridge.exchange(fd: fd, request: "ping", timeoutSeconds: 2)
        #expect(reply == "ping")
        #expect(TailscaleLocalBridge.tcpReachable(host: "127.0.0.1", port: echoPort, timeout: 1))
    }
}

/// Accepts one connection, writes back what it read, then closes.
private final class EchoServer {
    private var listenFD: Int32 = -1
    private var thread: Thread?

    func start() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EchoError.socket }
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
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw EchoError.bind
        }
        var got = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &got) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw EchoError.bind
        }
        listenFD = fd
        let port = UInt16(bigEndian: got.sin_port)
        let thread = Thread {
            var clientAddr = sockaddr_in()
            var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(fd, sa, &clientLength)
                }
            }
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                _ = Darwin.write(client, buffer, count)
            }
            Darwin.close(client)
        }
        thread.start()
        self.thread = thread
        return port
    }

    func stop() {
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    enum EchoError: Error { case socket, bind }
}
