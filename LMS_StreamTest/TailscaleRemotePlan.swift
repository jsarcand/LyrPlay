// File: TailscaleRemotePlan.swift
// Decides which tailnet address LyrPlay should dial when the saved server
// is not on the local network. No sockets and no Tailscale library here.

import Foundation

struct TailscalePeer: Equatable {
    var hostName: String
    var dnsName: String
    var os: String
    var online: Bool
    var expired: Bool
    var routes: [String]
}

struct TailscaleSnapshot: Equatable {
    var backendState: String
    var authURL: String?
    var magicDNSSuffix: String
    var selfDNSName: String
    var peers: [TailscalePeer]
}

enum TailscaleDialPlan: Equatable {
    case direct(host: String, web: Int, slim: Int, label: String)
    case probe(hosts: [String], web: Int, slim: Int)
}

enum TailscaleRemotePlan {
    /// Hostnames that are more likely to be the music server than a phone.
    static let serverNameHints = ["lyrion", "lms", "audio", "slim", "squeeze", "pcp", "picore", "music", "maison"]

    static func snapshot(from data: Data) -> TailscaleSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let auth = (root["AuthURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tailnet = root["CurrentTailnet"] as? [String: Any]
        let suffix = (tailnet?["MagicDNSSuffix"] as? String) ?? (root["MagicDNSSuffix"] as? String) ?? ""
        let selfPeer = root["Self"] as? [String: Any]
        var peers: [TailscalePeer] = []
        if let peerMap = root["Peer"] as? [String: Any] {
            for value in peerMap.values {
                guard let peer = value as? [String: Any] else { continue }
                peers.append(parsePeer(peer))
            }
        }
        return TailscaleSnapshot(
            backendState: root["BackendState"] as? String ?? "",
            authURL: (auth?.isEmpty == false) ? auth : nil,
            magicDNSSuffix: suffix,
            selfDNSName: selfPeer?["DNSName"] as? String ?? "",
            peers: peers
        )
    }

    static func dialPlan(savedHost: String, webPort: Int, slimPort: Int, rememberedHost: String, snapshot: TailscaleSnapshot) -> TailscaleDialPlan {
        let remembered = normalize(rememberedHost)
        if !remembered.isEmpty {
            return .direct(host: remembered, web: webPort, slim: slimPort, label: remembered)
        }

        let saved = normalize(savedHost)
        if isMagicDNS(saved, suffix: snapshot.magicDNSSuffix) || isTailscaleCGNAT(saved) {
            return .direct(host: saved, web: webPort, slim: slimPort, label: saved)
        }
        if ipv4(saved) != nil {
            let covered = snapshot.peers.contains { peer in
                peer.online && !peer.expired && peer.routes.contains { cidrContains($0, host: saved) }
            }
            if covered {
                return .direct(host: saved, web: webPort, slim: slimPort, label: saved)
            }
        }

        let selfName = normalize(snapshot.selfDNSName)
        let ranked = snapshot.peers
            .filter { peer in
                let name = normalize(peer.dnsName)
                return peer.online && !peer.expired && !name.isEmpty && name != selfName && isPlausibleServer(peer)
            }
            .sorted { score($0) > score($1) }
        let names = ranked.prefix(16).map { normalize($0.dnsName) }
        return .probe(hosts: Array(names), web: webPort, slim: slimPort)
    }

    static func isMagicDNS(_ host: String, suffix: String = "") -> Bool {
        let name = normalize(host)
        if name.hasSuffix(".ts.net") { return true }
        let extra = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return !extra.isEmpty && (name == extra || name.hasSuffix("." + extra))
    }

    static func isTailscaleCGNAT(_ host: String) -> Bool {
        cidrContains("100.64.0.0/10", host: host)
    }

    static func cidrContains(_ cidr: String, host: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits),
              let network = ipv4(String(parts[0])), let addr = ipv4(host) else {
            return false
        }
        if bits == 0 { return true }
        let mask = UInt32.max << UInt32(32 - bits)
        return (pack(network) & mask) == (pack(addr) & mask)
    }

    static func looksLikeLMS(_ raw: String) -> Bool {
        let text = raw.lowercased()
        if text.contains("lyrion") || text.contains("logitech media server") || text.contains("squeezebox server") {
            return true
        }
        guard text.contains("\"result\"") else { return false }
        if text.contains("version") { return true }
        return text.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil
    }

    static func lmsProbeRequest(host: String, port: Int) -> String {
        let body = "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"\",[\"version\",\"?\"]]}"
        return "POST /jsonrpc.js HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            let port = text[text.index(after: colon)...]
            if Int(port) != nil {
                text = String(text[..<colon])
            }
        }
        return text
    }

    private static func isPlausibleServer(_ peer: TailscalePeer) -> Bool {
        switch peer.os.lowercased() {
        case "ios", "android", "tvos":
            return false
        default:
            return true
        }
    }

    private static func score(_ peer: TailscalePeer) -> Int {
        let blob = (peer.hostName + " " + peer.dnsName).lowercased()
        var value = 0
        for hint in serverNameHints where blob.contains(hint) {
            value += 10
        }
        if !peer.routes.isEmpty { value += 3 }
        return value
    }

    private static func parsePeer(_ peer: [String: Any]) -> TailscalePeer {
        let primary = stringList(peer["PrimaryRoutes"])
        let allowed = stringList(peer["AllowedIPs"]).filter { !$0.hasSuffix("/32") && !$0.hasSuffix("/128") }
        return TailscalePeer(
            hostName: peer["HostName"] as? String ?? "",
            dnsName: peer["DNSName"] as? String ?? "",
            os: peer["OS"] as? String ?? "",
            online: peer["Online"] as? Bool ?? false,
            expired: peer["Expired"] as? Bool ?? false,
            routes: primary.isEmpty ? allowed : primary
        )
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] {
            return list.compactMap { $0 as? String }
        }
        return []
    }

    private static func ipv4(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    private static func pack(_ ip: (UInt8, UInt8, UInt8, UInt8)) -> UInt32 {
        (UInt32(ip.0) << 24) | (UInt32(ip.1) << 16) | (UInt32(ip.2) << 8) | UInt32(ip.3)
    }
}
