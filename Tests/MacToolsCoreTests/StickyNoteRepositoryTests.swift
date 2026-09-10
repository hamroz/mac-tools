import Foundation
import XCTest
@testable import MacToolsCore

@MainActor
final class StickyNoteRepositoryTests: XCTestCase {
    func test_createsUpdatesAndReloadsNotes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("notes.json")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let repository = StickyNoteRepository(storageURL: store, now: { timestamp })
        let created = repository.create(
            text: "First draft",
            palette: .sage,
            frame: CGRect(x: 20, y: 40, width: 260, height: 200),
            displayID: 42
        )
        repository.updateText(id: created.id, text: "Saved text")
        repository.updatePalette(id: created.id, palette: .sky)

        let reloaded = StickyNoteRepository(storageURL: store, now: { timestamp })
        let saved = try XCTUnwrap(reloaded.note(id: created.id))
        XCTAssertEqual(saved.text, "Saved text")
        XCTAssertEqual(saved.palette, .sky)
        XCTAssertEqual(saved.displayID, 42)
        XCTAssertEqual(reloaded.activeNotes.count, 1)
    }

    func test_recentlyDeletedNotesCanBeRestoredOrPermanentlyDeleted() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = StickyNoteRepository(storageURL: directory.appendingPathComponent("notes.json"))
        let note = repository.create(frame: CGRect(x: 0, y: 0, width: 260, height: 200))

        repository.moveToRecentlyDeleted(id: note.id)
        XCTAssertTrue(repository.activeNotes.isEmpty)
        XCTAssertEqual(repository.deletedNotes.map(\.id), [note.id])

        repository.restore(id: note.id)
        XCTAssertEqual(repository.activeNotes.map(\.id), [note.id])

        repository.moveToRecentlyDeleted(id: note.id)
        repository.permanentlyDelete(id: note.id)
        XCTAssertTrue(repository.notes.isEmpty)
    }

    func test_purgesOnlyNotesDeletedMoreThanThirtyDaysAgo() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = StickyNoteRepository(
            storageURL: directory.appendingPathComponent("notes.json"),
            now: { clock }
        )
        let old = repository.create(frame: CGRect(x: 0, y: 0, width: 260, height: 200))
        repository.moveToRecentlyDeleted(id: old.id)

        clock = clock.addingTimeInterval(29 * 86_400)
        let recent = repository.create(frame: CGRect(x: 0, y: 0, width: 260, height: 200))
        repository.moveToRecentlyDeleted(id: recent.id)

        clock = clock.addingTimeInterval(2 * 86_400)
        let count = repository.purgeDeleted(olderThan: 30)

        XCTAssertEqual(count, 1)
        XCTAssertNil(repository.note(id: old.id))
        XCTAssertNotNil(repository.note(id: recent.id))
    }

    func test_preservesCorruptStoreWithoutOverwritingIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: store)

        let repository = StickyNoteRepository(
            storageURL: store,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        XCTAssertTrue(repository.notes.isEmpty)
        XCTAssertNotNil(repository.warningMessage)
        let recoveryURL = try XCTUnwrap(repository.recoveryURL)
        XCTAssertEqual(try Data(contentsOf: store), corruptData)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), corruptData)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacToolsTests-\(UUID().uuidString)", isDirectory: true)
    }

    func test_RecoveryFailureProtectsOriginalAndRetryPersistsPendingNotes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("notes.json")
        let original = Data("damaged but recoverable".utf8)
        try original.write(to: store)
        let files = RecoveryFileManager()
        let repository = StickyNoteRepository(storageURL: store, fileManager: files)
        XCTAssertNil(repository.recoveryURL)
        XCTAssertFalse(repository.warningMessage?.contains("was preserved") ?? false)
        let note = repository.create(text: "Pending note", frame: CGRect(x: 0, y: 0, width: 260, height: 200))
        repository.updateText(id: note.id, text: "Pending edit")
        repository.retrySave()
        XCTAssertEqual(try Data(contentsOf: store), original)
        XCTAssertNotNil(repository.lastSaveError)

        files.failCopy = false
        repository.retrySave()
        let recovery = try XCTUnwrap(repository.recoveryURL)
        XCTAssertEqual(try Data(contentsOf: recovery), original)
        XCTAssertNil(repository.lastSaveError)
        let reloaded = StickyNoteRepository(storageURL: store)
        XCTAssertEqual(reloaded.note(id: note.id)?.text, "Pending edit")
    }

    func test_RecoveryCopiesAreUniqueEvenAtTheSameTimestamp() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("notes.json")
        let bytes = Data("broken".utf8)
        try bytes.write(to: store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = StickyNoteRepository(storageURL: store, now: { now })
        let second = StickyNoteRepository(storageURL: store, now: { now })
        let a = try XCTUnwrap(first.recoveryURL)
        let b = try XCTUnwrap(second.recoveryURL)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try Data(contentsOf: a), bytes)
        XCTAssertEqual(try Data(contentsOf: b), bytes)
    }
}

private final class RecoveryFileManager: FileManager, @unchecked Sendable {
    var failCopy = true

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if failCopy { throw CocoaError(.fileWriteNoPermission) }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}
