import XCTest
@testable import OpenWisprLib

final class TranscriberTests: XCTestCase {

    func testArgumentsIncludeWhisperPromptAsSingleFollowingArgument() throws {
        let prompt = "  Use punctuation, keep product names like OpenWispr.  "
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: prompt
        )
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        let promptFlagIndex = try XCTUnwrap(args.firstIndex(of: "--prompt"))
        XCTAssertEqual(args[promptFlagIndex + 1], prompt)
        XCTAssertEqual(args.filter { $0 == prompt }.count, 1)
    }

    func testArgumentsOmitNilWhisperPrompt() {
        let transcriber = Transcriber(modelSize: "base.en", language: "en")
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        XCTAssertFalse(args.contains("--prompt"))
    }

    func testArgumentsOmitWhitespaceOnlyWhisperPrompt() {
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: " \n\t "
        )
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        XCTAssertFalse(args.contains("--prompt"))
    }

    func testArgumentsKeepSuppressRegexWhenSpokenPunctuationUsesPrompt() throws {
        let prompt = "Use punctuation and short sentences."
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: prompt
        )
        transcriber.spokenPunctuation = true

        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        let promptFlagIndex = try XCTUnwrap(args.firstIndex(of: "--prompt"))
        XCTAssertEqual(args[promptFlagIndex + 1], prompt)

        let suppressFlagIndex = try XCTUnwrap(args.firstIndex(of: "--suppress-regex"))
        XCTAssertEqual(args[suppressFlagIndex + 1], "[,\\.\\?!;:\\-—]")
    }

    func testBlankAudioMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO]"), "")
    }

    func testBlankAudioWithWhitespace() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("  [BLANK_AUDIO]  "), "")
    }

    func testMultipleMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] [silence]"), "")
    }

    func testParenthesizedMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(BLANK_AUDIO)"), "")
    }

    func testNonSpeechEventMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[Music] [Applause]"), "")
    }

    func testMarkerMixedWithText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testMarkerAtStartOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] hello"), "hello")
    }

    func testMarkerAtEndOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO]"), "hello")
    }

    func testNormalTextUnchanged() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello world"), "hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(""), "")
    }

    func testUnknownBracketsPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("see [1] and (later)"), "see [1] and (later)")
    }

    func testKnownMarkerStrippedUnknownPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] see [1]"), "see [1]")
    }

    // MARK: - whisper-server mode

    final class StubInferenceProtocol: URLProtocol {
        static var lastRequest: URLRequest?
        static var lastBody = Data()

        override class func canInit(with request: URLRequest) -> Bool {
            return (request.url?.host == "stub.local")
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
            StubInferenceProtocol.lastRequest = request
            if let body = request.httpBody {
                StubInferenceProtocol.lastBody = body
            } else if let stream = request.httpBodyStream {
                var data = Data()
                stream.open()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                let firstRead = stream.read(buffer, maxLength: bufferSize)
                if firstRead > 0 { data.append(buffer, count: firstRead) }
                while firstRead > 0 {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
                StubInferenceProtocol.lastBody = data
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(#"{"text": "  [BLANK_AUDIO] Привет мир. \n"}"#.utf8)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testServerTranscribePostsMultipartAndStripsMarkers() throws {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("owtest-\(UUID().uuidString).wav")
        try Data([0xFF, 0xF6, 0x03, 0x00, 0x01, 0x02]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubInferenceProtocol.self]

        let transcriber = Transcriber(
            modelSize: "large-v3-turbo",
            language: "ru",
            whisperPrompt: "  \t "
        )
        transcriber.serverURL = URL(string: "http://stub.local:8123")
        transcriber.session = URLSession(configuration: config)

        let result = try transcriber.transcribe(audioURL: audio)
        XCTAssertEqual(result, "Привет мир.")

        let request = try XCTUnwrap(StubInferenceProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/inference")

        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), "multipart content-type: \(contentType)")

        let bodyString = String(decoding: StubInferenceProtocol.lastBody, as: UTF8.self)
        XCTAssertFalse(bodyString.isEmpty, "multipart body not captured")
        XCTAssertTrue(bodyString.contains("name=\"file\"; filename=\"\(audio.lastPathComponent)\""), "file part missing")
        XCTAssertTrue(bodyString.contains("name=\"language\""), "language part missing")
        XCTAssertTrue(bodyString.contains("ru"), "language value missing")
        XCTAssertFalse(bodyString.contains("name=\"prompt\""), "whitespace-only prompt must be omitted")
    }

    func testServerTranscribeSendsPromptAndBeamSize() throws {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("owtest-\(UUID().uuidString).wav")
        try Data([0x01, 0x02]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let (body, contentType) = try Transcriber.buildMultipartBody(
            audioURL: audio,
            boundary: "test-boundary",
            language: "ru",
            prompt: "Use punctuation.",
            beamSize: 1
        )
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        XCTAssertEqual(contentType, "multipart/form-data; boundary=test-boundary")
        XCTAssertTrue(bodyString.contains("name=\"prompt\""))
        XCTAssertTrue(bodyString.contains("Use punctuation.\r\n"))
        XCTAssertTrue(bodyString.contains("name=\"beam_size\""))
        XCTAssertTrue(bodyString.contains("1\r\n"))
    }

    func testServerTranscribeFailsOnErrorResponse() throws {
        final class ErrorProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool {
                return (request.url?.host == "stub.local")
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("boom".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("owtest-\(UUID().uuidString).wav")
        try Data([0x01]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ErrorProtocol.self]

        let transcriber = Transcriber(modelSize: "base", language: "ru")
        transcriber.serverURL = URL(string: "http://stub.local:8123")
        transcriber.session = URLSession(configuration: config)

        XCTAssertThrowsError(try transcriber.transcribe(audioURL: audio))
    }

    func testServerConnectionFailureFallsBackToCLI() throws {
        final class UnavailableProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool {
                return (request.url?.host == "stub.local")
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            }
            override func stopLoading() {}
        }

        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("owtest-\(UUID().uuidString).wav")
        try Data([0x01]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnavailableProtocol.self]

        let transcriber = Transcriber(modelSize: "base", language: "ru")
        transcriber.serverURL = URL(string: "http://stub.local:8123")
        transcriber.session = URLSession(configuration: config)
        var fallbackInvoked = false
        transcriber.connectionFailureFallback = { _ in
            fallbackInvoked = true
            return "FALLBACK_OK"
        }

        let result = try transcriber.transcribe(audioURL: audio)
        XCTAssertEqual(result, "FALLBACK_OK")
        XCTAssertTrue(fallbackInvoked, "connection failure must trigger the CLI fallback path")
    }

    func testServerHTTPErrorDoesNotFallBack() throws {
        // HTTP 5xx is an application-level failure, not a connection failure:
        // it must be rethrown, not masked by a whisper-cli fallback.
        final class ErrorProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool {
                return (request.url?.host == "stub.local")
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("boom".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("owtest-\(UUID().uuidString).wav")
        try Data([0x01]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ErrorProtocol.self]

        let transcriber = Transcriber(modelSize: "base", language: "ru")
        transcriber.serverURL = URL(string: "http://stub.local:8123")
        transcriber.session = URLSession(configuration: config)
        var fallbackInvoked = false
        transcriber.connectionFailureFallback = { _ in
            fallbackInvoked = true
            return "SHOULD_NOT_HAPPEN"
        }

        XCTAssertThrowsError(try transcriber.transcribe(audioURL: audio))
        XCTAssertFalse(fallbackInvoked, "HTTP 5xx must not trigger the connection-failure fallback")
    }
}
