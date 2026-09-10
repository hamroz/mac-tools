import XCTest
@testable import MacToolsCore

final class HotKeyPresetTests: XCTestCase {
    func test_presetsHaveStableMappings() {
        XCTAssertEqual(HotKeyPreset.controlOptionN.keyCode, 45)
        XCTAssertEqual(HotKeyPreset.controlOptionN.modifiers, [.control, .option])
        XCTAssertEqual(HotKeyPreset.controlOptionS.keyCode, 1)
        XCTAssertEqual(HotKeyPreset.controlShiftN.modifiers, [.control, .shift])
        XCTAssertEqual(HotKeyPreset.commandOptionN.modifiers, [.command, .option])
    }

    func test_allPresetsRoundTripThroughRawValues() {
        for preset in HotKeyPreset.allCases {
            XCTAssertEqual(HotKeyPreset(rawValue: preset.rawValue), preset)
            XCTAssertFalse(preset.displayName.isEmpty)
        }
    }
}
