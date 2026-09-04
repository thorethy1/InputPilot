import Security
import SwiftData
import XCTest
@testable import InputPilot

@MainActor final class SecretStoreTests: XCTestCase {
    private func makeStore() throws -> (SecretStore, ModelContext) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredSecret.self, configurations: configuration)
        let context = ModelContext(container)
        return (SecretStore(context: context), context)
    }

    private func allSecrets(_ context: ModelContext) throws -> [StoredSecret] {
        try context.fetch(FetchDescriptor<StoredSecret>())
    }

    func testSaveReadRoundTripAcrossNameAndID() throws {
        let (store, context) = try makeStore()
        try store.save(name: "work-password", value: "hunter2")

        XCTAssertEqual(try store.value(forName: "work-password"), "hunter2")
        let secret = try XCTUnwrap(try allSecrets(context).first)
        XCTAssertEqual(secret.name, "work-password")
        XCTAssertEqual(try store.value(forID: secret.id), "hunter2")

        try store.delete(id: secret.id)
        XCTAssertThrowsError(try store.value(forName: "work-password")) { error in
            guard case SecretStoreError.notFound = error else { return XCTFail("Expected notFound, got \(error)") }
        }
        XCTAssertTrue(try allSecrets(context).isEmpty)
        let keychainStatus = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecretStore.service,
            kSecAttrAccount as String: secret.id.uuidString
        ] as CFDictionary)
        XCTAssertTrue(keychainStatus == errSecSuccess || keychainStatus == errSecItemNotFound)
    }

    func testSaveWithExistingNameUpdatesValueAndKeepsID() throws {
        let (store, context) = try makeStore()
        try store.save(name: "work-password", value: "hunter2")
        let originalID = try XCTUnwrap(try allSecrets(context).first).id

        try store.save(name: "work-password", value: "correct horse battery staple")

        XCTAssertEqual(try store.value(forName: "work-password"), "correct horse battery staple")
        XCTAssertEqual(try allSecrets(context).count, 1)
        XCTAssertEqual(try allSecrets(context).first?.id, originalID)
    }

    func testValueForMissingNameThrowsNotFound() throws {
        let (store, _) = try makeStore()
        XCTAssertThrowsError(try store.value(forName: "nope")) { error in
            XCTAssertEqual((error as? SecretStoreError)?.errorDescription, "Secret ‘nope’ is missing.")
        }
        XCTAssertThrowsError(try store.value(forID: UUID())) { error in
            guard case SecretStoreError.notFound = error else { return XCTFail("Expected notFound, got \(error)") }
        }
    }

    func testRenameRejectsDuplicateNameAndUpdatesName() throws {
        let (store, context) = try makeStore()
        try store.save(name: "work-password", value: "a")
        try store.save(name: "api-token", value: "b")

        let renamed = try XCTUnwrap(try allSecrets(context).first(where: { $0.name == "api-token" }))
        XCTAssertThrowsError(try store.rename(id: renamed.id, to: "work-password")) { error in
            XCTAssertEqual((error as? SecretStoreError)?.errorDescription, "A secret named ‘work-password’ already exists.")
        }
        try store.rename(id: renamed.id, to: "api token")
        XCTAssertEqual(try allSecrets(context).first(where: { $0.id == renamed.id })?.name, "api token")
        XCTAssertEqual(try store.value(forName: "api token"), "b")
    }

    func testDeleteMissingSecretThrowsNotFound() throws {
        let (store, _) = try makeStore()
        XCTAssertThrowsError(try store.delete(id: UUID())) { error in
            guard case SecretStoreError.notFound = error else { return XCTFail("Expected notFound, got \(error)") }
        }
    }

    func testEmptyNameAndEmptyValueAreRejected() throws {
        let (store, context) = try makeStore()
        XCTAssertThrowsError(try store.save(name: "  ", value: "x")) { error in
            guard case SecretStoreError.invalidName = error else { return XCTFail("Expected invalidName, got \(error)") }
        }
        XCTAssertThrowsError(try store.save(name: "work-password", value: "")) { error in
            guard case SecretStoreError.invalidValue = error else { return XCTFail("Expected invalidValue, got \(error)") }
        }
        XCTAssertTrue(try allSecrets(context).isEmpty)
    }
}
