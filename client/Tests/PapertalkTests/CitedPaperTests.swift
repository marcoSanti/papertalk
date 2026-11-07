// Tests of cited papers: the Crossref and LLM parsers, the References section cut, the
// pipeline call, the record's decoding and `CitedPapersPresentation`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Papertalk

final class CitedPaperTests: PapertalkTestCase {

    func testCrossrefReferencesPreferTitlesAndFallBackToTheRawText() {
        let message: [String: Any] = ["reference": [
            ["article-title": " Attention is\n all you need ", "author": "Vaswani", "year": "2017", "DOI": "10.5555/3295222"],
            ["unstructured": "Smith J. Some book. 2001."],
            ["key": "ref3"],  // nothing to show
        ]]
        XCTAssertEqual(CitedPaper.fromCrossref(message), [
            CitedPaper(title: "Attention is all you need", authors: "Vaswani", year: "2017", doi: "10.5555/3295222"),
            CitedPaper(title: "Smith J. Some book. 2001."),
        ])
        XCTAssertEqual(CitedPaper.fromCrossref([:]), [])
    }

    func testLLMReferencesDropUntitledEntriesAndAcceptNumericYears() {
        let obj: [String: Any] = ["references": [
            ["title": "BERT", "authors": "Devlin et al.", "year": 2019, "doi": "https://doi.org/10.18653/v1/N19-1423"],
            ["title": "", "authors": "Nobody"],
            ["title": "No DOI", "doi": ""],
        ]]
        XCTAssertEqual(CitedPaper.fromLLM(obj), [
            CitedPaper(title: "BERT", authors: "Devlin et al.", year: "2019", doi: "10.18653/v1/N19-1423"),
            CitedPaper(title: "No DOI"),
        ])
    }

    func testReferencesSectionStartsAtTheLastNumberedHeading() {
        let text = "Intro\nWe cite references here.\nReferences\nearly\n7 REFERENCES\n[1] A. B. Title. 2020.\n"
        XCTAssertEqual(CitedPaper.referencesSection(of: text), "[1] A. B. Title. 2020.")
        XCTAssertNil(CitedPaper.referencesSection(of: "No list\nat all"))
        XCTAssertNil(CitedPaper.referencesSection(of: "Bibliography\n  \n"))
    }

