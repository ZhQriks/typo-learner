import CryptoKit
import Foundation
import Security
import TypoCore

/// Encrypted persistence: AES-256-GCM, with the key kept in your login Keychain.
/// Plaintext is never written to disk. Use from one queue only.
final class SecureStore: @unchecked Sendable {
    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case unreadable(movedTo: URL)

        var errorDescription: String? {
            switch self {
            case let .keychain(status):
                return "Keychain refused the encryption key (\(status)). Learning is not being saved."
            case let .unreadable(url):
                return "Saved data could not be decrypted. It was kept aside at \(url.lastPathComponent) and learning started fresh."
            }
        }
    }

    static let service = "io.github.zhqriks.TypoLearner"
    private static let account = "model-key"

    let directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TypoLearner", isDirectory: true)
    var file: URL { directory.appendingPathComponent("model.enc") }
    private var cachedKey: SymmetricKey?

    func load() throws -> LearnedModel? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let key = try key()
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
            return try JSONDecoder().decode(LearnedModel.self, from: plain)
        } catch {
            // Never overwrite data we cannot read.
            let aside = directory.appendingPathComponent("model-unreadable-\(Int(Date().timeIntervalSince1970)).enc")
            try FileManager.default.moveItem(at: file, to: aside)
            throw StoreError.unreadable(movedTo: aside)
        }
    }

    func save(_ model: LearnedModel) throws {
        let plain = try JSONEncoder().encode(model)
        guard let sealed = try AES.GCM.seal(plain, using: key()).combined else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try sealed.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func key() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            cachedKey = SymmetricKey(data: data)
            return cachedKey!
        }
        guard status == errSecItemNotFound else { throw StoreError.keychain(status) }

        let key = SymmetricKey(size: .bits256)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrLabel as String: "Typo Learner encryption key",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
        cachedKey = key
        return key
    }
}
