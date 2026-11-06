// Checks the macOS Help Book (shared/Papertalk.help): the app points at it, every page is
// reachable from the index, and no link is broken.

import Foundation
import XCTest

final class HelpBookTests: PapertalkTestCase {
    /// The repo root, from this file's place in client/Tests/PapertalkTests/.
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private var book: URL { root.appendingPathComponent("shared/Papertalk.help/Contents") }
    private var pages: URL { book.appendingPathComponent("Resources/en.lproj") }

    private func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The local pages `html` links to.
    private func links(in html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: ##"href="([^"#:]+)""##)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            .compactMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } }
    }

    func testAppInfoPlistNamesTheHelpBook() throws {
        let app = try plist(root.appendingPathComponent("client/Sources/Papertalk/macOS/Info.plist"))
        let help = try plist(book.appendingPathComponent("Info.plist"))
        XCTAssertEqual(app["CFBundleHelpBookFolder"] as? String, "Papertalk.help")
        XCTAssertEqual(app["CFBundleHelpBookName"] as? String, help["CFBundleIdentifier"] as? String)
        let access = try XCTUnwrap(help["HPDBookAccessPath"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pages.appendingPathComponent(access).path))
    }

    func testEveryPageIsLinkedFromTheIndexAndNoLinkIsBroken() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: pages.path)
        let html = files.filter { $0.hasSuffix(".html") }
        let indexLinks = Set(links(in: try String(contentsOf: pages.appendingPathComponent("index.html"), encoding: .utf8)))
        for page in html where page != "index.html" {
            XCTAssertTrue(indexLinks.contains(page), "\(page) isn't linked from index.html")
        }
        for page in html {
            let text = try String(contentsOf: pages.appendingPathComponent(page), encoding: .utf8)
            for link in links(in: text) {
                XCTAssertTrue(files.contains(link), "\(page) links to missing \(link)")
            }
        }
    }
}
