// File: TailscaleConnector.swift
// Embedded Tailscale node. Off the home network, LyrPlay joins the tailnet
// in-process and bridges the LMS ports to 127.0.0.1 so the rest of the app
// (SlimProto, Material, audio) does not have to know about Tailscale.
//
// The node is TailscaleKit, built by scripts/tailscale/build-framework.sh and
// linked into the app. Until that framework is linked, the connector reports
// that it is not in this build and leaves the normal connection path alone.

import Combine
import Darwin
import Foundation
import os.log
#if os(iOS)
import Network
import UIKit
#endif
#if os(iOS) && canImport(TailscaleKit)
import TailscaleKit
#endif

@MainActor
final class TailscaleConnector: ObservableObject {
    static let shared = TailscaleConnector()

    enum Phase: Equatable {
        case idle
        case starting
        case needsLogin
        case searching
        case connected
        case failed
        case unavailable
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusDetail: String = ""
    @Published private(set) var authURL: URL?

    /// Coordinator calls this after the local bridge is up, or after it is torn down.
    var onRouteReady: (() -> Void)?

    var wantsBanner: Bool {
        switch phase {
        case .starting, .needsLogin, .searching, .failed, .unavailable:
            return true
        case .idle, .connected:
            return false
        }
    }

    var bannerOpensLogin: Bool {
        phase == .needsLogin && authURL != nil
    }

    var bannerTitle: String {
        switch phase {
        case .needsLogin: return "Away from your server"
        case .starting, .searching: return "Connecting through Tailscale"
        case .failed: return "Tailscale couldn't reach the server"
        case .unavailable: return "Tailscale isn't in this build"
        case .idle, .connected: return ""
        }
    }

    var bannerDetail: String {
        switch phase {
        case .needsLogin: return "Log in once"
        case .starting: return "Starting"
        case .searching: return statusDetail.isEmpty ? "Looking for Lyrion" : statusDetail
        case .failed: return statusDetail.isEmpty ? "Tap to try again" : statusDetail
        case .unavailable: return "Run scripts/tailscale/build-framework.sh"
        case .idle, .connected: return ""
        }
    }

    /// Shown in Server settings while a remote session is up.
    var connectedName: String? {
        guard phase == .connected else { return nil }
        return statusDetail.isEmpty ? nil : statusDetail
    }

    private let logger = OSLog(subsystem: "com.lmsstream", category: "Tailscale")
    private var generation = 0
    private var directFailures = 0
    private var pathIsExpensive = false
    private var wasExpensive = false
    private var webBridge: TailscaleLocalBridge?
    private var slimBridge: TailscaleLocalBridge?
    #if os(iOS)
    private var pathMonitor: NWPathMonitor?
    #endif
    #if os(iOS) && canImport(TailscaleKit)
    private let dialer = EmbeddedTailscaleDialer()
    #endif

    static var libraryLinked: Bool {
        #if os(iOS) && canImport(TailscaleKit)
        return true
        #else
        return false
        #endif
    }

    private init() {
        #if os(iOS)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathUpdated(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.lmsstream.tailscale.path"))
        pathMonitor = monitor
        #endif
    }

    func prepareForConnect() {
        #if os(iOS)
        guard SettingsManager.shared.tailscaleRemoteEnabled else { return }
        guard SettingsManager.shared.sessionRoute == nil else { return }
        guard awayFromSavedServer(failures: directFailures) else { return }
        begin()
        #endif
    }

    func noteUnreachable() {
        #if os(iOS)
        guard SettingsManager.shared.tailscaleRemoteEnabled else { return }
        guard SettingsManager.shared.sessionRoute == nil else { return }
        directFailures += 1
        guard awayFromSavedServer(failures: directFailures) else { return }
        begin()
        #endif
    }

    func noteReachableDirectly() {
        directFailures = 0
        guard phase != .connected else { return }
        generation += 1
        guard phase != .idle else { return }
        phase = .idle
        authURL = nil
        statusDetail = ""
        #if os(iOS)
        Task { await closeDialer() }
        #endif
    }

    func restart() {
        #if os(iOS)
        generation += 1
        dropBridge()
        SettingsManager.shared.clearSessionRoute()
        phase = .idle
        authURL = nil
        statusDetail = ""
        directFailures = 0
        guard SettingsManager.shared.tailscaleRemoteEnabled else {
            onRouteReady?()
            return
        }
        begin()
        #endif
    }

    /// The user turned remote connection off. Drop the bridge and use the saved server.
    func userDisabled() {
        stopQuiet()
        onRouteReady?()
    }

