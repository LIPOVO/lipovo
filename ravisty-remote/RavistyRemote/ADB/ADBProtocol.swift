import Foundation

enum ADBError: LocalizedError {
    case invalidAddress, notConnected, busy, timeout, disconnected, protocolViolation(String)
    case authentication(String), rejectedService, outputTooLarge, missingPNG, key(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Введите IPv4-адрес телевизора и порт от 1 до 65535."
        case .notConnected: return "Сначала подключитесь к телевизору."
        case .busy: return "Предыдущая команда ещё выполняется."
        case .timeout: return "Телевизор не ответил вовремя. Проверьте сеть и разрешение отладки на его экране."
        case .disconnected: return "Соединение с телевизором закрыто."
        case .protocolViolation(let detail): return "Ошибка протокола ADB: \(detail)"
        case .authentication(let detail): return "Не удалось разрешить доступ ADB: \(detail)"
        case .rejectedService: return "Телевизор отклонил команду ADB."
        case .outputTooLarge: return "Ответ телевизора превысил допустимый размер."
        case .missingPNG: return "Телевизор не вернул корректный PNG-снимок."
        case .key(let detail): return "Ошибка ключа доступа: \(detail)"
        }
    }
}

enum ADBCommand {
    static let connect: UInt32 = 0x4e584e43
    static let auth: UInt32 = 0x48545541
    static let open: UInt32 = 0x4e45504f
    static let okay: UInt32 = 0x59414b4f
    static let close: UInt32 = 0x45534c43
    static let write: UInt32 = 0x45545257
    static let valid: Set<UInt32> = [connect, auth, open, okay, close, write]
}

struct ADBPacket {
    static let headerSize = 24
    static let maxPayload = 1024 * 1024
    let command: UInt32
    let arg0: UInt32
    let arg1: UInt32
    let payload: Data

    init(command: UInt32, arg0: UInt32 = 0, arg1: UInt32 = 0, payload: Data = Data()) {
        self.command = command; self.arg0 = arg0; self.arg1 = arg1; self.payload = payload
    }

    func encoded() -> Data {
        var result = Data()
        [command, arg0, arg1, UInt32(payload.count), Self.checksum(payload), command ^ 0xffffffff]
            .forEach { result.appendLE($0) }
        result.append(payload)
        return result
    }

    static func payloadLength(header: Data) throws -> Int {
        guard header.count == headerSize else { throw ADBError.protocolViolation("длина заголовка") }
        let command = header.uint32LE(at: 0)
        guard ADBCommand.valid.contains(command), header.uint32LE(at: 20) == command ^ 0xffffffff else {
            throw ADBError.protocolViolation("команда или magic")
        }
        let length = Int(header.uint32LE(at: 12))
        guard length <= maxPayload else { throw ADBError.outputTooLarge }
        return length
    }

    static func decode(header: Data, payload: Data) throws -> ADBPacket {
        let count = try payloadLength(header: header)
        guard payload.count == count, header.uint32LE(at: 16) == checksum(payload) else {
            throw ADBError.protocolViolation("длина или контрольная сумма данных")
        }
        return ADBPacket(command: header.uint32LE(at: 0), arg0: header.uint32LE(at: 4),
                         arg1: header.uint32LE(at: 8), payload: payload)
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    func uint32LE(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, byte in
            value | UInt32(self[index(startIndex, offsetBy: offset + byte)]) << (byte * 8)
        }
    }
}

enum PNGResponse {
    /// Some MediaTek screencap binaries emit diagnostic text before the PNG.
    /// Drop only that prefix, never alter bytes within the PNG stream.
    static func clean(_ data: Data) throws -> Data {
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard let range = data.range(of: signature),
              data.distance(from: data.startIndex, to: range.lowerBound) <= 65536 else {
            throw ADBError.missingPNG
        }
        let png = Data(data[range.lowerBound...])
        guard png.count >= 33, Array(png[12..<16]) == Array("IHDR".utf8) else {
            throw ADBError.missingPNG
        }
        return png
    }
}

/// Small, expiring FIFO. A slow link must never replay seconds of old remote taps.
struct RemoteKeyBuffer {
    struct Key {
        let code: Int
        let label: String
        let submittedAt: TimeInterval
    }
    let capacity: Int
    let lifetime: TimeInterval
    private var keys: [Key] = []

    init(capacity: Int = 3, lifetime: TimeInterval = 0.350) {
        self.capacity = max(1, capacity)
        self.lifetime = max(0, lifetime)
    }

    mutating func append(code: Int, label: String, now: TimeInterval) {
        keys.removeAll { now - $0.submittedAt > lifetime }
        if keys.count >= capacity { keys.removeFirst(keys.count - capacity + 1) }
        keys.append(Key(code: code, label: label, submittedAt: now))
    }

    mutating func next(now: TimeInterval) -> Key? {
        keys.removeAll { now - $0.submittedAt > lifetime }
        return keys.isEmpty ? nil : keys.removeFirst()
    }

    mutating func removeAll() { keys.removeAll(keepingCapacity: true) }
}
