import Foundation

public class Transcriber {
    private let modelSize: String
    private let language: String
    private let whisperPrompt: String?
    public var spokenPunctuation: Bool = false

    /// When set, transcription is delegated to a persistent whisper-server
    /// (POST <serverURL>/inference, multipart "file" field) instead of
    /// spawning whisper-cli per dictation. This removes the ~1 s model-load
    /// cost and keeps the Metal context warm between requests.
    public var serverURL: URL?

    /// Optional beam_size override sent to the server (default: server default, 5).
    public var beamSize: Int?

    /// Injectable for tests.
    public var session: URLSession = .shared

    public init(modelSize: String = "base.en", language: String = "en", whisperPrompt: String? = nil) {
        self.modelSize = modelSize
        self.language = language
        self.whisperPrompt = whisperPrompt
    }

    /// Injectable fallback used when the whisper-server is unreachable at the
    /// network level (connection refused / host not found / timeout). Defaults
    /// to the built-in whisper-cli path; overridable in tests.
    public var connectionFailureFallback: ((URL) throws -> String)?

    public func transcribe(audioURL: URL) throws -> String {
        if let serverURL {
            do {
                return try transcribeViaServer(audioURL: audioURL, serverURL: serverURL)
            } catch let error as TranscriberError where Self.isConnectionFailure(error) {
                fputs("whisper-server unavailable (\(error)); falling back to whisper-cli\n", stderr)
                if let fallback = connectionFailureFallback {
                    return try fallback(audioURL)
                }
                return try transcribeViaCLI(audioURL: audioURL)
            } catch {
                throw error
            }
        }
        return try transcribeViaCLI(audioURL: audioURL)
    }

    /// True when the error is a network-level failure to reach the server,
    /// as opposed to an application-level (HTTP 5xx / bad payload) failure.
    private static func isConnectionFailure(_ error: TranscriberError) -> Bool {
        guard case .serverUnavailable(let code) = error, let code else { return false }
        let connectionCodes: Set<Int> = [
            URLError.cannotConnectToHost.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.timedOut.rawValue,
            URLError.notConnectedToInternet.rawValue,
            URLError.cannotFindHost.rawValue,
        ]
        return connectionCodes.contains(code)
    }

