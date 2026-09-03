import Foundation
import HerdrKit
import SwiftUI

/// Connection state for one device, mirroring the Mac app's session states.
enum MobileConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

/// One device's live herdr view: transport + snapshot + event pump.
@MainActor
final class MobileDeviceSession {
    let device: MobileDevice
    var state: MobileConnectionState = .idle
    var snapshot: SessionSnapshot?
    private(set) var transport: MobileTransport?
    /// Bumped on every transport swap — see `MobileTransportProvider`.
    private(set) var transportRevision = 0
    private var eventTask: Task<Void, Never>?
    private var refreshPending = false
    /// The in-flight connect, so a foreground pass, a Reconnect tap and an
    /// attach all resolving at once share one rebuild instead of racing.
    private var connectTask: Task<Void, Never>?
    /// Set when iOS backgrounds us. A held session stops being trustworthy from
    /// that moment until something proves it again.
    private var wasSuspended = false

    var onChange: (() -> Void)?

    init(device: MobileDevice) {
        self.device = device
    }

    /// This session's state as the platform-neutral recovery policy sees it.
    var liveness: ConnectionLiveness {
        switch state {
        case .idle: return .absent
        case .connecting: return .establishing
        case .connected: return .established
        case .failed: return .failed
        }
    }

    /// Tears the held transport down and builds a fresh one. Never reuses a
    /// session: a half-open libssh2 session still reports itself connected, so
    /// "already connected" is not a safe reason to skip the rebuild.
    func connect() async {
        if let connectTask {
            await connectTask.value
            return
        }
        let task = Task { await self.performConnect() }
        connectTask = task
        await task.value
        connectTask = nil
    }

    private func performConnect() async {
        // The old session's channels — events, every attach PTY — die with it.
        await teardown()
        state = .connecting
        onChange?()
        do {
            let transport = try await SSHDirectTransport.connect(device: device)
            let pong = try await transport.request(
                method: "ping", params: .object([:]), as: PingResult.self
            )
            guard pong.protocolVersion >= 17 else {
                await transport.close()
                throw HerdrError.incompatibleProtocol(pong.protocolVersion)
            }
            setTransport(transport)
            wasSuspended = false
            state = .connected(version: pong.version)
            await refresh()
            startEventPump()
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        onChange?()
    }

    /// iOS is about to stop servicing our sockets and may drop the TCP
    /// connection outright while we are suspended.
    func noteSuspended() {
        wasSuspended = true
    }

    /// Foreground entry point: proves the held session and rebuilds it when the
    /// proof fails. Returns once the connection is either usable or failed.
    func resumeIfNeeded() async {
        switch ConnectionRecoveryPolicy.onForeground(
            liveness: liveness, wasSuspended: wasSuspended
        ) {
        case .wait:
            await connectTask?.value
        case .reuse:
            wasSuspended = false
        case .rebuild:
            await connect()
        case .probe:
            let healthy = await transport?.isHealthy() ?? false
            switch ConnectionRecoveryPolicy.afterProbe(succeeded: healthy) {
            case .rebuild:
                await connect()
            default:
                wasSuspended = false
            }
        }
    }

    func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        await teardown()
        state = .idle
        onChange?()
    }

    /// Drops every piece of state cached on the current transport. This is the
    /// teardown that popping and re-pushing the terminal screen used to do by
    /// accident; the reconnect path now does it deliberately.
    private func teardown() async {
        eventTask?.cancel()
        eventTask = nil
        guard let held = transport else { return }
        setTransport(nil)
        await held.close()
    }

    private func setTransport(_ new: MobileTransport?) {
        transport = new
        transportRevision += 1
    }

    func refresh() async {
        guard let transport else { return }
        struct Envelope: Codable { let snapshot: SessionSnapshot }
        do {
            snapshot = try await transport.request(
                method: "session.snapshot", as: Envelope.self
            ).snapshot
            onChange?()
        } catch {
            // A failed refresh keeps the last snapshot; the event pump's own
            // failure handling decides when the connection is actually gone.
        }
    }

    private func startEventPump() {
        guard let transport else { return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            do {
                for try await _ in transport.events(kinds: HerdrEvent.allKinds) {
                    await self?.scheduleRefresh()
                }
            } catch {}
            // Stream ended: the connection is likely gone. Reflect it so the
            // UI offers Reconnect instead of silently going stale.
            guard let self, !Task.isCancelled else { return }
            if case .connected = self.state {
                self.state = .failed(String(localized: "Connection lost"))
                self.onChange?()
            }
        }
    }

    /// Coalesces event bursts into one snapshot fetch per 300 ms.
    private func scheduleRefresh() async {
        guard !refreshPending else { return }
        refreshPending = true
        try? await Task.sleep(for: .milliseconds(300))
        refreshPending = false
        await refresh()
    }
}

extension MobileDeviceSession: MobileTransportProvider {
    /// Resolving always runs the foreground check first, so a caller that has
    /// been asleep never gets handed the session it remembers.
    func currentTransport() async throws -> MobileTransport {
        await resumeIfNeeded()
        if let transport { return transport }
        await connect()
        guard let transport else {
            let reason: String
            if case .failed(let message) = state {
                reason = message
            } else {
                reason = String(localized: "Not connected to this device.")
            }
            throw MobileTransportError.notConnected(reason)
        }
        return transport
    }
}

@MainActor
@Observable
final class MobileAppModel {
    var devices: [MobileDevice] = []
    var selectedDeviceID: UUID?
    var selectedSpaceID: String?
    var selectedAgentPaneID: String?
    var showAddDevice = false
    /// Bumped by sessions to publish nested (non-Observable) state changes.
    private(set) var revision = 0

