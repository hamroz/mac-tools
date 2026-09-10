import CoreGraphics
import Foundation

public struct NoteDisplay: Equatable, Sendable {
    public let id: UInt32
    public let visibleFrame: CGRect

    public init(id: UInt32, visibleFrame: CGRect) {
        self.id = id
        self.visibleFrame = visibleFrame
    }
}

public enum NoteGeometry {
    public static let defaultSize = CGSize(width: 260, height: 200)
    public static let minimumSize = CGSize(width: 180, height: 120)
    public static let maximumSize = CGSize(width: 520, height: 520)

    /// Displays are ordered with the primary display first. An empty list can
    /// occur while waking or changing display configuration; wait for the next event.
    public static func placement(frame: CGRect, displayID: UInt32?, displays: [NoteDisplay]) -> (frame: CGRect, displayID: UInt32)? {
        guard let display = displays.first(where: { $0.id == displayID }) ?? displays.first else { return nil }
        return (clamped(frame, to: display.visibleFrame), display.id)
    }

    public static func clamped(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = min(max(frame.width, minimumSize.width), min(maximumSize.width, visibleFrame.width))
        let height = min(max(frame.height, minimumSize.height), min(maximumSize.height, visibleFrame.height))

        let minX = visibleFrame.minX
        let maxX = max(minX, visibleFrame.maxX - width)
        let minY = visibleFrame.minY
        let maxY = max(minY, visibleFrame.maxY - height)

        return CGRect(
            x: min(max(frame.minX, minX), maxX),
            y: min(max(frame.minY, minY), maxY),
            width: width,
            height: height
        )
    }

    public static func frame(near pointer: CGPoint, in visibleFrame: CGRect) -> CGRect {
        let proposed = CGRect(
            x: pointer.x - defaultSize.width / 2,
            y: pointer.y - defaultSize.height / 2,
            width: defaultSize.width,
            height: defaultSize.height
        )
        return clamped(proposed, to: visibleFrame)
    }
}
