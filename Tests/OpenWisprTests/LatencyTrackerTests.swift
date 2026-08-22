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

    /// 16 kHz mono 16-bit PCM WAV; `padding` mimics the JUNK/FLLR chunks
    /// AVAudioFile writes before the audio data.
    private func makeWav(dataBytes: Int, padding: Int = 0) -> Data {
        func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
        func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }

        var fmt = Data("fmt ".utf8) + le32(16)
        fmt += le16(1) + le16(1) + le32(16000) + le32(32000) + le16(2) + le16(16)

        var body = Data()
        if padding > 0 {
            body += Data("JUNK".utf8) + le32(UInt32(padding)) + Data(count: padding)
        }
        body += fmt
        body += Data("data".utf8) + le32(UInt32(dataBytes)) + Data(count: dataBytes)

        return Data("RIFF".utf8) + le32(UInt32(4 + body.count)) + Data("WAVE".utf8) + body
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latency-\(UUID().uuidString).wav")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWavDurationFromDataChunk() throws {
        let url = try writeTemp(makeWav(dataBytes: 32000))
        XCTAssertEqual(try XCTUnwrap(LatencyTrace.wavDuration(at: url)), 1.0, accuracy: 0.001)
    }

    func testWavDurationIgnoresPaddingChunksBeforeAudio() throws {
        let url = try writeTemp(makeWav(dataBytes: 67200, padding: 4008))
        XCTAssertEqual(try XCTUnwrap(LatencyTrace.wavDuration(at: url)), 2.1, accuracy: 0.001)
    }

    func testWavDurationIsNilForMissingOrInvalidFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).wav")
        XCTAssertNil(LatencyTrace.wavDuration(at: missing))

        let notWav = try writeTemp(Data(count: 4096))
        XCTAssertNil(LatencyTrace.wavDuration(at: notWav))

        let empty = try writeTemp(makeWav(dataBytes: 0))
        XCTAssertNil(LatencyTrace.wavDuration(at: empty))
    }
}
