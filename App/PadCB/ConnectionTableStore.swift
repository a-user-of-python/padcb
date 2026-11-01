import Foundation
import CryptoKit
import Security

/// Reads and writes encrypted connection tables in
/// Documents/ConnectionTables — one `<SchematicName>.pct` per saved
/// schematic.
///
/// Format (documented in CONTRACTS.md, "Part 2 — connection table
/// format"): an 8-byte ASCII magic "PadCBCT1", one format-version byte,
/// then the AES-GCM sealed box in combined form (12-byte nonce ||
/// ciphertext || 16-byte tag). The plaintext is the ConnectionTable
/// encoded as JSON (ISO-8601 dates, sorted keys).
///
/// The 256-bit AES key is generated once, on first use, and stored in
/// the device Keychain (ThisDeviceOnly, AfterFirstUnlock). It never
/// leaves the device and is never written next to the tables, so the
/// .pct files are opaque bytes to anything but this app on this iPad.
enum ConnectionTableStore {

    enum StoreError: Error, LocalizedError {
        case badHeader
        case unsupportedVersion(UInt8)
        case keychain(OSStatus)
        case randomGeneration(OSStatus)

        var errorDescription: String? {
            switch self {
            case .badHeader:
                return "That file is not a PadCB connection table."
            case .unsupportedVersion(let version):
                return "That connection table uses format version \(version), which this build cannot read."
            case .keychain(let status):
                return "The Keychain returned error \(status) while accessing the table key."
            case .randomGeneration(let status):
                return "Secure random generation failed with error \(status)."
            }
        }
    }

    private static let magic = Array("PadCBCT1".utf8)
    private static let fileVersion: UInt8 = 1
    private static let keyByteCount = 32

    static var directory: URL { PadCBPaths.connectionTablesDirectory }

    static func tableURL(forSchematicFile url: URL) -> URL {
        let stem = PadCBPaths.sanitizedStem(url.deletingPathExtension().lastPathComponent)
        return directory
            .appendingPathComponent(stem.isEmpty ? "Untitled" : stem)
            .appendingPathExtension("pct")
    }

    // MARK: - Save / load

    /// Encrypts and atomically writes the table for one schematic save.
    /// Returns the file written.
    @discardableResult
    static func save(_ table: ConnectionTable, forSchematicFile url: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(table)
        let encrypted = try encrypt(plaintext)

        PadCBPaths.ensureDirectory(directory)
        let target = tableURL(forSchematicFile: url)
        try encrypted.write(to: target, options: [.atomic])
        return target
    }

    static func load(from url: URL) throws -> ConnectionTable {
        let data = try Data(contentsOf: url)
        let plaintext = try decrypt(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConnectionTable.self, from: plaintext)
    }

    /// Every saved table, newest first (the debug view's list).
    static func availableTables() -> [URL] {
        PadCBPaths.ensureDirectory(directory)
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "pct" }
        return urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a > b
        }
    }

    // MARK: - AES-GCM envelope

    private static func encrypt(_ plaintext: Data) throws -> Data {
        let key = SymmetricKey(data: try keyData())
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw StoreError.badHeader
        }
        var out = Data(magic)
        out.append(fileVersion)
        out.append(combined)
        return out
    }

    private static func decrypt(_ data: Data) throws -> Data {
        let headerLength = magic.count + 1
        guard data.count > headerLength + 28,
              Array(data.prefix(magic.count)) == magic else {
            throw StoreError.badHeader
        }
        let version = data[magic.count]
        guard version == fileVersion else {
            throw StoreError.unsupportedVersion(version)
        }
        let key = SymmetricKey(data: try keyData())
        let sealed = try AES.GCM.SealedBox(combined: data.dropFirst(headerLength))
        return try AES.GCM.open(sealed, using: key)
    }

    // MARK: - Keychain key

    private static let keychainService = "com.user.padcb.connection-table"
    private static let keychainAccount = "aes-gcm-key-v1"

    private static func keyData() throws -> Data {
        if let existing = try readKey() { return existing }

        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, keyByteCount, &bytes)
        guard status == errSecSuccess else {
            throw StoreError.randomGeneration(status)
        }
        let key = Data(bytes)

        var query = baseKeyQuery()
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another call won the race; use the stored key.
            if let existing = try readKey() { return existing }
        }
        guard addStatus == errSecSuccess else {
            throw StoreError.keychain(addStatus)
        }
        return key
    }

    private static func readKey() throws -> Data? {
        var query = baseKeyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
        guard let data = item as? Data, data.count == keyByteCount else {
            return nil
        }
        return data
    }

    private static func baseKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
