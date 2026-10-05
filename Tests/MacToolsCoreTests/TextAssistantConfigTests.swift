import XCTest
@testable import MacToolsCore

final class TextAssistantConfigTests: XCTestCase {
    private let config = TextAssistantConfig.defaults

    func test_DefaultsRoundTripAsReadableJSON() throws {
        let data = config.encoded()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"rules\" : [\n"), "Multi-line prompts are written as arrays of lines")
        XCTAssertTrue(json.contains("\"_help\""))
        XCTAssertEqual(try TextAssistantConfig.decode(data), config)
        XCTAssertEqual(config.modes.map(\.id), ["improve", "fix", "translate", "shorten"])
        XCTAssertEqual(config.tones.first?.id, "my-style")
    }

    func test_PromptsAcceptAStringOrLines() throws {
        let json = """
        {"version":1,"rules":["one","two"],"styleGuide":"guide",
         "modes":[{"id":"reply","name":"Reply","instruction":"Write a reply."}],
         "tones":[{"id":"plain","name":"Plain"}]}
        """
        let decoded = try TextAssistantConfig.decode(Data(json.utf8))
        XCTAssertEqual(decoded.rules.text, "one\ntwo")
        XCTAssertEqual(decoded.mode(id: "reply")?.instruction.text, "Write a reply.")
        XCTAssertNil(decoded.tone(id: "plain")?.instruction)
    }

    func test_ProblemsAreExplained() {
        func problem(_ json: String) -> String? {
            do { _ = try TextAssistantConfig.decode(Data(json.utf8)); return nil }
            catch { return (error as? LocalizedError)?.errorDescription }
        }
        XCTAssertTrue(problem(#"{"version":1,"rules":"r""#)?.hasPrefix("config.json isn’t valid") == true)
        XCTAssertEqual(problem(#"{"version":1,"rules":"r","styleGuide":"g","modes":[],"tones":[{"id":"a","name":"A"}]}"#),
                       "config.json needs at least one entry in “modes”.")
        XCTAssertEqual(problem(#"{"version":1,"rules":"r","styleGuide":"g","modes":[{"id":"m","name":"M","instruction":"i"},{"id":"m","name":"N","instruction":"i"}],"tones":[{"id":"a","name":"A"}]}"#),
                       "config.json uses the id “m” more than once.")
        XCTAssertTrue(problem(#"{"version":1,"rules":"r","styleGuide":"g","tones":[]}"#)?.contains("“modes” is missing") == true)
    }

    func test_TranslateTargetsTheOtherLanguage() {
        let translate = config.mode(id: "translate")!, tone = config.tone(id: "original")!
        func system(_ text: String, mode: TextAssistantConfig.Mode = TextAssistantConfig.defaults.mode(id: "translate")!) -> String {
            PromptBuilder.request(text: text, mode: mode, tone: tone, config: config, styleSamples: nil, model: "m").system
        }
        XCTAssertTrue(system("Привет! Как у тебя дела сегодня?").contains("into English"))
        XCTAssertTrue(system("Hey, how is it going today?").contains("into Russian"))
        XCTAssertTrue(system("Bonjour, comment ça va aujourd'hui ? Je voulais te parler du projet.").contains("into English"), "Other languages use the fallback")
        XCTAssertTrue(system("ок").contains("into English"), "Very short Russian still counts as Russian")
        XCTAssertTrue(system("ok thx").contains("into Russian"), "Very short English still counts as English")
        var fixed = translate
        fixed.translation?.target = "German"
        XCTAssertTrue(system("Hey, how is it going today?", mode: fixed).contains("into German"))
    }

    func test_PromptLayersRulesTaskToneAndSamples() {
        let request = PromptBuilder.request(
            text: "hi", mode: config.mode(id: "improve")!, tone: config.tone(id: "my-style")!,
            config: config, styleSamples: "## English\nsample", model: "opencode/claude-haiku-4-5"
        )
        XCTAssertTrue(request.system.hasPrefix(config.rules.text))
        XCTAssertTrue(request.system.contains("Task:\nFix spelling"))
        XCTAssertTrue(request.system.contains("Tone:\nSound like the author as their style guide describes"))
        XCTAssertTrue(request.system.contains("win over how the selected text is written"), "The guide's capitalization beats the input's")
        XCTAssertTrue(request.system.hasSuffix("<style_samples>\n## English\nsample\n</style_samples>"))
        XCTAssertTrue(request.system.contains("Never copy their content"))
        XCTAssertTrue(request.system.contains("never add details the text doesn't contain"), "The guide can't introduce facts")
        XCTAssertEqual(request.user, "<text>\nhi\n</text>")
        XCTAssertEqual(request.model, "opencode/claude-haiku-4-5")

        let noSamples = PromptBuilder.request(text: "hi", mode: config.modes[0], tone: config.tones[0], config: config, styleSamples: nil, model: "m")
        XCTAssertFalse(noSamples.system.contains("<style_samples>"))
    }

    func test_StyleTemplateHoldsNoSamplesUntilFilledIn() {
        XCTAssertNil(StyleSamples.extract(from: TextAssistantConfig.styleTemplate))
        let filled = TextAssistantConfig.styleTemplate.replacingOccurrences(of: "## Русский\n", with: "## Русский\nну короче, завтра созвонимся)\n")
        XCTAssertEqual(StyleSamples.extract(from: filled), "## English\n\n\n\n## Русский\nну короче, завтра созвонимся)")
    }
}
