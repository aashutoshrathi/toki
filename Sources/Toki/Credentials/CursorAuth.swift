import CommonCrypto
import Foundation
import LocalAuthentication
import Security

enum CursorAuth {
    struct Credentials {
        let token: String
        let userId: String
    }

    enum Login {
        case missing
        case locked
        case connected(Credentials)
    }

    private static let storagePrefix = "cursor-safe-storage:v1:"
    private static let keyLock = NSLock()
    nonisolated(unsafe) private static var approvedKey: Data?

    static func read(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                     allowPrompt: Bool = false) -> Login {
        let db = "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard FileManager.default.fileExists(atPath: db),
              let stored = Shell.output("/usr/bin/sqlite3", ["-readonly", db,
                "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else { return .missing }

        if stored.hasPrefix(storagePrefix) {
            guard let ciphertext = Data(base64Encoded: String(stored.dropFirst(storagePrefix.count))),
                  ciphertext.starts(with: Data("v10".utf8)),
                  ciphertext.count > 3, (ciphertext.count - 3).isMultiple(of: kCCBlockSizeAES128) else {
                return .missing
            }

            let encryptedToken = Data(ciphertext.dropFirst(3))
            if let key = keyLock.withLock({ approvedKey }) {
                if let token = decrypt(encryptedToken, key: key) {
                    return credentials(token: token).map(Login.connected) ?? .missing
                }
                keyLock.withLock { if approvedKey == key { approvedKey = nil } }
            }

            // Only the card action can prompt. A prior Always Allow decision may be reused
            // by automatic refreshes, and a one-time Allow keeps the key in this process.
            guard let key = storageKey(allowPrompt: allowPrompt) else { return .locked }
            guard let token = decrypt(encryptedToken, key: key),
                  let credentials = credentials(token: token) else { return .missing }
            keyLock.withLock { approvedKey = key }
            return .connected(credentials)
        }

        return credentials(token: stored).map(Login.connected) ?? .missing
    }

    private static func credentials(token: String) -> Credentials? {
        guard token.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#,
                          options: .regularExpression) != nil,
              let userId = jwtSubject(token),
              userId.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return Credentials(token: token, userId: userId)
    }

    static func jwtSubject(_ token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let data = base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = object["sub"] as? String else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    private static func storageKey(allowPrompt: Bool) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecAttrAccount as String: "Cursor Key",
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        var lookup = SecItemCopyMatching(query as CFDictionary, &item)
        if lookup == errSecItemNotFound {
            query[kSecAttrAccount as String] = "Cursor"
            lookup = SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard lookup == errSecSuccess,
              let password = item as? Data, !password.isEmpty else { return nil }

        // Electron's macOS v10 format derives the encryption key from its Keychain item.
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                bytes.baseAddress?.assumingMemoryBound(to: Int8.self), bytes.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003, &key, kCCKeySizeAES128)
        }
        return status == kCCSuccess ? Data(key) : nil
    }

    private static func decrypt(_ ciphertext: Data, key: Data) -> String? {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var length = 0
        let status = output.withUnsafeMutableBytes { plaintext in
            key.withUnsafeBytes { key in
                ciphertext.withUnsafeBytes { ciphertext in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, key.count, iv, ciphertext.baseAddress, ciphertext.count,
                            plaintext.baseAddress, plaintext.count, &length)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: output.prefix(length), encoding: .utf8)
    }
}
