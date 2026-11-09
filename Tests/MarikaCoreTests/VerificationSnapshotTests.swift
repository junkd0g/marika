import Foundation
import Testing
@testable import MarikaCore

struct VerificationSnapshotTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verification-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, _ path: String, at root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func git(_ args: [String], at root: URL) async throws {
        let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path] + args, environment: ProcessInfo.processInfo.environment)
        #expect(result.succeeded)
    }

    @Test func detectsSameSizeEditsEvenWhenModificationTimeIsRestored() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try write("let x = 1", "a.swift", at: root)
        let before = try await VerificationSnapshot.capture(at: root)
        let file = root.appendingPathComponent("a.swift")
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate])
        try write("let x = 2", "a.swift", at: root)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        #expect(try await VerificationSnapshot.capture(at: root) != before)
        try write("let x = 1", "a.swift", at: root)
        #expect(try await VerificationSnapshot.capture(at: root) == before)
    }

    @Test func additionsRenamesDeletionAndExecutableBitsChangeFingerprint() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try write("test", "a.txt", at: root)
        let first = try await VerificationSnapshot.capture(at: root)
        try write("fixture", "fixture.txt", at: root)
        #expect(try await VerificationSnapshot.capture(at: root) != first)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fixture.txt"))
        #expect(try await VerificationSnapshot.capture(at: root) == first)
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.txt"), to: root.appendingPathComponent("b.txt"))
        let renamed = try await VerificationSnapshot.capture(at: root)
        #expect(renamed != first)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("b.txt").path)
        #expect(try await VerificationSnapshot.capture(at: root) != renamed)
    }

    @Test func excludesBuildOutputButTracksTestSourcesAndConfiguration() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try write("source", "Tests/a.swift", at: root)
        try write("config", "Package.swift", at: root)
        let first = try await VerificationSnapshot.capture(at: root)
        for path in [".build/output", "node_modules/a.js", "coverage/result", "__pycache__/a.pyc"] { try write("generated", path, at: root) }
        #expect(try await VerificationSnapshot.capture(at: root) == first)
        try write("changed", "Package.swift", at: root)
        #expect(try await VerificationSnapshot.capture(at: root) != first)
    }

    @Test func gitIgnoresGeneratedOutputButIncludesTrackedIgnoredFiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-q"], at: root)
        try write("generated/\n", ".gitignore", at: root)
        try write("source", "a.swift", at: root)
        try write("tracked", "generated/tracked.swift", at: root)
        try await git(["add", "-f", "generated/tracked.swift"], at: root)
        let first = try await VerificationSnapshot.capture(at: root)
        try write("ignored", "generated/cache.bin", at: root)
        #expect(try await VerificationSnapshot.capture(at: root) == first)
        try write("updated", "generated/tracked.swift", at: root)
        #expect(try await VerificationSnapshot.capture(at: root) != first)
        try FileManager.default.removeItem(at: root.appendingPathComponent("generated/tracked.swift"))
        #expect(try await VerificationSnapshot.capture(at: root) != first)
    }

    @Test func rootIdentityAndSavedRecordSurviveRestart() async throws {
        let root = try folder(), other = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        try write("same", "a.swift", at: root); try write("same", "a.swift", at: other)
        let snapshot = try await VerificationSnapshot.capture(at: root)
        #expect(try await VerificationSnapshot.capture(at: other) != snapshot)
        let record = TaskVerificationRecord(command: "tests", output: "passed", succeeded: true, snapshot: snapshot)
        let restored = try JSONDecoder().decode(TaskVerificationRecord.self, from: JSONEncoder().encode(record))
        #expect(restored == record && restored.snapshot == snapshot)
        let legacy = try JSONDecoder().decode(TaskVerificationRecord.self, from: Data(#"{"date":0,"command":"tests","output":"ok","succeeded":true}"#.utf8))
        #expect(legacy.snapshot == nil && legacy.snapshotIssue == nil)
    }

    @Test func projectInsideAnIgnoredParentFolderStillTracksItsCode() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        try await git(["init", "-q"], at: parent)
        try write("generated/\n", ".gitignore", at: parent)
        let root = parent.appendingPathComponent("generated/project")
        try write("first", "source.swift", at: root)
        let before = try await VerificationSnapshot.capture(at: root)
        #expect(before.fileCount == 1)
        try write("other", "source.swift", at: root)
        #expect(try await VerificationSnapshot.capture(at: root) != before)
    }

    @Test func externalLinksAndMissingRootsCannotProduceACurrentFingerprint() async throws {
        let root = try folder(), other = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        try write("outside", "secret", at: other)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: other.appendingPathComponent("secret"))
        await #expect(throws: (any Error).self) { try await VerificationSnapshot.capture(at: root) }
        await #expect(throws: (any Error).self) { try await VerificationSnapshot.capture(at: root.appendingPathComponent("missing")) }
    }
}
