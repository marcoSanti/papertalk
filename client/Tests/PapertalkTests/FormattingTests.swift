import XCTest
@testable import Papertalk

final class FormattingTests: PapertalkTestCase {
    func testFormatTime() {
        XCTAssertEqual(formatT(0), "0:00")
        XCTAssertEqual(formatT(65), "1:05")
        XCTAssertEqual(formatT(125), "2:05")
        XCTAssertEqual(formatT(600), "10:00")
        XCTAssertEqual(formatT(-3), "0:-3")
        // Non-finite values show a placeholder, never crash.
        XCTAssertEqual(formatT(.infinity), "–:––")
        XCTAssertEqual(formatT(.nan), "–:––")
    }

    func testStageLabelKnown() {
        XCTAssertEqual(stageLabel("extract"), "Extracting text from PDF")
        XCTAssertEqual(stageLabel("notes"), "Summarizing paper")
        XCTAssertEqual(stageLabel("outline"), "Planning episode")
        XCTAssertEqual(stageLabel("segments"), "Writing dialogue")
        XCTAssertEqual(stageLabel("audio"), "Synthesizing audio")
        XCTAssertEqual(stageLabel("finalize"), "Finalizing")
    }

    func testStageLabelFallbacks() {
        XCTAssertEqual(stageLabel(""), "Processing…")
        XCTAssertEqual(stageLabel("scrubbing"), "Scrubbing…")
        XCTAssertEqual(stageLabel("my_custom"), "My_Custom…")
    }

    func testFormatDateFullTimestamp() {
        // ISO8601 timestamp -> medium date.
        XCTAssertEqual(formatDate("2024-03-15T10:30:00Z"), dateString(2024, 3, 15))
    }

    func testFormatDatePartial() {
        XCTAssertEqual(formatDate("2024"), "2024")
        XCTAssertEqual(formatDate("2024-03"), "March 2024")
        XCTAssertEqual(formatDate("2024-03-15"), "Mar 15, 2024")
    }

    func testFormatDateBogus() {
        XCTAssertEqual(formatDate("not-a-date"), "")
        XCTAssertEqual(formatDate(""), "")
    }

    private func dateString(_ y: Int, _ m: Int, _ d: Int) -> String {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: comps)!
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .none
        return df.string(from: date)
    }
}

final class AuthorNameTests: PapertalkTestCase {
    func testClean() {
        XCTAssertEqual(AuthorName.clean("  Ada   Lovelace  "), "Ada Lovelace")
        XCTAssertEqual(AuthorName.clean("Grace\nHopper"), "Grace Hopper")
    }

    func testSortKey() {
        XCTAssertEqual(AuthorName.sortKey("Ada Lovelace"), "Lovelace Ada")
        XCTAssertEqual(AuthorName.sortKey("Solo"), "Solo")
    }

    func testIndexLetter() {
        XCTAssertEqual(AuthorName.indexLetter("Ada Lovelace"), "L")
        XCTAssertEqual(AuthorName.indexLetter("Élise Durand"), "D")
        XCTAssertEqual(AuthorName.indexLetter("Ada 9lives"), "#")
        XCTAssertEqual(AuthorName.indexLetter(""), "#")
    }
}

final class DepthTests: PapertalkTestCase {
    func testRawValuesAndLabels() {
        XCTAssertEqual(Depth.inDepth.rawValue, "in_depth")
        XCTAssertEqual(Depth.summary.rawValue, "summary")
        XCTAssertEqual(Depth.direct.rawValue, "direct")
        XCTAssertEqual(Depth.custom.rawValue, "custom")
        XCTAssertEqual(Depth.summary.label, "Summary")
        XCTAssertEqual(Depth.direct.label, "Direct read")
        XCTAssertEqual(Depth.inDepth.label, "In-depth")
    }

    func testAllCasesExist() {
        XCTAssertEqual(Depth.allCases.count, 4)
        for d in Depth.allCases { XCTAssertEqual(d.id, d.rawValue) }
    }
}