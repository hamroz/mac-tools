import Combine
import Foundation

@MainActor
public final class StickyNoteRepository: ObservableObject {
    @Published public private(set) var notes: [StickyNoteRecord] = []
    @Published public private(set) var warningMessage: String?
    @Published public private(set) var lastSaveError: String?

    public private(set) var recoveryURL: URL?

    private let storageURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var needsRecovery = false

    public var activeNotes: [StickyNoteRecord] {
        notes.filter { $0.deletedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public var deletedNotes: [StickyNoteRecord] {
        notes.filter { $0.deletedAt != nil }.sorted {
            ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast)
        }
    }

    public init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
        _ = purgeDeleted(olderThan: 30)
    }

    @discardableResult
    public func create(
        text: String = "",
        palette: NotePalette = .graphite,
        frame: CGRect,
        displayID: UInt32? = nil
    ) -> StickyNoteRecord {
        let timestamp = now()
        let note = StickyNoteRecord(
            text: text,
            palette: palette,
            frame: frame,
            displayID: displayID,
            createdAt: timestamp
        )
        notes.append(note)
        save()
        return note
    }

    public func note(id: UUID) -> StickyNoteRecord? {
        notes.first { $0.id == id }
    }

    public func updateText(id: UUID, text: String) {
        update(id: id) { note in
            guard note.text != text else { return false }
            note.text = text
            return true
        }
    }

    public func updatePalette(id: UUID, palette: NotePalette) {
        update(id: id) { note in
            guard note.palette != palette else { return false }
            note.palette = palette
            return true
        }
    }

    public func updateFrame(id: UUID, frame: CGRect, displayID: UInt32?) {
        update(id: id) { note in
            guard note.frame != frame || note.displayID != displayID else { return false }
            note.frame = frame
            note.displayID = displayID
            return true
        }
    }

    public func moveToRecentlyDeleted(id: UUID) {
        update(id: id) { note in
            guard note.deletedAt == nil else { return false }
            note.deletedAt = now()
            return true
        }
    }

    public func restore(id: UUID) {
        update(id: id) { note in
            guard note.deletedAt != nil else { return false }
            note.deletedAt = nil
            return true
        }
    }

    public func permanentlyDelete(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: index)
        save()
    }

    @discardableResult
    public func purgeDeleted(olderThan days: Int) -> Int {
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        let originalCount = notes.count
        notes.removeAll { note in
            guard let deletedAt = note.deletedAt else { return false }
            return deletedAt < cutoff
        }
        let removed = originalCount - notes.count
        if removed > 0 { save() }
        return removed
    }

    public func retrySave() {
        if needsRecovery { preserveCorruptStore() }
        save()
    }

    private func update(id: UUID, mutation: (inout StickyNoteRecord) -> Bool) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        guard mutation(&note) else { return }
        note.updatedAt = now()
        notes[index] = note
        save()
    }

    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            notes = try decoder.decode([StickyNoteRecord].self, from: data)
        } catch {
            needsRecovery = true
            preserveCorruptStore()
            notes = []
        }
    }

    private func preserveCorruptStore() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())
        let candidate = storageURL
            .deletingPathExtension()
            .appendingPathExtension("recovery-\(stamp)-\(UUID().uuidString).json")
        do {
            try fileManager.copyItem(at: storageURL, to: candidate)
            recoveryURL = candidate
            needsRecovery = false
            warningMessage = "Saved notes could not be read. The original file was preserved at \(candidate.path)."
        } catch {
            warningMessage = "Saved notes could not be read or copied for recovery: \(error.localizedDescription). Saving is paused to protect the original file."
        }
    }

    private func save() {
        guard !needsRecovery else {
            lastSaveError = "Saving is paused until the original notes file can be backed up. New changes are only in memory; keep Mac Tools open and try saving again."
            return
        }
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(notes)
            try data.write(to: storageURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = "Notes could not be saved: \(error.localizedDescription)"
        }
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Mac Tools", isDirectory: true)
            .appendingPathComponent("notes.json")
    }
}
