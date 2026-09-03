import CryptoKit
import Foundation
import HerdrKit
import HerdrSSH

/// How the phone reaches a device's herdr session. Today: direct SSH with a
/// `direct-streamlocal` channel per RPC (herdr is one-request-per-connection).
/// A relay transport slots in behind the same face later.
protocol MobileTransport: Sendable {
    func request(method: String, params: JSONValue) async throws -> JSONValue
    func events(kinds: [String]) -> AsyncThrowingStream<HerdrEvent, Error>
    func openTerminal(command: String, columns: Int, rows: Int) async throws -> SSHPTYChannel
    /// Whether this transport can still carry an RPC. iOS suspension can leave
    /// libssh2 believing it is connected while the socket underneath is dead,
    /// so this must prove liveness on the wire rather than read a flag.
    func isHealthy() async -> Bool
    func close() async
}

/// Resolves the *current* transport for a device at the moment of use.
///
/// An attach outlives the `SSHConnection` it started on — a background pass
/// kills the session and the reconnect builds a new one — so anything holding a
/// transport across suspension must re-resolve through this instead of keeping
/// the reference it was handed at construction.
@MainActor
protocol MobileTransportProvider: AnyObject {
    /// Bumped every time the held transport is replaced or dropped. Channels
    /// opened on an earlier revision are dead with the transport they came from.
    var transportRevision: Int { get }

    /// The transport to use now, reconnecting first when the held one is gone
    /// or cannot prove itself.
    func currentTransport() async throws -> MobileTransport
}

extension MobileTransport {
    func request<T: Decodable>(
        method: String,
        params: JSONValue = .object([:]),
        as type: T.Type
    ) async throws -> T {
        let result = try await request(method: method, params: params)
        let data = try JSONEncoder().encode(result)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HerdrError.malformedResponse("\(method): \(error)")
        }
    }
}

enum MobileTransportError: LocalizedError {
    case hostKeyChanged(fingerprint: String)
    case missingPassword
    case homeProbeFailed
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let reason):
            return reason
        case .hostKeyChanged(let fingerprint):
            return String(
                localized: "This device's SSH host key changed (\(fingerprint)). If the host was reinstalled, remove and re-add the device."
            )
        case .missingPassword:
            return String(localized: "No password saved for this device.")
        case .homeProbeFailed:
            return String(localized: "Could not resolve the home directory on the device.")
        }
    }
}

/// Owns one authenticated SSH connection to a device. RPCs each open a fresh
/// streamlocal channel (herdr closes the socket after one reply); the event
/// subscription holds a long-lived channel and streams NDJSON lines.
final class SSHDirectTransport: MobileTransport {
    private let connection: SSHConnection
    private let socketPath: String

    private static let requestTimeout: Duration = .seconds(15)
    /// A liveness probe must not inherit the request budget: it runs while the
    /// user is staring at a stalled screen, and a dead socket has to be called
    /// dead quickly so the rebuild can start.
    private static let probeTimeout: Duration = .seconds(4)

    private init(connection: SSHConnection, socketPath: String) {
        self.connection = connection
        self.socketPath = socketPath
    }