    func stopQuiet() {
        generation += 1
        dropBridge()
        #if os(iOS)
        SettingsManager.shared.clearSessionRoute()
        Task { await self.closeDialer() }
        #endif
        phase = .idle
        authURL = nil
        statusDetail = ""
        directFailures = 0
    }

    func openLogin() {
        #if os(iOS)
        guard let authURL else { return }
        UIApplication.shared.open(authURL)
        #endif
    }

    #if os(iOS)
    private func pathUpdated(_ path: Network.NWPath) {
        pathIsExpensive = path.isExpensive
        if wasExpensive && !path.isExpensive && SettingsManager.shared.sessionRoute != nil {
            let token = generation
            Task { await preferLAN(token: token) }
        }
        wasExpensive = path.isExpensive
    }

    private func awayFromSavedServer(failures: Int) -> Bool {
        if pathIsExpensive { return true }
        if failures >= 2 { return true }
        let settings = SettingsManager.shared
        if TailscaleRemotePlan.isMagicDNS(settings.serverHost) { return true }
        if TailscaleRemotePlan.isMagicDNS(settings.tailscaleRememberedHost) { return true }
        return false
    }

    private func begin() {
        switch phase {
        case .starting, .searching, .needsLogin, .connected, .failed:
            return
        case .idle, .unavailable:
            break
        }
        guard !SettingsManager.shared.serverHost.isEmpty || !SettingsManager.shared.tailscaleRememberedHost.isEmpty else {
            return
        }
        #if canImport(TailscaleKit)
        generation += 1
        let token = generation
        phase = .starting
        statusDetail = ""
        authURL = nil
        os_log(.info, log: logger, "Starting embedded Tailscale node")
        Task { await run(token) }
        #else
        phase = .unavailable
        os_log(.info, log: logger, "TailscaleKit is not linked into this build")
        #endif
    }
    #endif

    private func dropBridge() {
        webBridge?.stop()
        slimBridge?.stop()
        webBridge = nil
        slimBridge = nil
    }