    private let store = MobileDeviceStore()
    private var sessions: [UUID: MobileDeviceSession] = [:]

    init() {
        devices = store.load()
        selectedDeviceID = devices.first?.id
    }

    var selectedDevice: MobileDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    func session(for deviceID: UUID) -> MobileDeviceSession? {
        if let existing = sessions[deviceID] { return existing }
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        let session = MobileDeviceSession(device: device)
        session.onChange = { [weak self] in self?.revision += 1 }
        sessions[deviceID] = session
        return session
    }

    var selectedSession: MobileDeviceSession? {
        guard let selectedDeviceID else { return nil }
        return session(for: selectedDeviceID)
    }

    /// Observable connection state: sessions are plain classes, so views must
    /// read this (revision-tracked) rather than session.state directly.
    var selectedConnectionState: MobileConnectionState {
        _ = revision
        return selectedSession?.state ?? .idle
    }

    func connectSelected() {
        guard let session = selectedSession else { return }
        Task { await session.connect() }
    }

    /// Backgrounding: mark every session suspect. Nothing is torn down here —
    /// iOS gives no useful window for it, and the foreground probe is what
    /// decides whether a session survived.
    func noteSuspended() {
        for session in sessions.values {
            session.noteSuspended()
        }
    }

    /// Foregrounding: health-check the visible device and rebuild if the
    /// suspension killed it.
    func resumeSelected() {
        guard let session = selectedSession else { return }
        Task { await session.resumeIfNeeded() }
    }

    func selectDevice(_ id: UUID) {
        guard id != selectedDeviceID else { return }
        selectedDeviceID = id
        selectedSpaceID = nil
        selectedAgentPaneID = nil
        connectSelected()
    }

    // MARK: - Device management

    func addDevice(
        name: String,
        host: String,
        port: UInt16,
        username: String,
        authMethod: MobileDevice.AuthMethod,
        password: String
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = MobileDevice(
            name: trimmedName.isEmpty ? host : trimmedName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod
        )
        if authMethod == .password {
            MobileSecretStore.setPassword(password, for: device.id)
        }
        devices.append(device)
        store.save(devices)
        selectDevice(device.id)
    }

    /// The line to enroll on a Mac: `echo '<line>' >> ~/.ssh/authorized_keys`.
    var deviceKeyAuthorizedLine: String {
        DeviceKey.authorizedKeysLine(DeviceKey.ensure())
    }

    func removeDevice(_ device: MobileDevice) {
        if let session = sessions.removeValue(forKey: device.id) {
            Task { await session.disconnect() }
        }
        MobileSecretStore.removePassword(for: device.id)
        KnownHostsStore.unpin(host: device.host, port: device.port)
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        if selectedDeviceID == device.id {
            selectedDeviceID = devices.first?.id
            selectedSpaceID = nil
            selectedAgentPaneID = nil
            connectSelected()
        }
    }

    // MARK: - Derived lists (mirror the Mac sidebar)

    var spaces: [WorkspaceInfo] {
        _ = revision
        return selectedSession?.snapshot?.workspaces ?? []
    }

    /// Agents in the selected space (nil = all), waiting-on-you first —
    /// the same Blocked > Done > Working > Idle order as the Mac app and Heeler.
    var agents: [AgentInfo] {
        _ = revision
        guard let snapshot = selectedSession?.snapshot else { return [] }
        var list = snapshot.agents
        if let selectedSpaceID {
            list = list.filter { $0.workspaceID == selectedSpaceID }
        }
        return list.sorted {
            if $0.status.sortBucket != $1.status.sortBucket {
                return $0.status.sortBucket < $1.status.sortBucket
            }
            return $0.paneID < $1.paneID
        }
    }

    func tabLabel(for agent: AgentInfo) -> String? {
        _ = revision
        return selectedSession?.snapshot?.tabs?
            .first { $0.tabID == agent.tabID }?.customLabel
    }

    func spaceName(for workspaceID: String) -> String {
        _ = revision
        return selectedSession?.snapshot?.workspaces
            .first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    /// View identity for an attach screen. Pane IDs are only unique within a
    /// device, so switching devices must rebuild the screen — but a reconnect
    /// to the same device must not.
    func attachIdentity(paneID: String) -> String {
        "\(selectedDeviceID?.uuidString ?? "-")/\(paneID)"
    }

    var selectedAgent: AgentInfo? {
        _ = revision
        return selectedSession?.snapshot?.agents.first { $0.paneID == selectedAgentPaneID }
    }

    /// Bare herdr terminal panes in the selected space (nil = all).
    var terminalPanes: [PaneInfo] {
        _ = revision
        guard let snapshot = selectedSession?.snapshot else { return [] }
        var panes = snapshot.ordinaryTerminalPanes
        if let selectedSpaceID {
            panes = panes.filter { $0.workspaceID == selectedSpaceID }
        }
        return panes.sorted { $0.paneID < $1.paneID }
    }

    var selectedTerminalPane: PaneInfo? {
        _ = revision
        return terminalPanes.first { $0.paneID == selectedAgentPaneID }
    }

    func terminalLabel(for pane: PaneInfo) -> String {
        _ = revision
        if let tabID = pane.tabID,
           let label = selectedSession?.snapshot?.tabs?
               .first(where: { $0.tabID == tabID })?.customLabel {
            return label
        }
        if let title = pane.terminalTitle, !title.isEmpty { return title }
        return String(localized: "Terminal")
    }
}
