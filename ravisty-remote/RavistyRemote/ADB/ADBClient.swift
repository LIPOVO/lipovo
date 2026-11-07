import Foundation

actor ADBClient {
    private var stream: ADBTCPStream?
    private let identity = ADBIdentity()
    private var connected = false
    private var busy = false
    private var nextLocalID: UInt32 = 1

    func connect(host: String, port: UInt16, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        guard !busy else { throw ADBError.busy }
        busy = true
        defer { busy = false }
        stream?.cancel()
        connected = false
        let tcp = try ADBTCPStream(host: host, port: port)
        stream = tcp
        do {
            progress("Подключение к телевизору…")
            try await tcp.connect()
            // Version 1.0 keeps payload checksums enabled on both endpoints.
            try await tcp.send(ADBPacket(command: ADBCommand.connect, arg0: 0x01000000, arg1: 4096,
                                        payload: Data("host::ravisty-remote\0".utf8)).encoded())
            var authAttempt = 0
            let deadline = Date().addingTimeInterval(100)
            while deadline.timeIntervalSinceNow > 0 {
                let packet = try await readPacket(tcp, timeout: deadline.timeIntervalSinceNow)
                switch packet.command {
                case ADBCommand.connect:
                    guard packet.arg0 >= 0x01000000, packet.arg1 >= 4096 else {
                        throw ADBError.protocolViolation("несовместимая версия ADB")
                    }
                    connected = true
                    nextLocalID = 1
                    return String(decoding: packet.payload, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
                case ADBCommand.auth:
                    guard packet.arg0 == 1, authAttempt < 4 else {
                        throw ADBError.authentication("неожиданный ответ телевизора")
                    }
                    if authAttempt == 1 {
                        progress("Разрешите отладку для этого iPhone на экране телевизора.")
                        try await tcp.send(ADBPacket(command: ADBCommand.auth, arg0: 3,
                                                    payload: identity.publicKeyPayload()).encoded())
                    } else {
                        try await tcp.send(ADBPacket(command: ADBCommand.auth, arg0: 2,
                                                    payload: identity.sign(token: packet.payload)).encoded())
                    }
                    authAttempt += 1
                default: throw ADBError.protocolViolation("пакет до авторизации")
                }
            }
            throw ADBError.timeout
        } catch {
            tcp.cancel()
            stream = nil
            connected = false
            throw error
        }
    }

    func disconnect() {
        stream?.cancel()
        stream = nil
        connected = false
    }

    func shell(_ command: String) async throws -> String {
        let data = try await execute(service: "shell:" + command, limit: 512 * 1024, timeout: 20)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func screenshot() async throws -> Data {
        // exec bypasses PTY newline conversion, preserving PNG bytes.
        let bytes = try await execute(service: "exec:screencap -p", limit: 8 * 1024 * 1024, timeout: 30)
        return try PNGResponse.clean(bytes)
    }

    private func execute(service: String, limit: Int, timeout: TimeInterval) async throws -> Data {
        guard connected, let tcp = stream else { throw ADBError.notConnected }
        guard !busy else { throw ADBError.busy }
        busy = true
        defer { busy = false }
        let local = nextLocalID
        nextLocalID = nextLocalID == UInt32.max ? 1 : nextLocalID + 1
        let deadline = Date().addingTimeInterval(timeout)
        do {
            try await tcp.send(ADBPacket(command: ADBCommand.open, arg0: local,
                                        payload: Data((service + "\0").utf8)).encoded())
            var remote: UInt32 = 0
            var output = Data()
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw ADBError.timeout }
                let packet = try await readPacket(tcp, timeout: remaining)
                // Late packets belonging to a closed previous stream can be ignored.
                guard packet.arg1 == local else {
                    if [ADBCommand.close, ADBCommand.okay, ADBCommand.write].contains(packet.command) { continue }
                    throw ADBError.protocolViolation("пакет вне открытого потока")
                }
                switch packet.command {
                case ADBCommand.okay:
                    guard packet.arg0 != 0, remote == 0 || remote == packet.arg0 else {
                        throw ADBError.protocolViolation("идентификатор потока")
                    }
                    remote = packet.arg0
                case ADBCommand.write:
                    guard remote != 0, packet.arg0 == remote else { throw ADBError.protocolViolation("WRITE до OKAY") }
                    guard packet.payload.count <= limit - output.count else { throw ADBError.outputTooLarge }
                    output.append(packet.payload)
                    try await tcp.send(ADBPacket(command: ADBCommand.okay, arg0: local, arg1: remote).encoded())
                case ADBCommand.close:
                    guard remote != 0 else { throw ADBError.rejectedService }
                    guard packet.arg0 == remote else { throw ADBError.protocolViolation("CLOSE другого потока") }
                    return output
                default: throw ADBError.protocolViolation("неожиданная команда потока")
                }
            }
        } catch {
            tcp.cancel()
            stream = nil
            connected = false
            throw error
        }
    }

    private func readPacket(_ tcp: ADBTCPStream, timeout: TimeInterval) async throws -> ADBPacket {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        let header = try await tcp.readExactly(ADBPacket.headerSize, timeout: max(0.1, deadline.timeIntervalSinceNow))
        let size = try ADBPacket.payloadLength(header: header)
        let payload = try await tcp.readExactly(size, timeout: max(0.1, deadline.timeIntervalSinceNow))
        return try ADBPacket.decode(header: header, payload: payload)
    }
}
