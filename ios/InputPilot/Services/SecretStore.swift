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
    // The CI test host lacks the keychain-access entitlement (-34018), so unit tests run against an in-memory keychain.
    static let usesInMemoryKeychain = NSClassFromString("XCTestCase") != nil
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save(name: String, value: String, note: String = "") throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SecretStoreError.invalidName }
        guard !value.isEmpty else { throw SecretStoreError.invalidValue }
        guard try fetchSecret(named: trimmedName) == nil else { throw SecretStoreError.duplicateName(trimmedName) }
        let secret = StoredSecret(name: trimmedName, note: note)
        try upsertKeychainValue(value, account: secret.id.uuidString)
        context.insert(secret)
        try context.save()
    }

    func replaceValue(id: UUID, with newValue: String) throws {
        guard !newValue.isEmpty else { throw SecretStoreError.invalidValue }
        guard let secret = try fetchSecret(id: id) else { throw SecretStoreError.notFound(id.uuidString) }
        try upsertKeychainValue(newValue, account: secret.id.uuidString)
        secret.updatedAt = Date()
        try context.save()
    }

    func value(forID id: UUID) throws -> String {
        var result: AnyObject?
        let status: OSStatus
        if Self.usesInMemoryKeychain {
            if let data = InMemoryKeychain.copy(service: Self.service, account: id.uuidString) {
                result = data as NSData
                status = errSecSuccess
            } else {
                status = errSecItemNotFound
            }
        } else {
            var query = Self.baseQuery(account: id.uuidString)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                // Prefer the human-readable name over the raw UUID in user-facing errors.
                let metadata = (try? fetchSecret(id: id)) ?? nil
                throw SecretStoreError.notFound(metadata?.name ?? id.uuidString)
            }
            throw SecretStoreError.keychain(status)
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
        let status: OSStatus
        if Self.usesInMemoryKeychain {
            status = InMemoryKeychain.delete(service: Self.service, account: id.uuidString)
        } else {
            status = SecItemDelete(Self.baseQuery(account: id.uuidString) as CFDictionary)
        }
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
        let updateStatus: OSStatus
        if Self.usesInMemoryKeychain {
            updateStatus = InMemoryKeychain.update(service: Self.service, account: account, data: data)
        } else {
            updateStatus = SecItemUpdate(Self.baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SecretStoreError.keychain(updateStatus) }
        let addStatus: OSStatus
        if Self.usesInMemoryKeychain {
            addStatus = InMemoryKeychain.add(service: Self.service, account: account, data: data)
        } else {
            var add = Self.baseQuery(account: account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addStatus = SecItemAdd(add as CFDictionary, nil)
        }
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

enum InMemoryKeychain {
    private static let lock = NSLock()
    private static var items: [String: Data] = [:]

    private static func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }

    static func update(service: String, account: String, data: Data) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let key = key(service: service, account: account)
        guard items[key] != nil else { return errSecItemNotFound }
        items[key] = data
        return errSecSuccess
    }

    static func add(service: String, account: String, data: Data) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let key = key(service: service, account: account)
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = data
        return errSecSuccess
    }

    static func copy(service: String, account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key(service: service, account: account)]
    }

    static func delete(service: String, account: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        return items.removeValue(forKey: key(service: service, account: account)) != nil ? errSecSuccess : errSecItemNotFound
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
