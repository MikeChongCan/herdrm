import XCTest
@testable import herdrm

/// What a user sees in the sidebar's section headers. The sticky mechanics
/// are tested in the StickySectionHeaders package; this covers the wiring.
@MainActor
final class SidebarStickyHeadersUIUXTests: XCTestCase {
    func testSpacesHeaderStaysPinnedWhileItsRowsScroll() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        XCTAssertEqual(sidebar.pinnedHeader, .spaces)

        sidebar.scroll(.offset(180))
        XCTAssertEqual(sidebar.scrollOffset, 180, accuracy: 1)
        XCTAssertEqual(sidebar.pinnedHeader, .spaces)
    }

    func testAgentsHeaderTakesOverAfterSpacesScrollAway() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)

        sidebar.scroll(.bottom)
        XCTAssertEqual(sidebar.pinnedHeader, .agents)

        sidebar.scroll(.offset(sidebar.maxOffset - 60))
        XCTAssertEqual(sidebar.pinnedHeader, .agents)

        sidebar.scroll(.top)
        XCTAssertEqual(sidebar.pinnedHeader, .spaces)
    }

    func testClickingThePinnedHeaderCollapsesAndExpandsItsSection() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        let expanded = sidebar.listHeight

        sidebar.scroll(.offset(180))
        try sidebar.clickPinnedHeader()                       // Spaces ▾ → collapsed
        XCTAssertLessThan(sidebar.listHeight, expanded - 300)

        sidebar.scroll(.top)
        XCTAssertEqual(sidebar.pinnedHeader, .spaces)
        try sidebar.clickPinnedHeader()                       // Spaces ▸ → expanded
        XCTAssertEqual(sidebar.listHeight, expanded, accuracy: 2)
    }
}
