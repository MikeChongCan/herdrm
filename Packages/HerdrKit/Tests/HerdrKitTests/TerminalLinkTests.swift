import Foundation
import XCTest
@testable import HerdrKit

final class TerminalLinkTests: XCTestCase {
    func testHTTPSURL() {
        XCTAssertEqual(
            WebURL.first(in: "https://example.com/path?q=1"),
            URL(string: "https://example.com/path?q=1")
        )
    }

    func testHTTPURL() {
        XCTAssertEqual(WebURL.first(in: "http://example.com"), URL(string: "http://example.com"))
    }

    func testRejectedSchemesAndPaths() {
        for text in [
            "ftp://x",
            "file:///tmp",
            "mailto:a@b.c",
            "javascript:alert(1)",
            "data:text/html,x",
            "/usr/bin/ls",
            "foo/bar",
        ] {
            XCTAssertNil(WebURL.first(in: text), text)
        }
        XCTAssertNil(WebURL.first(in: ""))
    }

    func testCollectorDedupesByAbsoluteString() {
        var collector = WebLinkCollector()
        let url = URL(string: "https://example.com")!
        collector.add(url)
        collector.add(url)
        XCTAssertEqual(collector.urls, [url])
    }

    func testCollectorDropsOldestPastLimit() {
        var collector = WebLinkCollector()
        for i in 1...51 {
            collector.add(URL(string: "https://example.com/\(i)")!)
        }
        XCTAssertEqual(collector.urls.count, 50)
        XCTAssertEqual(collector.urls.first, URL(string: "https://example.com/2"))
        XCTAssertEqual(collector.urls.last, URL(string: "https://example.com/51"))
        XCTAssertFalse(collector.urls.contains(URL(string: "https://example.com/1")!))
    }

    func testPhoneAndAddressAreNotWebURLs() {
        XCTAssertNil(WebURL.first(in: "+1 415-555-0100"))
        XCTAssertNil(WebURL.first(in: "1 Infinite Loop, Cupertino, CA"))
    }

    func testExtractorStripsCSIFromVisibleLine() {
        var extractor = VisibleTextExtractor()
        let events = extractor.consume(Data("see \u{1b}[31mhttps://ex.com/a\u{1b}[0m now\n".utf8))
        XCTAssertEqual(events, [.line("see https://ex.com/a now")])
        XCTAssertEqual(WebURL.first(in: "see https://ex.com/a now"), URL(string: "https://ex.com/a"))
    }

    func testExtractorEmitsOSC8PayloadAndVisibleText() {
        var extractor = VisibleTextExtractor()
        var bytes = Data()
        bytes.append(0x1B)
        bytes.append(contentsOf: "]8;;https://ex.com/doc".utf8)
        bytes.append(0x07)
        bytes.append(contentsOf: "docs".utf8)
        bytes.append(0x1B)
        bytes.append(contentsOf: "]8;;".utf8)
        bytes.append(0x07)
        bytes.append(0x0A)
        XCTAssertEqual(
            extractor.consume(bytes),
            [.osc8("https://ex.com/doc"), .line("docs")]
        )
    }

    func testExtractorHoldsPartialLineAcrossChunks() {
        var extractor = VisibleTextExtractor()
        XCTAssertTrue(extractor.consume(Data("https://ex.com/ab".utf8)).isEmpty)
        XCTAssertEqual(
            extractor.consume(Data("cd\n".utf8)),
            [.line("https://ex.com/abcd")]
        )
    }

    func testExtractorDoesNotPublishUntilNewline() {
        var extractor = VisibleTextExtractor()
        let long = "https://example.com/" + String(repeating: "a", count: 80)
        XCTAssertTrue(extractor.consume(Data(long.utf8)).isEmpty)
        XCTAssertEqual(extractor.consume(Data("\n".utf8)), [.line(long)])
    }

    func testDetectedLinkFileURL() {
        XCTAssertEqual(
            DetectedLink.parse("file:///Users/me/README.md", cwd: nil, home: nil),
            .hostFile("/Users/me/README.md")
        )
        XCTAssertEqual(
            DetectedLink.parse("file://localhost/Users/me/a.md", cwd: nil, home: nil),
            .hostFile("/Users/me/a.md")
        )
        XCTAssertNil(DetectedLink.parse("file://other/Users/me/a.md", cwd: nil, home: nil))
    }

    func testDetectedLinkRelativeAndHome() {
        XCTAssertEqual(
            DetectedLink.parse("./docs/a.md", cwd: "/proj", home: nil),
            .hostFile("/proj/docs/a.md")
        )
        XCTAssertEqual(
            DetectedLink.parse("~/foo.md", cwd: nil, home: "/Users/me"),
            .hostFile("/Users/me/foo.md")
        )
    }

    func testDetectedLinkWebAndRejectedSchemes() {
        XCTAssertEqual(
            DetectedLink.parse("https://x.com", cwd: nil, home: nil),
            .web(URL(string: "https://x.com")!)
        )
        for raw in ["javascript:alert(1)", "ssh:host", "git://example.com/repo", #"C:\Windows\a.md"#] {
            XCTAssertNil(DetectedLink.parse(raw, cwd: "/proj", home: "/Users/me"), raw)
        }
    }

    func testDetectedLinkBareNameNeedsCwd() {
        XCTAssertEqual(
            DetectedLink.parse("foo.md", cwd: "/proj", home: nil),
            .hostFile("/proj/foo.md")
        )
        XCTAssertNil(DetectedLink.parse("foo.md", cwd: nil, home: nil))
    }

    func testDetectedLinkTrimsAndRejectsInternalWhitespace() {
        XCTAssertEqual(
            DetectedLink.parse(" /tmp/a.md ", cwd: nil, home: nil),
            .hostFile("/tmp/a.md")
        )
        XCTAssertNil(DetectedLink.parse("/tmp/a file.md", cwd: nil, home: nil))
    }
}