    /// Connects, verifies the pinned host key (TOFU on first contact),
    /// authenticates (device key or Keychain password), and resolves the
    /// remote herdr socket path against the remote $HOME.
    static func connect(device: MobileDevice) async throws -> SSHDirectTransport {
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: device.host, port: device.port),
            timeout: .seconds(10)
        )
        do {
            let hostKey = connection.hostKey
            let fingerprint = Self.fingerprint(hostKey.key)
            if let pinned = KnownHostsStore.fingerprint(
                host: device.host, port: device.port, algorithm: hostKey.algorithm
            ) {
                guard pinned == fingerprint else {
                    throw MobileTransportError.hostKeyChanged(fingerprint: fingerprint)
                }
            } else {
                KnownHostsStore.pin(
                    host: device.host, port: device.port,
                    algorithm: hostKey.algorithm, fingerprint: fingerprint
                )
            }

            switch device.authMethod {
            case .deviceKey:
                // The private key stays in CryptoKit; libssh2 only ever sees
                // the signature produced by this closure.
                let key = DeviceKey.ensure()
                try await connection.authenticate(
                    username: device.username,
                    publicKey: DeviceKey.publicKeyBlob(key),
                    signer: { challenge in try key.signature(for: challenge) },
                    timeout: .seconds(15)
                )
            case .password:
                guard let password = MobileSecretStore.password(for: device.id) else {
                    throw MobileTransportError.missingPassword
                }
                try await connection.authenticate(
                    username: device.username,
                    password: password,
                    timeout: .seconds(15)
                )
            }

            let socketPath: String
            if let override = device.socketPath, !override.isEmpty {
                socketPath = override
            } else {
                // sshd exec is not a login shell, but $HOME is always set.
                let result = try await connection.execute(
                    "printf '%s' \"$HOME\"", timeout: .seconds(10)
                )
                guard let home = String(data: result.stdout, encoding: .utf8),
                      home.hasPrefix("/")
                else { throw MobileTransportError.homeProbeFailed }
                socketPath = home + "/.config/herdr/herdr.sock"
            }
            return SSHDirectTransport(connection: connection, socketPath: socketPath)
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    static func fingerprint(_ key: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString()
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        try await request(method: method, params: params, timeout: Self.requestTimeout)
    }

    private func request(
        method: String,
        params: JSONValue,
        timeout: Duration
    ) async throws -> JSONValue {
        let payload = SocketRPC.encodeRequest(
            id: UUID().uuidString, method: method, params: params
        )
        let reply: Data
        do {
            reply = try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: payload,
                timeout: timeout
            )
        } catch SSHError.streamLocalOpenFailed {
            throw HerdrError.remoteHerdrDown(target: "device", socketPath: socketPath)
        }
        // exchangeStreamLocal returns up to the first newline-terminated chunk;
        // trim a trailing newline before decoding.
        var line = reply
        if line.last == 0x0A { line.removeLast() }
        return try SocketRPC.decodeResponse(line)
    }

    /// `isConnected` only reports what libssh2 believes, which after an iOS
    /// suspension can be wrong in the one direction that matters, so the flag
    /// is a cheap pre-filter and the real answer is a round trip: a fresh
    /// streamlocal channel plus a `ping` on a short budget.
    func isHealthy() async -> Bool {
        guard await connection.isConnected else { return false }
        do {
            _ = try await request(
                method: "ping", params: .object([:]), timeout: Self.probeTimeout
            )
            return true
        } catch {
            return false
        }
    }

    func events(kinds: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
        let connection = connection
        let socketPath = socketPath
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let channel = try await connection.openStreamLocal(
                        socketPath: socketPath, timeout: .seconds(10)
                    )
                    defer { Task { try? await channel.close(timeout: .seconds(2)) } }
                    let subscribe = JSONValue.object([
                        "subscriptions": .array(kinds.map { .object(["type": .string($0)]) })
                    ])
                    try await channel.write(
                        SocketRPC.encodeRequest(id: "events", method: "events.subscribe", params: subscribe),
                        timeout: .seconds(10)
                    )
                    var buffer = Data()
                    var sawAck = false
                    while !Task.isCancelled {
                        // Long timeout: herdr only writes when something happens.
                        guard let chunk = try await channel.read(timeout: .seconds(3600)) else { break }
                        buffer.append(chunk)
                        while let index = buffer.firstIndex(of: 0x0A) {
                            let line = buffer.prefix(upTo: index)
                            buffer.removeSubrange(...index)
                            guard !line.isEmpty else { continue }
                            guard sawAck else {
                                sawAck = true  // first line is the subscribe ack
                                continue
                            }
                            if let value = try? JSONDecoder().decode(JSONValue.self, from: line) {
                                let kind = value["event"]?["type"]?.stringValue
                                    ?? value["type"]?.stringValue
                                    ?? value["kind"]?.stringValue
                                    ?? "unknown"
                                continuation.yield(HerdrEvent(kind: kind, payload: value))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A PTY session channel running `command` directly (no login shell).
    /// sshd's exec PATH is bare, so callers prepend the well-known prefixes.
    func openTerminal(command: String, columns: Int, rows: Int) async throws -> SSHPTYChannel {
        try await connection.openPTY(
            command: command,
            columns: columns,
            rows: rows,
            timeout: .seconds(15)
        )
    }

    func close() async {
        try? await connection.close(timeout: .seconds(3))
    }
}

enum MobileAttach {
    /// Non-login sshd exec leaves PATH at /usr/bin:/bin; herdr usually lives in
    /// a user prefix. Mirrors the Mac app's remote attach PATH handling.
    static let pathExport = #"export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/bin""#

    /// APC marker printed just before exec. sshd runs the command through the
    /// user's shell, whose rc chatter would otherwise leak into the terminal;
    /// the attach session drops everything before this marker (Heeler's
    /// AttachBootstrapHandshake trick).
    static let bootstrapMarker = Data([0x1B, 0x5F]) + Data("herdrm-attach".utf8) + Data([0x1B, 0x5C])
    private static let markerPrintf = #"printf '\033_herdrm-attach\033\\'"#

    /// The remote command for attaching to an agent pane or a bare terminal.
    static func command(target: TerminalAttachTarget) -> String {
        let attach: String
        switch target {
        case .agent(let paneID):
            attach = "herdr agent attach \(ShellQuoting.quoted(paneID)) --takeover"
        case .terminal(let terminalID):
            attach = "herdr terminal attach \(ShellQuoting.quoted(terminalID)) --takeover"
        }
        let script = "\(pathExport); \(markerPrintf); exec \(attach)"
        return "/bin/sh -c \(ShellQuoting.quoted(script))"
    }
}