    /// Spawns whisper-cli to transcribe the audio file.
    func transcribeViaCLI(audioURL: URL) throws -> String {
        guard let whisperPath = Transcriber.findWhisperBinary() else {
            throw TranscriberError.whisperNotFound
        }

        guard let modelPath = Transcriber.findModel(modelSize: modelSize) else {
            throw TranscriberError.modelNotFound(modelSize)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments(modelPath: modelPath, audioURL: audioURL)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        var stderrData = Data()
        let stderrThread = Thread {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        stderrThread.start()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        while !stderrThread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        process.waitUntilExit()

        let output = Transcriber.stripWhisperMarkers(
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderr.isEmpty { fputs("whisper-cpp: \(stderr)\n", Foundation.stderr) }
            throw TranscriberError.transcriptionFailed
        }

        return output
    }

    /// Synchronous wrapper over URLSession.dataTask.
    /// Only used from background queues (transcription runs off the main thread).
    static func dataSynchronously(for request: URLRequest, session: URLSession) throws -> (Data, URLResponse?) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse?, Error?) = (Data(), nil, nil)

        let task = session.dataTask(with: request) { data, response, error in
            result = (data ?? Data(), response, error)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = result.2 {
            if let urlError = error as? URLError {
                throw TranscriberError.serverUnavailable(code: urlError.code.rawValue)
            }
            throw TranscriberError.transcriptionFailed
        }
        return (result.0, result.1)
    }

    // MARK: - whisper-server mode

    private func transcribeViaServer(audioURL: URL, serverURL: URL) throws -> String {
        let endpoint = serverURL.appendingPathComponent("inference")
        let boundary = "openwispr-\(UUID().uuidString)"
        let (body, contentType) = try Self.buildMultipartBody(
            audioURL: audioURL,
            boundary: boundary,
            language: language,
            prompt: effectiveWhisperPrompt,
            beamSize: beamSize
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try Self.dataSynchronously(for: request, session: session)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            fputs("whisper-server: request failed (\(String(data: data, encoding: .utf8) ?? "no response"))\n", stderr)
            throw TranscriberError.transcriptionFailed
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            fputs("whisper-server: unexpected response: \(String(data: data, encoding: .utf8) ?? "")\n", stderr)
            throw TranscriberError.transcriptionFailed
        }

        return Transcriber.stripWhisperMarkers(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Builds the multipart/form-data body for POST /inference.
    /// Exposed for unit tests.
    static func buildMultipartBody(
        audioURL: URL,
        boundary: String,
        language: String,
        prompt: String?,
        beamSize: Int?
    ) throws -> (body: Data, contentType: String) {
        var body = Data()

        func append(_ chunk: String) {
            body.append(chunk.data(using: .utf8)!)
        }

        let filename = audioURL.lastPathComponent
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(Self.mimeForPath(filename))\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")

        func appendScalar(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        if !language.isEmpty {
            appendScalar("language", language)
        }
        if let prompt, !prompt.isEmpty {
            appendScalar("prompt", prompt)
        }
        if let beamSize {
            appendScalar("beam_size", "\(beamSize)")
        }

        append("--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private static func mimeForPath(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "ogg", "oga": return "audio/ogg"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    func arguments(modelPath: String, audioURL: URL) -> [String] {
        var args = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-l", language,
            "--no-timestamps",
            "-nt",
        ]
        if let prompt = effectiveWhisperPrompt {
            args += ["--prompt", prompt]
        }
        if spokenPunctuation {
            args += ["--suppress-regex", "[,\\.\\?!;:\\-—]"]
        }

        return args
    }

    private var effectiveWhisperPrompt: String? {
        guard let whisperPrompt else { return nil }
        return whisperPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : whisperPrompt
    }

    private static let knownMarkers: Set<String> = [
        "BLANK_AUDIO", "blank_audio",
        "Music", "MUSIC", "music",
        "Applause", "APPLAUSE", "applause",
        "Laughter", "LAUGHTER", "laughter",
        "silence", "Silence", "SILENCE",
        "SOUND", "Sound", "sound",
        "NOISE", "Noise", "noise",
        "INAUDIBLE", "inaudible",
    ]

    private static let markerRegex = try! NSRegularExpression(
        pattern: "[\\[\\(]\\s*([^\\]\\)]+?)\\s*[\\]\\)]"
    )

    public static func stripWhisperMarkers(_ text: String) -> String {
        let nsText = text as NSString
        let matches = markerRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            let innerRange = match.range(at: 1)
            let inner = nsText.substring(with: innerRange)
            if knownMarkers.contains(inner) {
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: "")
            }
        }
        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func findWhisperBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        for name in ["whisper-cli", "whisper-cpp"] {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = [name]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            try? which.run()
            which.waitUntilExit()

            let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let result = result, !result.isEmpty {
                return result
            }
        }

        return nil
    }

    public static func modelExists(modelSize: String) -> Bool {
        return findModel(modelSize: modelSize) != nil
    }

    static func findModel(modelSize: String) -> String? {
        let modelFileName = "ggml-\(modelSize).bin"

        let candidates = [
            "\(Config.configDir.path)/models/\(modelFileName)",
            "/opt/homebrew/share/whisper-cpp/models/\(modelFileName)",
            "/usr/local/share/whisper-cpp/models/\(modelFileName)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cache/whisper/\(modelFileName)",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}

enum TranscriberError: LocalizedError {
    case whisperNotFound
    case modelNotFound(String)
    case transcriptionFailed
    /// The persistent whisper-server could not be reached at the network
    /// level (connection refused, host not found, timeout). Carries the
    /// underlying `URLError.Code` raw value so callers can distinguish it
    /// from application-level (HTTP 5xx) failures.
    case serverUnavailable(code: Int?)

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cpp not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let size):
            return "Whisper model '\(size)' not found. Download it with: open-wispr download-model \(size)"
        case .transcriptionFailed:
            return "Transcription failed"
        case .serverUnavailable(let code):
            return "whisper-server unavailable (URLError code \(code.map(String.init) ?? "unknown"))"
        }
    }
}
