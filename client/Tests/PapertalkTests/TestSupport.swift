import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Papertalk

/// Base class for every test in the suite. It installs `NetworkGuard`, so a
/// test that reaches for a real server (an LLM endpoint, doi2bib, the storage
/// server) fails instead of silently going out to the network.
class PapertalkTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        NetworkGuard.install()
    }

    override func setUp() {
        super.setUp()
        NetworkGuard.reset()
    }

    override func tearDown() {
        let blocked = NetworkGuard.blocked
        if !blocked.isEmpty {
            XCTFail("Test tried to reach the network: \(blocked.joined(separator: ", "))")
        }
        MockLLM.uninstall()
        super.tearDown()
    }
}

/// Catch-all `URLProtocol`: answers every request `MockLLM` isn't handling
/// with a connection error and records it. Registered once for the whole run.
/// It steps aside while `MockLLM` is installed: macOS consults the latest
/// registered protocol first, but Linux (corelibs Foundation) the earliest.
final class NetworkGuard: URLProtocol {
    private static let lock = NSLock()
    private static var installed = false
    private static var _blocked: [String] = []

    static var blocked: [String] { lock.withLock { _blocked } }
    static func reset() { lock.withLock { _blocked = [] } }

    static func install() {
        lock.withLock {
            guard !installed else { return }
            installed = true
            _ = URLProtocol.registerClass(NetworkGuard.self)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { MockLLM.onRequest == nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url?.absoluteString ?? "?"
        Self.lock.withLock { Self._blocked.append(url) }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

// MARK: - Fixtures

enum Fixtures {
    /// A fresh, empty folder under the temp directory.
    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func paper(
        id: String = UUID().uuidString,
        title: String? = "A Paper",
        filename: String? = "a.pdf",
        state: String = "done",
        createdIso: String? = "2024-01-01T00:00:00Z",
        tags: [String] = [],
        favorite: Bool = false,
        authors: [String] = [],
        doi: String = "",
        read: Bool = false,
        depth: String? = "in_depth",
        hasScript: Bool = true,
        hasAudio: Bool = true,
        speakers: [SpeakerConfig] = []
    ) -> Paper {
        var p = Paper(id: id, title: title, filename: filename, hasPdf: true, hasScript: hasScript,
                      hasAudio: hasAudio, createdIso: createdIso, publishedIso: nil, state: state,
                      tags: tags, favorite: favorite, authors: authors, affiliations: [], doi: doi,
                      read: read, depth: depth, bibtex: nil, progress: 0, duration: 0, progressTs: nil,
                      stage: state == "done" ? "done" : "extract", message: nil, statusError: nil)
        p.speakers = speakers
        return p
    }

    static func transcript(_ turns: [(String, String)], segmentTitle: String = "Segment") -> Transcript {
        let speakers = turns.map(\.0).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return Transcript(paperTitle: "T",
                          speakers: speakers.map { Transcript.Speaker(name: $0, persona: nil) },
                          segments: [Transcript.Segment(title: segmentTitle,
                                                        turns: turns.map { Transcript.Turn(speaker: $0.0, text: $0.1) })])
    }

    /// A minimal one-page PDF with `lines` of Helvetica text, built by hand.
    static func pdf(lines: [String]) -> Data {
        let ops = ["BT /F1 12 Tf 72 740 Td 16 TL"] + lines.map { "(\($0)) Tj T*" } + ["ET"]
        let stream = ops.joined(separator: "\n")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        out += offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// A valid 24 kHz mono 16-bit PCM WAV of `seconds` of silence.
    static func silentWAV(seconds: Double) -> Data {
        let sampleRate = 24_000
        let samples = Int(Double(sampleRate) * seconds)
        let dataBytes = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))
        return d
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
/// The store saves optimistically on detached tasks, so tests wait for disk.
@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}
