import XCTest
import Network
@testable import RavistyRemote

final class ADBProtocolTests: XCTestCase {
    func testPacketRoundTripAndChecksum() throws {
        let packet = ADBPacket(command: ADBCommand.open, arg0: 7, payload: Data("shell:input keyevent 3\0".utf8))
        let bytes = packet.encoded()
        let header = Data(bytes.prefix(24))
        let body = Data(bytes.dropFirst(24))
        let decoded = try ADBPacket.decode(header: header, payload: body)
        XCTAssertEqual(decoded.command, ADBCommand.open)
        XCTAssertEqual(decoded.arg0, 7)
        XCTAssertEqual(decoded.arg1, 0)
        XCTAssertEqual(decoded.payload, packet.payload)
        XCTAssertEqual(header.uint32LE(at: 16), body.reduce(UInt32(0)) { $0 &+ UInt32($1) })
    }

    func testRejectsBadMagicAndPayload() throws {
        var bytes = ADBPacket(command: ADBCommand.write, arg0: 1, arg1: 2, payload: Data([1, 2, 3])).encoded()
        bytes[20] ^= 0xff
        XCTAssertThrowsError(try ADBPacket.payloadLength(header: Data(bytes.prefix(24))))
        let good = ADBPacket(command: ADBCommand.write, payload: Data([1, 2, 3])).encoded()
        XCTAssertThrowsError(try ADBPacket.decode(header: Data(good.prefix(24)), payload: Data([1, 2, 4])))
        XCTAssertThrowsError(try ADBPacket.payloadLength(header: Data([0, 1])))
    }

    func testRejectsOversizePayload() {
        var header = Data()
        [ADBCommand.write, 1, 2, UInt32(ADBPacket.maxPayload + 1), 0, ADBCommand.write ^ 0xffffffff]
            .forEach { header.appendLE($0) }
        XCTAssertThrowsError(try ADBPacket.payloadLength(header: header))
    }

    func testAndroidPublicKeyMontgomeryFields() throws {
        // N = 2^2048 - 159 => R mod N = 159; R² mod N = 25281.
        let modulus = [UInt8(0)] + [UInt8](repeating: 255, count: 255) + [UInt8(97)]
        let body = [UInt8(2), 0x82, 0x01, 0x01] + modulus + [2, 3, 1, 0, 1]
        let der = Data([0x30, 0x82, 0x01, 0x0a] + body)
        let encoded = try AndroidRSAPublicKey.encode(pkcs1: der)
        XCTAssertEqual(encoded.count, 524)
        XCTAssertEqual(encoded.uint32LE(at: 0), 64)
        XCTAssertEqual(encoded.uint32LE(at: 8), 0xffffff61)
        XCTAssertEqual(encoded.uint32LE(at: 4) &* encoded.uint32LE(at: 8), UInt32.max)
        XCTAssertEqual(encoded.uint32LE(at: 264), 25281)
        XCTAssertEqual(Array(encoded[268..<520]), [UInt8](repeating: 0, count: 252))
        XCTAssertEqual(encoded.uint32LE(at: 520), 65537)
    }

