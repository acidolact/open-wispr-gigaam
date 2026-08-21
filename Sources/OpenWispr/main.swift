import AppKit
import Foundation
import OpenWisprLib

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

let version = OpenWispr.version

func printUsage() {
    print("""
    open-wispr v\(version) — Push-to-talk voice dictation for macOS

    USAGE:
        open-wispr start              Start the dictation daemon
        open-wispr stop               Stop the dictation daemon
        open-wispr set-hotkey <key>   Set the push-to-talk hotkey
        open-wispr get-hotkey         Show current hotkey
        open-wispr set-model <size>   Set the Whisper model
        open-wispr set-language <code>  Set the language (e.g. en, fr, auto)
        open-wispr download-model [size]  Download a Whisper model
        open-wispr status             Show configuration and status
        open-wispr postkey <vkey> down|up [hold-ms]  Post a synthetic key event (debug helper)
        open-wispr --help             Show this help message

    HOTKEY EXAMPLES:
        open-wispr set-hotkey globe             Globe/fn key (default)
        open-wispr set-hotkey rightoption        Right Option key
        open-wispr set-hotkey f5                 F5 key
        open-wispr set-hotkey ctrl+space         Ctrl + Space

    AVAILABLE MODELS:
        \(Config.supportedModels.joined(separator: ", "))
    """)
}

func cmdStart() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate

    signal(SIGINT) { _ in
        print("\nStopping open-wispr...")
        exit(0)
    }

    app.run()
}

func cmdSetHotkey(_ keyString: String) {
    guard let parsed = KeyCodes.parse(keyString) else {
        print("Error: Unknown key '\(keyString)'")
        print("Run 'open-wispr --help' for examples")
        exit(1)
    }

    var config = Config.load()
    config.hotkey = HotkeyConfig(keyCode: parsed.keyCode, modifiers: parsed.modifiers)

    do {
        try config.save()
        let desc = KeyCodes.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers)
        print("Hotkey set to: \(desc)")
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdSetModel(_ size: String) {
    guard Config.supportedModels.contains(size) else {
        print("Error: Unknown model '\(size)'")
        print("Available: \(Config.supportedModels.joined(separator: ", "))")
        exit(1)
    }

    var config = Config.load()
    config.modelSize = size

    do {
        try config.save()
        print("Model set to: \(size)")
        if !Transcriber.modelExists(modelSize: size) {
            print("Model will be downloaded on next start.")
        }
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdSetLanguage(_ lang: String) {
    let validCodes = Config.supportedLanguages.map { $0.code }
    guard validCodes.contains(lang) else {
        print("Error: Unknown language '\(lang)'")
        print("Available: auto, en, fr, de, es, zh, ja, ko, pt, it, nl, ru, ...")
        print("See full list: https://github.com/human37/open-wispr")
        exit(1)
    }

    var config = Config.load()
    config.language = lang

    do {
        try config.save()
        let name = Config.supportedLanguages.first(where: { $0.code == lang })?.name ?? lang
        print("Language set to: \(name) (\(lang))")
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdGetHotkey() {
    let config = Config.load()
    let desc = config.hotkeySummary()
    print("Current hotkey: \(desc)")
}

func cmdDownloadModel(_ size: String) {
    do {
        try ModelDownloader.download(modelSize: size)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdStatus() {
    let config = Config.load()
    let hotkeyDesc = config.hotkeySummary()

    print("open-wispr v\(version)")
    print("Config:      \(Config.configFile.path)")
    print("Hotkey:      \(hotkeyDesc)")
    print("Model:       \(config.modelSize)")
    print("Model ready: \(Transcriber.modelExists(modelSize: config.modelSize) ? "yes" : "no")")
    print("whisper-cpp: \(Transcriber.findWhisperBinary() != nil ? "yes" : "no")")
    if let server = config.whisperServerURL, !server.isEmpty {
        print("Server:     \(server) (persistent whisper-server mode)")
    } else {
        print("Server:     off (spawns whisper-cli per dictation)")
    }
    let langName = Config.supportedLanguages.first(where: { $0.code == config.language })?.name ?? config.language
    print("Language:    \(langName) (\(config.language))")
    let toggleMode = config.toggleMode?.value ?? false
    print("Toggle:      \(toggleMode ? "on (press to start/stop)" : "off (hold to talk)")")
}

func cmdListen(seconds: Int) {
    print("Listening for \(seconds)s on a GLOBAL monitor (keyDown/keyUp/flagsChanged). Post keys now.")
    let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
        print("  event type=\(event.type.rawValue) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)")
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: TimeInterval(seconds)))
    NSEvent.removeMonitor(monitor)
    print("Done.")
    exit(0)
}

func cmdStop() {
    let uid = getuid()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["bootout", "gui/\(uid)/local.openwispr.app"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            print("Stopped.")
            exit(0)
        }
    } catch {
        print("Failed to run launchctl: \(error)")
    }
    print("Not running (or failed to stop).")
    exit(1)
}

func cmdPostkey(_ args: [String]) {
    guard args.count >= 2, let vkey = UInt16(args[0]) else {
        print("Usage: open-wispr postkey <virtual-key> down|up [hold-ms]")
        exit(1)
    }
    let action = args[1].lowercased()
    guard ["down", "up", "press"].contains(action) else {
        print("Usage: open-wispr postkey <virtual-key> down|up [hold-ms]")
        exit(1)
    }
    let src = CGEventSource(stateID: .hidSystemState)
    let down = action != "up"
    guard let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(vkey), keyDown: down) else {
        print("error: failed to create CGEvent for vkey \(vkey)")
        exit(1)
    }
    ev.post(tap: .cghidEventTap)
    if down, args.count >= 3, let holdMs = Int(args[2]), holdMs > 0 {
        Thread.sleep(forTimeInterval: Double(holdMs) / 1000.0)
        if let upEv = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(vkey), keyDown: false) {
            upEv.post(tap: .cghidEventTap)
        }
    }
    print("posted vkey \(vkey) \(action)")
}

let args = CommandLine.arguments
let rawCommand = args.count > 1 ? args[1] : nil
let command: String? = {
    if let r = rawCommand, r.hasPrefix("-psn_") { return "start" }
    return rawCommand
}()

switch command {
case "start":
    if AppBundleLaunch.relaunchThroughAppBundleIfNeeded() {
        exit(0)
    }
    cmdStart()
case "stop":
    cmdStop()
case "listen":
    cmdListen(seconds: args.count > 2 ? (Int(args[2]) ?? 6) : 6)
case "set-hotkey":
    guard args.count > 2 else {
        print("Usage: open-wispr set-hotkey <key>")
        exit(1)
    }
    cmdSetHotkey(args[2])
case "set-model":
    guard args.count > 2 else {
        print("Usage: open-wispr set-model <size>")
        exit(1)
    }
    cmdSetModel(args[2])
case "set-language":
    guard args.count > 2 else {
        print("Usage: open-wispr set-language <code>")
        print("Examples: en, fr, auto")
        exit(1)
    }
    cmdSetLanguage(args[2])
case "get-hotkey":
    cmdGetHotkey()
case "postkey":
    guard args.count >= 4 else {
        print("Usage: open-wispr postkey <virtual-key> down|up [hold-ms]")
        exit(1)
    }
    cmdPostkey(Array(args[2...]))
case "download-model":
    let size = args.count > 2 ? args[2] : "base.en"
    cmdDownloadModel(size)
case "status":
    cmdStatus()
case "--help", "-h", "help":
    printUsage()
case nil:
    printUsage()
default:
    print("Unknown command: \(command!)")
    printUsage()
    exit(1)
}
