import Foundation
import Security
import SwiftData

enum SecretStoreError: LocalizedError {
    case notFound(String)
    case duplicateName(String)
    case invalidName
    case invalidValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .notFound(name): "Secret ‘\(name)’ is missing."
        case let .duplicateName(name): "A secret named ‘\(name)’ already exists."
        case .invalidName: "The secret name must not be empty."
        case .invalidValue: "The secret value must not be empty."
        case let .keychain(status): "Keychain error (code \(status))."
        }
    }
}

@MainActor struct SecretStore {
    static let service = "app.inputpilot.secrets"
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save(name: String, value: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SecretStoreError.invalidName }
        guard !value.isEmpty else { throw SecretStoreError.invalidValue }
        if let existing = try fetchSecret(named: trimmedName) {
            try upsertKeychainValue(value, account: existing.id.uuidString)
            existing.updatedAt = Date()
            try? context.save()
        } else {
            let secret = StoredSecret(name: trimmedName)
            try upsertKeychainValue(value, account: secret.id.uuidString)
            context.insert(secret)
            try context.save()
        }
    }

    func value(forID id: UUID) throws -> String {
        var query = Self.baseQuery(account: id.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? SecretStoreError.notFound(id.uuidString) : SecretStoreError.keychain(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.keychain(errSecParam)
        }
        return value
    }

    func value(forName name: String) throws -> String {
        guard let secret = try fetchSecret(named: name) else { throw SecretStoreError.notFound(name) }
        return try value(forID: secret.id)
    }

    func delete(id: UUID) throws {
        guard let secret = try fetchSecret(id: id) else { throw SecretStoreError.notFound(id.uuidString) }
        let status = SecItemDelete(Self.baseQuery(account: id.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
        context.delete(secret)
        try context.save()
    }

    func rename(id: UUID, to newName: String) throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SecretStoreError.invalidName }
        guard let secret = try fetchSecret(id: id) else { throw SecretStoreError.notFound(id.uuidString) }
        if let clash = try fetchSecret(named: trimmedName), clash.id != id { throw SecretStoreError.duplicateName(trimmedName) }
        secret.name = trimmedName
        secret.updatedAt = Date()
        try context.save()
    }

    private func upsertKeychainValue(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = Self.baseQuery(account: account) as CFDictionary
        let status = SecItemUpdate(query, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
        var add = Self.baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func fetchSecret(named name: String) throws -> StoredSecret? {
        var descriptor = FetchDescriptor<StoredSecret>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchSecret(id: UUID) throws -> StoredSecret? {
        var descriptor = FetchDescriptor<StoredSecret>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
