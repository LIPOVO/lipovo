import Foundation
import Network

/// One reader and one writer, owned by ADBClient. NWConnection performs no TLS for legacy ADB.
final class ADBTCPStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tv.ravisty.remote.adb.tcp", qos: .userInitiated)

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw ADBError.invalidAddress }
        let tcp = NWProtocolTCP.Options()
        // Remote buttons and ADB acknowledgements are tiny latency-sensitive packets.
        // Do not wait for Nagle coalescing while the peer waits for an ACK.
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    /// Also permits an accepted loopback connection in the wire-protocol tests.
    init(acceptedConnection: NWConnection) { connection = acceptedConnection }

    func connect(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = CompletionGate(continuation)
            let timer = DispatchWorkItem { [connection] in
                if gate.resolve(.failure(ADBError.timeout)) {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                }
            }
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    if gate.resolve(.success(())) { timer.cancel(); connection.stateUpdateHandler = nil }
                case .failed(let error):
                    if gate.resolve(.failure(error)) { timer.cancel(); connection.stateUpdateHandler = nil }
                case .cancelled:
                    if gate.resolve(.failure(ADBError.disconnected)) { timer.cancel(); connection.stateUpdateHandler = nil }
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            connection.start(queue: queue)
        }
    }

    func cancel() { connection.cancel() }

    func send(_ data: Data, timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = CompletionGate(continuation)
            let timer = DispatchWorkItem { [connection] in
                if gate.resolve(.failure(ADBError.timeout)) { connection.cancel() }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            connection.send(content: data, completion: .contentProcessed { error in
                let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
                if gate.resolve(result) { timer.cancel() }
            })
        }
    }

    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        guard count >= 0, count <= ADBPacket.maxPayload else { throw ADBError.outputTooLarge }
        if count == 0 { return Data() }
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        while output.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { cancel(); throw ADBError.timeout }
            let bytes = try await receive(maximum: count - output.count, timeout: remaining)
            output.append(bytes)
        }
        return output
    }

    private func receive(maximum: Int, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = CompletionGate(continuation)
            let timer = DispatchWorkItem { [connection] in
                if gate.resolve(.failure(ADBError.timeout)) { connection.cancel() }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                let result: Result<Data, Error>
                if let error { result = .failure(error) }
                else if let data, !data.isEmpty { result = .success(data) }
                else if complete { result = .failure(ADBError.disconnected) }
                else { result = .failure(ADBError.protocolViolation("пустой TCP-ответ")) }
                if gate.resolve(result) { timer.cancel() }
            }
        }
    }
}

private final class CompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        guard let saved else { return false }
        saved.resume(with: result)
        return true
    }
}