    func testPipelineSendsOnlyTheReferencesSection() async throws {
        MockLLM.install { request in
            let text = MockLLM.allText(in: request)
            XCTAssertTrue(text.contains("[1] Ada. Notes. 1843."))
            XCTAssertFalse(text.contains("Body text"))
            return (200, MockLLM.chatReply(#"{"references":[{"title":"Notes","authors":"Ada","year":"1843","doi":""}]}"#))
        }
        let p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        let refs = try await p.citedPapers(text: "Body text\nReferences\n[1] Ada. Notes. 1843.")
        XCTAssertEqual(refs, [CitedPaper(title: "Notes", authors: "Ada", year: "1843")])
    }

    func testPipelineSkipsTheLLMWithoutAReferencesSection() async throws {
        MockLLM.install { _ in XCTFail("no call expected"); return (500, Data()) }
        let p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        let refs = try await p.citedPapers(text: "Just a body")
        XCTAssertEqual(refs, [])
    }

    func testRecordsWithoutReferencesStillDecodeAndNewOnesRoundTrip() throws {
        var p = Fixtures.paper()
        let old = try JSONEncoder().encode(p)
        XCTAssertNil(try JSONDecoder().decode(Paper.self, from: old).references)
        p.references = [CitedPaper(title: "T", year: "2000")]
        XCTAssertEqual(try JSONDecoder().decode(Paper.self, from: JSONEncoder().encode(p)).references, p.references)
    }

    // MARK: Presentation

    func testShowLabelCountsAndHidesWhenEmpty() {
        var p = Fixtures.paper()
        XCTAssertNil(CitedPapersPresentation.showLabel(p))
        p.references = []
        XCTAssertNil(CitedPapersPresentation.showLabel(p))
        p.references = [CitedPaper(title: "A")]
        XCTAssertEqual(CitedPapersPresentation.showLabel(p), "Show 1 cited paper")
        p.references = [CitedPaper(title: "A"), CitedPaper(title: "B")]
        XCTAssertEqual(CitedPapersPresentation.showLabel(p), "Show 2 cited papers")
    }

    func testLinkIsTheDOIElseAScholarSearch() {
        let withDOI = CitedPaper(title: "X", doi: "10.1/abc")
        XCTAssertEqual(CitedPapersPresentation.link(withDOI)?.absoluteString, "https://doi.org/10.1/abc")
        XCTAssertEqual(CitedPapersPresentation.linkHelp(withDOI), "Open DOI")
        let bare = CitedPaper(title: "Deep & wide")
        XCTAssertEqual(CitedPapersPresentation.link(bare)?.absoluteString,
                       "https://scholar.google.com/scholar?q=Deep%20%26%20wide")
        XCTAssertEqual(CitedPapersPresentation.linkHelp(bare), "Search Google Scholar")
    }

    func testBylineAndCopyText() {
        let full = CitedPaper(title: "Title", authors: "Ada", year: "1843", doi: "10.1/x")
        XCTAssertEqual(CitedPapersPresentation.byline(full), "Ada · 1843")
        XCTAssertEqual(CitedPapersPresentation.copyText(full), "Ada (1843). Title. doi:10.1/x")
        XCTAssertNil(CitedPapersPresentation.byline(CitedPaper(title: "T")))
        XCTAssertEqual(CitedPapersPresentation.copyText(CitedPaper(title: "T.")), "T.")
        XCTAssertEqual(CitedPapersPresentation.copyText(CitedPaper(title: "T", authors: "Ada")), "Ada. T.")
    }

    func testMatchByDOIThenTitleButNeverTheCitingPaper() {
        var a = Fixtures.paper(title: "Attention Is All You Need"); a.doi = "10.1/ATT"
        let b = Fixtures.paper(title: "BERT: Pre-training")
        let lib = [a, b]
        XCTAssertEqual(CitedPapersPresentation.match(CitedPaper(title: "other", doi: "10.1/att"), in: lib, citing: "z")?.id, a.id)
        XCTAssertEqual(CitedPapersPresentation.match(CitedPaper(title: "bert pre-training"), in: lib, citing: "z")?.id, b.id)
        XCTAssertNil(CitedPapersPresentation.match(CitedPaper(title: "BERT: Pre-training"), in: lib, citing: b.id))
        XCTAssertNil(CitedPapersPresentation.match(CitedPaper(title: "Unknown"), in: lib, citing: "z"))
    }
}

/// Refreshing metadata fills the reference list: from Crossref when the DOI has one, else from the PDF.
@MainActor
final class CitedPaperStoreTests: PapertalkTestCase {
    private func store(pdfLines: [String]) async throws -> (AppStore, LocalStorage) {
        let storage = LocalStorage(root: Fixtures.tempDir())
        await storage.save(Fixtures.paper(id: "p"), K.paper("p"))
        try await storage.write(K.pdf("p"), Fixtures.pdf(lines: pdfLines))
        let store = AppStore(storage: storage, speech: FakeSpeechBackend())
        await waitUntil { store.papers.count == 1 }
        store.llm.baseUrl = "http://mock.local/v1"
        return (store, storage)
    }

    func testCrossrefReferencesAreSavedWithoutAskingTheLLM() async throws {
        let (store, storage) = try await store(pdfLines: ["Body", "References", "[1] Not read"])
        MockLLM.install { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("api.crossref.org") {
                return (200, Data(#"{"message":{"reference":[{"article-title":"Cited one","DOI":"10.1/c"}]}}"#.utf8))
            }
            if url.contains("doi2bib") { return (404, Data()) }
            let text = MockLLM.allText(in: request)
            XCTAssertFalse(text.contains("reference list"), "Crossref had them")
            return (200, MockLLM.chatReply(#"{"title":"T","authors":[],"affiliations":[],"doi":"10.1/p","tags":["x"]}"#))
        }
        store.refreshMeta("p")
        await waitUntil(timeout: 5) { await storage.exists(Paper.self, K.paper("p"))?.references != nil }
        let saved = await storage.exists(Paper.self, K.paper("p"))
        XCTAssertEqual(saved?.references, [CitedPaper(title: "Cited one", doi: "10.1/c")])
    }

    func testWithoutADOITheLLMReadsThePDFsList() async throws {
        let (store, storage) = try await store(pdfLines: ["Body", "References", "[1] Ada. Notes. 1843."])
        MockLLM.install { request in
            let text = MockLLM.allText(in: request)
            if text.contains("reference list") {
                return (200, MockLLM.chatReply(#"{"references":[{"title":"Notes","authors":"Ada","year":"1843"}]}"#))
            }
            return (200, MockLLM.chatReply(#"{"title":"T","authors":[],"affiliations":[],"doi":"","tags":["x"]}"#))
        }
        store.refreshMeta("p")
        await waitUntil(timeout: 5) { await storage.exists(Paper.self, K.paper("p"))?.references != nil }
        let saved = await storage.exists(Paper.self, K.paper("p"))
        XCTAssertEqual(saved?.references, [CitedPaper(title: "Notes", authors: "Ada", year: "1843")])
    }
}