    func testPNGPrefixRemovalDoesNotRewritePNGBytes() throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
                       + [UInt8](repeating: 0, count: 20))
        let raw = Data("Init wrapper\nopen mma dev failed\n".utf8) + png
        XCTAssertEqual(try PNGResponse.clean(raw), png)
        XCTAssertThrowsError(try PNGResponse.clean(Data("Not a PNG".utf8)))
    }

    func testPublicKeyWithDenseModulusCarries() throws {
        var modulus = (0..<256).map { UInt8(($0 * 73 + 41) & 255) }
        modulus[0] |= 0x80
        modulus[255] |= 1
        let integer = [UInt8(0)] + modulus
        let body = [UInt8(2), 0x82, 0x01, 0x01] + integer + [2, 3, 1, 0, 1]
        let key = try AndroidRSAPublicKey.encode(pkcs1: Data([0x30, 0x82, 0x01, 0x0a] + body))
        XCTAssertEqual(key.uint32LE(at: 4), 0xa3c413df)
        XCTAssertEqual(key.uint32LE(at: 264), 0x91d3a837)
        XCTAssertEqual(key.uint32LE(at: 268), 0xb11f5508)
        XCTAssertEqual(key.uint32LE(at: 264 + 31 * 4), 0xe5380bcb)
        XCTAssertEqual(key.uint32LE(at: 264 + 63 * 4), 0x990257c7)
    }

    func testRemoteQueueKeepsOnlyThreeRecentKeys() {
        var queue = RemoteKeyBuffer(capacity: 3, lifetime: 0.350)
        for code in 1...5 { queue.append(code: code, label: "key", now: 10) }
        XCTAssertEqual(queue.next(now: 10.1)?.code, 3)
        XCTAssertEqual(queue.next(now: 10.1)?.code, 4)
        XCTAssertEqual(queue.next(now: 10.1)?.code, 5)
        XCTAssertNil(queue.next(now: 10.1))
    }

    func testRemoteQueueDropsExpiredTapsBeforeExecution() {
        var queue = RemoteKeyBuffer(capacity: 3, lifetime: 0.350)
        queue.append(code: 19, label: "old", now: 20)
        queue.append(code: 20, label: "new", now: 20.3)
        XCTAssertEqual(queue.next(now: 20.4)?.code, 20)
        XCTAssertNil(queue.next(now: 20.7))
    }

    func testRemoteQueueCanBeClearedOnDisconnect() {
        var queue = RemoteKeyBuffer()
        queue.append(code: 23, label: "OK", now: 1)
        queue.removeAll()
        XCTAssertNil(queue.next(now: 1.1))
    }

    func testFastInputAcceptsTransportAckBeforeHelperReply() async throws {
        try await checkFastInput(replyBeforeAck: false)
    }

    func testFastInputAcceptsHelperReplyBeforeTransportAck() async throws {
        try await checkFastInput(replyBeforeAck: true)
    }

    func testFastInputDoesNotReplayKeyAfterClosedStream() async throws {
        let peer = try LoopbackADBPeer()
        let port = try await peer.start()
        let server = Task { try await peer.serve(replyBeforeAck: false, closeFirstKey: true) }
        let client = ADBClient()
        defer { peer.stop() }
        do {
            _ = try await client.connect(host: "127.0.0.1", port: port) { _ in }
            try await client.startInputSession()
            do {
                try await client.keyEvent(19)
                XCTFail("Closed helper stream must fail the key operation")
            } catch { /* Expected. The failed key must not be retried. */ }
            let commands = try await server.value
            XCTAssertEqual(commands, ["key 1 19\n"])
            await client.disconnect()
        } catch {
            await client.disconnect()
            peer.stop()
            _ = try? await server.value
            throw error
        }
    }

    private func checkFastInput(replyBeforeAck: Bool) async throws {
        let peer = try LoopbackADBPeer()
        let port = try await peer.start()
        let server = Task { try await peer.serve(replyBeforeAck: replyBeforeAck) }
        let client = ADBClient()
        defer { peer.stop() }
        do {
            _ = try await client.connect(host: "127.0.0.1", port: port) { _ in }
            try await client.startInputSession()
            try await client.keyEvent(19)
            try await client.keyEvent(23)
            let commands = try await server.value
            XCTAssertEqual(commands, ["key 1 19\n", "key 2 23\n"])
            await client.disconnect()
        } catch {
            await client.disconnect()
            peer.stop()
            _ = try? await server.value
            throw error
        }
    }
}

