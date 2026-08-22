import Foundation

/// Timestamps of a single dictation cycle, from "hotkey released" to
/// "text landed in the frontmost app". Written to the daemon log so the
/// end-to-end latency target can be verified against real usage instead
/// of the transcription step alone.
public struct LatencyTrace {
    /// Hotkey released (or toggled off) — the moment the user stops talking.
    public var stopRequested: CFAbsoluteTime
    /// Audio engine stopped and the WAV is closed on disk.
    public var audioReady: CFAbsoluteTime?
    /// Transcriber returned text.
    public var transcribed: CFAbsoluteTime?
    /// Text inserted into the active application.
    public var inserted: CFAbsoluteTime?

    public init(stopRequested: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        self.stopRequested = stopRequested
    }

    public mutating func markAudioReady(_ t: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        audioReady = t
    }

    public mutating func markTranscribed(_ t: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        transcribed = t
    }

    public mutating func markInserted(_ t: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        inserted = t
    }

    /// One-line log summary, e.g.
    /// `latency: total=612ms (capture=18ms transcribe=352ms insert=242ms) audio=2.8s chars=41`
    public func summary(audioSeconds: Double? = nil, characters: Int? = nil) -> String {
        var parts: [String] = []
        if let audioReady = audioReady {
            parts.append("capture=\(LatencyTrace.ms(audioReady - stopRequested))")
        }
        if let transcribed = transcribed, let audioReady = audioReady {
            parts.append("transcribe=\(LatencyTrace.ms(transcribed - audioReady))")
        }
        if let inserted = inserted, let transcribed = transcribed {
            parts.append("insert=\(LatencyTrace.ms(inserted - transcribed))")
        }

        let end = inserted ?? transcribed ?? audioReady ?? stopRequested
        var line = "latency: total=\(LatencyTrace.ms(end - stopRequested))"
        if !parts.isEmpty {
            line += " (\(parts.joined(separator: " ")))"
        }
        if let audioSeconds = audioSeconds {
            line += String(format: " audio=%.1fs", audioSeconds)
        }
        if let characters = characters {
            line += " chars=\(characters)"
        }
        return line
    }

    static func ms(_ seconds: CFAbsoluteTime) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }

    /// Duration of a PCM WAV, from the `data` chunk size and the `fmt ` byte rate.
    /// The chunks have to be walked rather than assuming a 44-byte header:
    /// `AVAudioFile` writes `JUNK`/`FLLR` padding chunks (~4 KB) before the audio,
    /// which a fixed-header calculation would count as sound.
    /// Returns nil when the file is missing or not a readable PCM WAV.
    public static func wavDuration(at url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              header.prefix(4).elementsEqual(Array("RIFF".utf8)),
              header.dropFirst(8).elementsEqual(Array("WAVE".utf8)) else { return nil }

        var offset: UInt64 = 12
        var byteRate: UInt32?

        while true {
            try? handle.seek(toOffset: offset)
            guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return nil }
            let id = head.prefix(4)
            let size = le32(head.dropFirst(4))

            if id.elementsEqual(Array("fmt ".utf8)) {
                guard let fmt = try? handle.read(upToCount: 16), fmt.count == 16 else { return nil }
                byteRate = le32(fmt.dropFirst(8))
            } else if id.elementsEqual(Array("data".utf8)) {
                guard let rate = byteRate, rate > 0, size > 0 else { return nil }
                return Double(size) / Double(rate)
            }

            // Chunks are word-aligned: an odd size is followed by a pad byte.
            offset += 8 + UInt64(size) + UInt64(size % 2)
        }
    }

    private static func le32(_ bytes: Data) -> UInt32 {
        var value: UInt32 = 0
        for (i, byte) in bytes.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * i)
        }
        return value
    }
}
