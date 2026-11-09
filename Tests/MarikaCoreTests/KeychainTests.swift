import Foundation
import Security
import Testing
@testable import MarikaCore

struct KeychainTests {
    @Test func replacingAnExistingCredentialNeverDeletesIt() {
        var stored = Data("previous credential".utf8)
        var updates = 0
        let operations = Keychain.Operations(update: { query, attributes in
            updates += 1
            #expect((query as NSDictionary)[kSecAttrAccount] as? String == "fixture")
            stored = (attributes as NSDictionary)[kSecValueData] as? Data ?? Data()
            return errSecSuccess
        }, add: { _ in Issue.record("An existing credential should be updated"); return errSecParam },
           delete: { _ in Issue.record("Replacing a credential must not delete it"); return errSecParam })

        #expect(Keychain.write("replacement", account: "fixture", operations: operations))
        #expect(updates == 1 && stored == Data("replacement".utf8))
    }

    @Test func rejectedUpdatesKeepThePreviousCredentialAndReportFailure() {
        var stored: Data? = Data("previous credential".utf8)
        let operations = Keychain.Operations(update: { _, _ in errSecInteractionNotAllowed },
            add: { _ in Issue.record("A rejected update must not fall back to adding"); return errSecSuccess },
            delete: { _ in stored = nil; return errSecSuccess })

        #expect(!Keychain.write("replacement", account: "fixture", operations: operations))
        #expect(stored == Data("previous credential".utf8))
    }

    @Test func aMissingCredentialIsAddedAndAddFailuresAreReported() {
        var added: Data?
        var status = errSecSuccess
        let operations = Keychain.Operations(update: { _, _ in errSecItemNotFound }, add: { attributes in
            #expect((attributes as NSDictionary)[kSecAttrAccessible] as? String == kSecAttrAccessibleWhenUnlocked as String)
            if status == errSecSuccess { added = (attributes as NSDictionary)[kSecValueData] as? Data }
            return status
        }, delete: { _ in Issue.record("Adding a credential must not delete anything"); return errSecParam })

        #expect(Keychain.write("new credential", account: "fixture", operations: operations))
        #expect(added == Data("new credential".utf8))
        status = errSecAuthFailed
        #expect(!Keychain.write("rejected", account: "fixture", operations: operations))
        #expect(added == Data("new credential".utf8))
    }

    @Test func concurrentCreationRetriesTheUpdateWithoutDeleting() {
        var updates = 0
        let operations = Keychain.Operations(update: { _, _ in
            updates += 1
            return updates == 1 ? errSecItemNotFound : errSecSuccess
        }, add: { _ in errSecDuplicateItem },
           delete: { _ in Issue.record("Concurrent creation must not delete credentials"); return errSecParam })
        #expect(Keychain.write("replacement", account: "fixture", operations: operations))
        #expect(updates == 2)
    }

    @Test func deletionReportsFailuresAndAcceptsAnAlreadyMissingItem() {
        var status = errSecSuccess
        let operations = Keychain.Operations(
            update: { _, _ in Issue.record("Deletion must not update"); return errSecParam },
            add: { _ in Issue.record("Deletion must not add"); return errSecParam }, delete: { _ in status })
        #expect(Keychain.write(nil, account: "fixture", operations: operations))
        status = errSecItemNotFound
        #expect(Keychain.write("", account: "fixture", operations: operations))
        status = errSecInteractionNotAllowed
        #expect(!Keychain.write(nil, account: "fixture", operations: operations))
    }
}