/// Deterministic local peer exercises the actual client, including partial TCP reads.
private final class LoopbackADBPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ravisty.tests.adb-peer")
    private let accepted: AsyncStream<NWConnection>
    private let acceptContinuation: AsyncStream<NWConnection>.Continuation
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []

    init() throws {
        var continuation: AsyncStream<NWConnection>.Continuation!
        accepted = AsyncStream { continuation = $0 }
        acceptContinuation = continuation
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); readyContinuation = continuation; lock.unlock()
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                self.acceptContinuation.yield(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port { self.finishReady(.success(port.rawValue)) }
                    else { self.finishReady(.failure(ADBError.invalidAddress)) }
                case .failed(let error): self.finishReady(.failure(error))
                case .cancelled: self.finishReady(.failure(ADBError.disconnected))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishReady(.failure(ADBError.timeout)) }
            listener.start(queue: queue)
        }
    }

    private func finishReady(_ result: Result<UInt16, Error>) {
        lock.lock(); let saved = readyContinuation; readyContinuation = nil; lock.unlock()
        saved?.resume(with: result)
    }

    func stop() {
        listener.cancel()
        acceptContinuation.finish()
        lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }

    func serve(replyBeforeAck: Bool, closeFirstKey: Bool = false) async throws -> [String] {
        var iterator = accepted.makeAsyncIterator()
        guard let connection = await iterator.next() else { throw ADBError.disconnected }
        let tcp = ADBTCPStream(acceptedConnection: connection)
        try await tcp.connect(timeout: 5)
        let connect = try await read(tcp)
        XCTAssertEqual(connect.command, ADBCommand.connect)
        try await sendFragmented(tcp, ADBPacket(command: ADBCommand.connect, arg0: 0x01000000,
                                              arg1: 4096, payload: Data("device::loopback\0".utf8)))
        let open = try await read(tcp)
        XCTAssertEqual(open.command, ADBCommand.open)
        XCTAssertTrue(String(decoding: open.payload, as: UTF8.self).contains("ravisty-input.jar"))
        let remote: UInt32 = 71
        try await tcp.send(ADBPacket(command: ADBCommand.okay, arg0: remote, arg1: open.arg0).encoded())
        // READY spans two ADB packets, with vendor text before it.
        for text in ["vendor diagnostic\nREA", "DY 1\n"] {
            try await sendFragmented(tcp, ADBPacket(command: ADBCommand.write, arg0: remote,
                                                  arg1: open.arg0, payload: Data(text.utf8)))
            let ack = try await read(tcp)
            XCTAssertEqual(ack.command, ADBCommand.okay)
        }
        var commands: [String] = []
        for sequence in 1...(closeFirstKey ? 1 : 2) {
            let command = try await read(tcp)
            XCTAssertEqual(command.command, ADBCommand.write)
            commands.append(String(decoding: command.payload, as: UTF8.self))
            if closeFirstKey {
                try await tcp.send(ADBPacket(command: ADBCommand.close, arg0: remote, arg1: open.arg0).encoded())
                return commands
            }
            let transportAck = ADBPacket(command: ADBCommand.okay, arg0: remote, arg1: open.arg0)
            let reply = ADBPacket(command: ADBCommand.write, arg0: remote, arg1: open.arg0,
                                  payload: Data("OK \(sequence)\n".utf8))
            if !replyBeforeAck { try await tcp.send(transportAck.encoded()) }
            try await sendFragmented(tcp, reply)
            let replyAck = try await read(tcp)
            XCTAssertEqual(replyAck.command, ADBCommand.okay)
            if replyBeforeAck { try await tcp.send(transportAck.encoded()) }
        }
        return commands
    }

    private func read(_ tcp: ADBTCPStream) async throws -> ADBPacket {
        let header = try await tcp.readExactly(24, timeout: 5)
        let body = try await tcp.readExactly(ADBPacket.payloadLength(header: header), timeout: 5)
        return try ADBPacket.decode(header: header, payload: body)
    }

    private func sendFragmented(_ tcp: ADBTCPStream, _ packet: ADBPacket) async throws {
        let bytes = packet.encoded()
        try await tcp.send(Data(bytes.prefix(7)))
        try await tcp.send(Data(bytes.dropFirst(7).prefix(13)))
        try await tcp.send(Data(bytes.dropFirst(20)))
    }
}
