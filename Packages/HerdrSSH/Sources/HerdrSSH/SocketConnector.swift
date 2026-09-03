import Darwin
import Dispatch
import Foundation

enum SocketConnector {
    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        try await connect(
            to: endpoint,
            until: deadline,
            resolver: DNSServiceAddressResolver(),
            makeSocket: { socket($0, $1, $2) })
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw SSHError.invalidEndpoint
        }

        try checkProgress(until: deadline)
        let addresses = try await resolver.resolve(endpoint, until: deadline)
        var lastError: SSHError = .connectionFailed
        for address in addresses {
            do {
                try checkProgress(until: deadline)
                return try await connect(
                    to: address,
                    until: deadline,
                    makeSocket: makeSocket)
            } catch let error as SSHError {
                if error == .cancelled || error == .timedOut {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError
    }

    private static func connect(
        to address: SocketAddress,
        until deadline: ContinuousClock.Instant,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        let descriptor = makeSocket(address.family, address.type, address.protocol)
        guard descriptor >= 0 else { throw SSHError.connectionFailed }
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { Darwin.close(descriptor) }
        }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SSHError.connectionFailed
        }

        configureKeepalive(descriptor: descriptor, type: address.type)

        let result = address.bytes.withUnsafeBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.connect(
                descriptor,
                baseAddress.assumingMemoryBound(to: sockaddr.self),
                socklen_t(bytes.count))
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw SSHError.connectionFailed }
            try await SocketReadiness.wait(
                descriptor: descriptor,
                directions: .write,
                until: deadline)

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                socketError == 0
            else {
                throw SSHError.connectionFailed
            }
        }

        ownsDescriptor = false
        return descriptor
    }

    /// Without this a session that dies while the process is suspended — iOS
    /// stops servicing the socket, the peer or a NAT drops the flow — comes
    /// back half-open: reads simply never return, so a long-lived channel
    /// (an attach's PTY, the event stream) hangs instead of failing.
    ///
    /// libssh2's own `libssh2_keepalive_config` is deliberately not used: it
    /// only arms `libssh2_keepalive_send`, which nothing in this package is
    /// positioned to call on a schedule. TCP keepalive is driven by the kernel
    /// and needs no pump, and every option below is advisory — a socket that
    /// refuses one is still perfectly usable.
    private static func configureKeepalive(descriptor: Int32, type: Int32) {
        guard type == SOCK_STREAM else { return }
        setOption(descriptor, SOL_SOCKET, SO_KEEPALIVE, 1)
        // Idle before the first probe, then probe every 5s, five times: a dead
        // link is reported within about a minute of the app coming back.
        setOption(descriptor, IPPROTO_TCP, TCP_KEEPALIVE, 20)
        setOption(descriptor, IPPROTO_TCP, TCP_KEEPINTVL, 5)
        setOption(descriptor, IPPROTO_TCP, TCP_KEEPCNT, 5)
    }

    private static func setOption(
        _ descriptor: Int32,
        _ level: Int32,
        _ name: Int32,
        _ value: Int32
    ) {
        var value = value
        _ = setsockopt(
            descriptor,
            level,
            name,
            &value,
            socklen_t(MemoryLayout<Int32>.size))
    }

    private static func checkProgress(
        until deadline: ContinuousClock.Instant
    ) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if ContinuousClock.now >= deadline { throw SSHError.timedOut }
    }
}

struct SocketAddress: Sendable, Equatable {
    let family: Int32
    let type: Int32
    let `protocol`: Int32
    let bytes: Data
}
