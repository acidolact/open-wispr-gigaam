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

    /// Duration of a 16 kHz mono 16-bit PCM WAV, derived from its size on disk.
    /// Returns nil when the file is missing or too small to hold a header.
    public static func wavDuration(at url: URL) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        let bytes = size.int64Value - 44
        guard bytes > 0 else { return nil }
        return Double(bytes) / (16000.0 * 2.0)
    }
}