    private func closeDialer() async {
        #if os(iOS) && canImport(TailscaleKit)
        await dialer.close()
        #endif
    }
}

#if os(iOS) && canImport(TailscaleKit)
extension TailscaleConnector {
    fileprivate func run(_ token: Int) async {
        let directory = stateDirectory()
        let hostname = nodeHostname()
        do {
            try await dialer.start(hostname: hostname, directory: directory)
        } catch {
            guard token == generation else { return }
            phase = .failed
            statusDetail = "Could not start"
            os_log(.error, log: logger, "Tailscale start failed: %{public}s", String(describing: error))
            return
        }
        guard token == generation else {
            await closeDialer()
            return
        }

        var ready: TailscaleSnapshot?
        while token == generation {
            if let data = try? await dialer.status(), let snapshot = TailscaleRemotePlan.snapshot(from: data) {
                ready = snapshot
                if snapshot.backendState == "Running" { break }
                if let auth = snapshot.authURL, let url = URL(string: auth) {
                    authURL = url
                    phase = .needsLogin
                    os_log(.info, log: logger, "Tailscale needs a login")
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard token == generation, let snapshot = ready, snapshot.backendState == "Running" else { return }
        authURL = nil
        phase = .searching
        await findServer(snapshot, token: token)
    }

    fileprivate func findServer(_ snapshot: TailscaleSnapshot, token: Int) async {
        let settings = SettingsManager.shared
        let plan = TailscaleRemotePlan.dialPlan(
            savedHost: settings.serverHost,
            webPort: settings.serverWebPort,
            slimPort: settings.serverSlimProtoPort,
            rememberedHost: settings.tailscaleRememberedHost,
            snapshot: snapshot
        )
        switch plan {
        case .direct(let host, let web, let slim, let label):
            statusDetail = label
            if await confirmLMS(host: host, port: web) {
                await install(host: host, web: web, slim: slim, label: label, token: token)
            } else if token == generation {
                phase = .failed
                statusDetail = "No Lyrion at \(label)"
            }
        case .probe(let hosts, let web, let slim):
            guard !hosts.isEmpty else {
                phase = .failed
                statusDetail = "No other machine on the tailnet"
                return
            }
            for host in hosts {
                guard token == generation else { return }
                statusDetail = host
                if await confirmLMS(host: host, port: web) {
                    await install(host: host, web: web, slim: slim, label: host, token: token)
                    return
                }
            }
            if token == generation {
                phase = .failed
                statusDetail = "No Lyrion on the tailnet"
            }
        }
    }

    fileprivate func confirmLMS(host: String, port: Int) async -> Bool {
        let fd = await dialer.dial(host: host, port: port)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let reply = TailscaleLocalBridge.exchange(
            fd: fd,
            request: TailscaleRemotePlan.lmsProbeRequest(host: host, port: port),
            timeoutSeconds: 4
        )
        let matched = TailscaleRemotePlan.looksLikeLMS(reply)
        os_log(.info, log: logger, "Probe %{public}s:%d → %{public}s", host, port, matched ? "LMS" : "no")
        return matched
    }

    fileprivate func install(host: String, web: Int, slim: Int, label: String, token: Int) async {
        guard token == generation else { return }
        let webBridge = TailscaleLocalBridge()
        let slimBridge = TailscaleLocalBridge()
        let dialer = self.dialer
        do {
            let webLocal = try webBridge.start { await dialer.dial(host: host, port: web) }
            let slimLocal = try slimBridge.start { await dialer.dial(host: host, port: slim) }
            guard token == generation else {
                webBridge.stop()
                slimBridge.stop()
                return
            }
            self.webBridge = webBridge
            self.slimBridge = slimBridge
            let route = SettingsManager.SessionServerRoute(
                host: "127.0.0.1",
                webPort: Int(webLocal),
                slimPort: Int(slimLocal),
                remoteName: label
            )
            let settings = SettingsManager.shared
            settings.setSessionRoute(route)
            if settings.tailscaleRememberedHost.isEmpty {
                settings.tailscaleRememberedHost = host
                settings.saveSettings()
            }
            phase = .connected
            statusDetail = label
            os_log(.info, log: logger, "Bridged %{public}s to 127.0.0.1 web %d slim %d", label, webLocal, slimLocal)
            onRouteReady?()
            Task { await self.preferLAN(token: token) }
        } catch {
            webBridge.stop()
            slimBridge.stop()
            guard token == generation else { return }
            phase = .failed
            statusDetail = "Could not open the local bridge"
        }
    }

    fileprivate func preferLAN(token: Int) async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard token == generation else { return }
        let settings = SettingsManager.shared
        guard settings.sessionRoute != nil, !pathIsExpensive else { return }
        let host = settings.serverHost
        guard !host.isEmpty,
              !TailscaleRemotePlan.isMagicDNS(host),
              !TailscaleRemotePlan.isTailscaleCGNAT(host) else { return }
        let port = UInt16(settings.serverWebPort)
        let open = await Task.detached { () -> Bool in
            TailscaleLocalBridge.tcpReachable(host: host, port: port, timeout: 1.5)
        }.value
        guard open, token == generation else { return }
        os_log(.info, log: logger, "Saved server answers on the LAN — leaving the tailnet bridge")
        dropBridge()
        settings.clearSessionRoute()
        phase = .idle
        statusDetail = ""
        directFailures = 0
        onRouteReady?()
    }

    fileprivate func stateDirectory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    fileprivate func nodeHostname() -> String {
        let raw = SettingsManager.shared.effectivePlayerName.lowercased()
        let cleaned = raw.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        var suffix = String(cleaned)
        while suffix.contains("--") {
            suffix = suffix.replacingOccurrences(of: "--", with: "-")
        }
        suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if suffix.isEmpty { return "lyrplay" }
        return "lyrplay-" + String(suffix.prefix(24))
    }
}

private final class EmbeddedTailscaleDialer {
    private var node: TailscaleNode?

    func start(hostname: String, directory: String) async throws {
        await close()
        let config = Configuration(
            hostName: hostname,
            path: directory,
            authKey: nil,
            controlURL: kDefaultControlURL,
            ephemeral: false
        )
        let started = try TailscaleNode(config: config, logger: nil)
        node = started
        Task { try? await started.up() }
    }

    func status() async throws -> Data {
        guard let node else { throw TailscaleConnector.DialError.notStarted }
        return try await node.statusJSON()
    }

    func dial(host: String, port: Int) async -> Int32 {
        guard let node else { return -1 }
        guard let handle = await node.tailscale else { return -1 }
        let address = "\(host):\(port)"
        return await Task.detached { () -> Int32 in
            var connection: Int32 = 0
            let result = tailscale_dial(handle, "tcp", address, &connection)
            return result == 0 ? connection : -1
        }.value
    }

    func close() async {
        if let node {
            try? await node.close()
        }
        node = nil
    }
}

extension TailscaleConnector {
    enum DialError: Error {
        case notStarted
    }
}
#endif
