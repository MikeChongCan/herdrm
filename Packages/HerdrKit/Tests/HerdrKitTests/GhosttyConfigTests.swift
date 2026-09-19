#if os(macOS)
import XCTest

@testable import HerdrKit

final class GhosttyConfigTests: XCTestCase {
    func testParsesFontFamilyAndSize() {
        let config = GhosttyConfigImporter.parse(
            """
            # my ghostty config
            font-family = JetBrains Mono
            font-size = 14
            theme = catppuccin
            """
        )
        XCTAssertEqual(config.fontFamily, "JetBrains Mono")
        XCTAssertEqual(config.fontSize, 14)
    }

    func testFirstFontFamilyWinsAndLastSizeWins() {
        let config = GhosttyConfigImporter.parse(
            """
            font-family = SF Mono
            font-family = Symbols Nerd Font
            font-size = 12
            font-size = 13.5
            """
        )
        XCTAssertEqual(config.fontFamily, "SF Mono")   // primary face, not the fallback
        XCTAssertEqual(config.fontSize, 13.5)          // scalar: final value wins
    }

    func testStripsQuotesAndIgnoresCommentsAndBlanks() {
        let config = GhosttyConfigImporter.parse(
            """

            #font-family = Commented Out
              font-family = "Berkeley Mono"

            font-size = "16"
            """
        )
        XCTAssertEqual(config.fontFamily, "Berkeley Mono")
        XCTAssertEqual(config.fontSize, 16)
    }

    func testEmptyValuesAndUnknownKeysAreIgnored() {
        let config = GhosttyConfigImporter.parse(
            """
            font-family =
            font-size = not-a-number
            window-padding-x = 4
            """
        )
        XCTAssertNil(config.fontFamily)
        XCTAssertNil(config.fontSize)
        XCTAssertTrue(config.isEmpty)
    }

    func testConfigURLPrefersXDGThenDotConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-cfg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let xdg = root.appendingPathComponent("xdg", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let xdgConfig = xdg.appendingPathComponent("ghostty/config")
        let dotConfig = home.appendingPathComponent(".config/ghostty/config")
        for url in [xdgConfig, dotConfig] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let withXDG = GhosttyConfigImporter.configURL(
            environment: ["XDG_CONFIG_HOME": xdg.path, "HOME": home.path]
        )
        XCTAssertEqual(withXDG?.path, xdgConfig.path)

        let withoutXDG = GhosttyConfigImporter.configURL(environment: ["HOME": home.path])
        XCTAssertEqual(withoutXDG?.path, dotConfig.path)
    }

    func testConfigURLNilWhenNothingExists() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-none-\(UUID().uuidString.prefix(8))")
        XCTAssertNil(GhosttyConfigImporter.configURL(environment: ["HOME": home.path]))
    }

    func testLoadReadsAndParsesDiscoveredConfig() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-load-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let config = home.appendingPathComponent(".config/ghostty/config")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "font-family = Berkeley Mono\nfont-size = 15\n".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let loaded = GhosttyConfigImporter.load(environment: ["HOME": home.path])
        XCTAssertEqual(loaded?.fontFamily, "Berkeley Mono")
        XCTAssertEqual(loaded?.fontSize, 15)
        XCTAssertNil(GhosttyConfigImporter.load(environment: ["HOME": "/nonexistent-\(UUID().uuidString)"]))
    }
}
#endif
