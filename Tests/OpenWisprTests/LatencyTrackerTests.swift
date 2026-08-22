import XCTest
@testable import OpenWisprLib

final class LatencyTrackerTests: XCTestCase {
    private func trace() -> LatencyTrace {
        var t = LatencyTrace(stopRequested: 1000)
        t.markAudioReady(1000.02)
        t.markTranscribed(1000.37)
        t.markInserted(1000.61)
        return t
    }

    func testSummaryBreaksDownEachStage() {
        let line = trace().summary()
        XCTAssertEqual(line, "latency: total=610ms (capture=20ms transcribe=350ms insert=240ms)")
    }

    func testSummaryIncludesAudioLengthAndCharacters() {
        let line = trace().summary(audioSeconds: 2.84, characters: 41)
        XCTAssertTrue(line.hasSuffix("audio=2.8s chars=41"), line)
    }

    func testSummaryWithOnlyStopRequestedReportsZeroTotal() {
        let line = LatencyTrace(stopRequested: 500).summary()
        XCTAssertEqual(line, "latency: total=0ms")
    }

    func testSummaryStopsAtLastRecordedStage() {
        var t = LatencyTrace(stopRequested: 10)
        t.markAudioReady(10.05)
        XCTAssertEqual(t.summary(), "latency: total=50ms (capture=50ms)")
    }

    func testWavDurationFromFileSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latency-\(UUID().uuidString).wav")
        // 44-byte header + 1 second of 16 kHz mono 16-bit PCM.
        let data = Data(count: 44 + 32000)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let duration = try XCTUnwrap(LatencyTrace.wavDuration(at: url))
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
    }

    func testWavDurationIsNilForMissingOrHeaderOnlyFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).wav")
        XCTAssertNil(LatencyTrace.wavDuration(at: missing))

        let headerOnly = FileManager.default.temporaryDirectory
            .appendingPathComponent("header-\(UUID().uuidString).wav")
        try Data(count: 44).write(to: headerOnly)
        defer { try? FileManager.default.removeItem(at: headerOnly) }
        XCTAssertNil(LatencyTrace.wavDuration(at: headerOnly))
    }
}
