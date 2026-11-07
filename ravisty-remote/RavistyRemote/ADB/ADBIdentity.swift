import Foundation
import Security

final class ADBIdentity: @unchecked Sendable {
    private let tag = Data("tv.ravisty.remote.adb.identity.v1".utf8)
    private var cachedKey: SecKey?

    private func privateKey() throws -> SecKey {
        if let cachedKey { return cachedKey }
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                   kSecAttrApplicationTag as String: tag,
                                   kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                   kSecReturnRef as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let result {
            let key = result as! SecKey
            cachedKey = key
            return key
        }
        guard status == errSecItemNotFound else { throw ADBError.key("Keychain \(status)") }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw ADBError.key("создание RSA")
        }
        cachedKey = key
        return key
    }

    func sign(token: Data) throws -> Data {
        guard token.count == 20 else { throw ADBError.authentication("ожидался 20-байтовый SHA-1 токен") }
        let key = try privateKey()
        let algorithm = SecKeyAlgorithm.rsaSignatureDigestPKCS1v15SHA1
        guard SecKeyIsAlgorithmSupported(key, .sign, algorithm) else { throw ADBError.key("RSA/SHA-1 не поддерживается") }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, token as CFData, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw ADBError.key("подпись токена")
        }
        return signature as Data
    }

    func publicKeyPayload() throws -> Data {
        guard let key = SecKeyCopyPublicKey(try privateKey()) else { throw ADBError.key("публичный ключ") }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(key, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw ADBError.key("экспорт публичного ключа")
        }
        let android = try AndroidRSAPublicKey.encode(pkcs1: representation as Data)
        return Data((android.base64EncodedString() + " ravisty@iphone\0").utf8)
    }
}

enum AndroidRSAPublicKey {
    /// AOSP's 524-byte RSAPublicKey: 64, n0inv, n[256], R² mod n[256], exponent.
    static func encode(pkcs1: Data) throws -> Data {
        var parser = DERReader(Array(pkcs1))
        let sequence = try parser.element(tag: 0x30)
        guard parser.isAtEnd else { throw ADBError.key("лишние DER-данные") }
        var values = DERReader(sequence)
        var modulus = try values.element(tag: 0x02)
        let exponentBytes = try values.element(tag: 0x02)
        guard values.isAtEnd else { throw ADBError.key("неверная структура RSA") }
        while modulus.first == 0 && modulus.count > 1 { modulus.removeFirst() }
        guard modulus.count == 256, modulus[0] & 0x80 != 0,
              modulus.last! & 1 == 1, exponentBytes.count <= 4 else {
            throw ADBError.key("требуется нечётный 2048-битный RSA modulus")
        }
        let exponent = exponentBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard exponent == 65537 || exponent == 3 else { throw ADBError.key("неподдерживаемый RSA exponent") }
        let littleBytes = Array(modulus.reversed())
        var words = [UInt32](repeating: 0, count: 64)
        for i in 0..<64 {
            for byte in 0..<4 { words[i] |= UInt32(littleBytes[i * 4 + byte]) << (byte * 8) }
        }
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- words[0] &* inverse) }
        let n0inv = 0 &- inverse
        var rr = [UInt32](repeating: 0, count: 64)
        rr[0] = 1
        for _ in 0..<4096 { doubleMod(&rr, modulus: words) }
        var encoded = Data()
        encoded.appendLE(64)
        encoded.appendLE(n0inv)
        words.forEach { encoded.appendLE($0) }
        rr.forEach { encoded.appendLE($0) }
        encoded.appendLE(exponent)
        return encoded
    }

    private static func doubleMod(_ value: inout [UInt32], modulus: [UInt32]) {
        var carry: UInt32 = 0
        for i in value.indices {
            let next = value[i] >> 31
            value[i] = value[i] << 1 | carry
            carry = next
        }
        var greaterOrEqual = true
        for i in value.indices.reversed() where value[i] != modulus[i] {
            greaterOrEqual = value[i] > modulus[i]
            break
        }
        if carry != 0 || greaterOrEqual {
            var borrow: UInt64 = 0
            for i in value.indices {
                let subtract = UInt64(modulus[i]) + borrow
                let current = UInt64(value[i])
                value[i] = UInt32(truncatingIfNeeded: current &- subtract)
                borrow = current < subtract ? 1 : 0
            }
        }
    }

    private struct DERReader {
        let bytes: [UInt8]
        var offset = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var isAtEnd: Bool { offset == bytes.count }
        mutating func element(tag: UInt8) throws -> [UInt8] {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw ADBError.key("DER tag") }
            offset += 1
            let firstLength = bytes[offset]; offset += 1
            var length = Int(firstLength)
            if firstLength & 0x80 != 0 {
                let count = Int(firstLength & 0x7f)
                guard count > 0, count <= 4, offset + count <= bytes.count else { throw ADBError.key("DER length") }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[offset]); offset += 1 }
            }
            guard length >= 0, length <= bytes.count - offset else { throw ADBError.key("DER bounds") }
            let output = Array(bytes[offset..<(offset + length)])
            offset += length
            return output
        }
    }
}
