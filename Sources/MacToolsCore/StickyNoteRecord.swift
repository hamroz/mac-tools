import CoreGraphics
import Foundation

public enum NotePalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case sand
    case sage
    case sky
    case rose
    case graphite

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct StickyNoteRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var palette: NotePalette
    public var frame: CGRect
    public var displayID: UInt32?
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        text: String = "",
        palette: NotePalette = .graphite,
        frame: CGRect,
        displayID: UInt32? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.palette = palette
        self.frame = frame
        self.displayID = displayID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}
