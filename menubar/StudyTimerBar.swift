// Study Timer menu bar app.
// Reads the same share codes as the Study Timer artifact and shows the
// countdown in the macOS menu bar, computed from this Mac's clock.

import AppKit

// ===== Share code logic (mirrors the artifact's pure functions) =====

struct Session: Equatable {
    let focus: Int       // minutes
    let brk: Int         // minutes
    let rounds: Int
    let startUtc: Double // epoch seconds
}

enum PhaseState { case notStarted, focus, brk, finished }

struct PhaseInfo {
    let state: PhaseState
    let round: Int
    let totalRounds: Int
    let remaining: Double // seconds
}

let formatVersion = "1"
let startMinSec = 1577836800.0 // 2020-01-01 UTC
let startMaxSec = 4102444800.0 // 2100-01-01 UTC

func validate(_ s: Session) -> String? {
    if !(1...180).contains(s.focus) { return "Focus minutes must be a whole number from 1 to 180." }
    if !(1...60).contains(s.brk) { return "Break minutes must be a whole number from 1 to 60." }
    if !(1...12).contains(s.rounds) { return "Rounds must be a whole number from 1 to 12." }
    if !(s.startUtc >= startMinSec && s.startUtc < startMaxSec) {
        return "Start time must be between the years 2020 and 2099."
    }
    return nil
}

// Position-weighted sum of character codes, mod 36^2, as two base36 characters.
func checksum(_ str: String) -> String {
    var sum = 0
    for (i, c) in str.unicodeScalars.enumerated() { sum += (i + 1) * Int(c.value) }
    let v = String(sum % 1296, radix: 36)
    return v.count < 2 ? "0" + v : v
}

func encode(_ s: Session) -> String {
    let body = [formatVersion,
                String(s.focus, radix: 36),
                String(s.brk, radix: 36),
                String(s.rounds, radix: 36),
                String(Int(s.startUtc.rounded()), radix: 36)].joined(separator: "-")
    return "\(body)-\(checksum(body))"
}

enum DecodeResult {
    case ok(Session)
    case fail(String)
}

func decode(_ code: String) -> DecodeResult {
    let clean = code.filter { !$0.isWhitespace }.lowercased()
    if clean.isEmpty { return .fail("Paste a share code first.") }
    let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyz-")
    if !clean.allSatisfy({ allowed.contains($0) }) {
        return .fail("This code has characters that don't belong. Codes use only letters, digits and dashes.")
    }
    let parts = clean.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    if parts.count != 6 || parts.contains(where: { $0.isEmpty }) {
        return .fail("This code is incomplete or has extra pieces. Copy the whole code again.")
    }
    if parts[0] != formatVersion { return .fail("This code was made by a different version of the timer.") }
    let body = parts[0..<5].joined(separator: "-")
    if checksum(body) != parts[5] { return .fail("This code doesn't check out. Look for a typo, or copy it again.") }
    guard let f = Int(parts[1], radix: 36), let b = Int(parts[2], radix: 36),
          let r = Int(parts[3], radix: 36), let t = Int(parts[4], radix: 36) else {
        return .fail("This code doesn't check out. Look for a typo, or copy it again.")
    }
    let s = Session(focus: f, brk: b, rounds: r, startUtc: Double(t))
    if let error = validate(s) { return .fail("This code has a bad setting. \(error)") }
    return .ok(s)
}

// Each round is focus then break, except the last round has no break.
func getPhase(_ s: Session, now: Double) -> PhaseInfo {
    let focusSec = Double(s.focus * 60)
    let cycleSec = Double((s.focus + s.brk) * 60)
    let totalSec = Double(s.rounds) * focusSec + Double((s.rounds - 1) * s.brk * 60)
    let elapsed = now - s.startUtc
    if elapsed < 0 { return PhaseInfo(state: .notStarted, round: 0, totalRounds: s.rounds, remaining: -elapsed) }
    if elapsed >= totalSec { return PhaseInfo(state: .finished, round: s.rounds, totalRounds: s.rounds, remaining: 0) }
    let index = (elapsed / cycleSec).rounded(.down)
    let into = elapsed - index * cycleSec
    if into < focusSec {
        return PhaseInfo(state: .focus, round: Int(index) + 1, totalRounds: s.rounds, remaining: focusSec - into)
    }
    return PhaseInfo(state: .brk, round: Int(index) + 1, totalRounds: s.rounds, remaining: cycleSec - into)
}

// Rounds up, so the display reads 00:01 until the exact boundary.
func formatClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// ===== Self-test (run with --test) =====

func runTests() -> Bool {
    var failures = 0
    func check(_ name: String, _ pass: Bool) {
        print("\(pass ? "✓" : "✗") \(name)")
        if !pass { failures += 1 }
    }
    // Codes produced by the artifact
    let fromArtifact: [(String, Session)] = [
        ("1-p-5-4-tn2co0-3r", Session(focus: 25, brk: 5, rounds: 4, startUtc: 1792260000)),
        ("1-1e-a-3-tn7pq0-9h", Session(focus: 50, brk: 10, rounds: 3, startUtc: 1792510200)),
        ("1-1-1-1-q3eio0-xt", Session(focus: 1, brk: 1, rounds: 1, startUtc: 1577836800)),
        ("1-50-1o-c-1vuhmnz-ps", Session(focus: 180, brk: 60, rounds: 12, startUtc: 4102444799)),
    ]
    for (code, expected) in fromArtifact {
        if case .ok(let s) = decode(code) { check("decode \(code)", s == expected) } else { check("decode \(code)", false) }
        check("encode matches artifact: \(code)", encode(expected) == code)
    }
    if case .ok = decode("  1-P-5-4-TN2CO0-3R\n") { check("spaces and capitals ignored", true) } else { check("spaces and capitals ignored", false) }
    let bad = ["", "hello", "1-p-5-4-tn2co0-$$", "1-p-5-4-tn2cp0-3r", "1-0-5-4-tn2co0-yf", "1-p-5-0-tn2co0-2z", "2-p-5-4-tn2co0-3s"]
    for code in bad {
        if case .fail = decode(code) { check("rejects \"\(code)\"", true) } else { check("rejects \"\(code)\"", false) }
    }
    let s = Session(focus: 25, brk: 5, rounds: 2, startUtc: 1792260000)
    let cases: [(Double, PhaseState, Int, Double)] = [
        (-120, .notStarted, 0, 120), (0, .focus, 1, 1500), (1499, .focus, 1, 1), (1500, .brk, 1, 300),
        (1860, .focus, 2, 1440), (3299, .focus, 2, 1), (3300, .finished, 2, 0), (3600, .finished, 2, 0),
    ]
    for (offset, st, round, remaining) in cases {
        let p = getPhase(s, now: s.startUtc + offset)
        check("25/5/2 at \(Int(offset))s → \(st) round \(round) \(formatClock(remaining))",
              p.state == st && p.round == round && p.remaining == remaining)
    }
    print(failures == 0 ? "All passed" : "\(failures) failed")
    return failures == 0
}

// ===== Menu bar app =====

let artifactURL = URL(string: "https://claude.ai/artifact/JnMKumzc6V92D4AHpx1K9L")!
let savedCodeKey = "lastShareCode"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var session: Session?
    var lastPhaseKey: String?
    let statusLine = NSMenuItem(title: "No session", action: nil, keyEquivalent: "")
    let settingsLine = NSMenuItem(title: "Paste a share code to join", action: nil, keyEquivalent: "")
    var copyItem: NSMenuItem!
    var leaveItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        settingsLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(settingsLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Join Code from Clipboard", action: #selector(joinFromClipboard), keyEquivalent: "v").target = self
        menu.addItem(withTitle: "Enter Code…", action: #selector(enterCode), keyEquivalent: "j").target = self
        copyItem = menu.addItem(withTitle: "Copy Current Code", action: #selector(copyCode), keyEquivalent: "c")
        copyItem.target = self
        leaveItem = menu.addItem(withTitle: "Leave Session", action: #selector(leave), keyEquivalent: "")
        leaveItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Study Timer in Browser", action: #selector(openArtifact), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        if let saved = UserDefaults.standard.string(forKey: savedCodeKey), case .ok(let s) = decode(saved) {
            session = s
        }

        // .common mode keeps the countdown moving while the menu is open.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    func tick() {
        guard let button = item.button else { return }
        copyItem.isEnabled = session != nil
        leaveItem.isEnabled = session != nil
        guard let s = session else {
            button.image = symbol("timer")
            button.title = ""
            statusLine.title = "No session"
            settingsLine.title = "Copy a share code, then choose Join Code from Clipboard"
            return
        }
        let p = getPhase(s, now: Date().timeIntervalSince1970)
        let clock = formatClock(p.remaining)
        switch p.state {
        case .notStarted:
            button.image = symbol("hourglass")
            button.title = " \(clock)"
            statusLine.title = "Starts in \(clock)"
        case .focus:
            button.image = symbol("brain.head.profile")
            button.title = " \(clock)"
            statusLine.title = "Focus · Round \(p.round) of \(p.totalRounds) · \(clock) left"
        case .brk:
            button.image = symbol("cup.and.saucer")
            button.title = " \(clock)"
            statusLine.title = "Break · Round \(p.round) of \(p.totalRounds) · \(clock) left"
        case .finished:
            button.image = symbol("checkmark.circle")
            button.title = " Done"
            statusLine.title = "Session finished · \(s.rounds) of \(s.rounds) rounds done"
        }
        let start = Date(timeIntervalSince1970: s.startUtc)
        settingsLine.title = "\(s.focus) min focus · \(s.brk) min break · \(s.rounds) rounds · starts \(start.formatted(date: .omitted, time: .shortened))"

        // Sound when the phase changes while the app is running.
        let key = "\(p.state)-\(p.round)"
        if let last = lastPhaseKey, last != key { NSSound(named: "Glass")?.play() }
        lastPhaseKey = key
    }

    func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Study Timer")
        image?.isTemplate = true
        return image
    }

    func join(_ code: String) {
        switch decode(code) {
        case .ok(let s):
            session = s
            lastPhaseKey = nil
            UserDefaults.standard.set(encode(s), forKey: savedCodeKey)
            tick()
        case .fail(let error):
            showAlert("Couldn't join", error)
        }
    }

    @objc func joinFromClipboard() {
        join(NSPasteboard.general.string(forType: .string) ?? "")
    }

    @objc func enterCode() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Join a study session"
        alert.informativeText = "Paste the share code your partner sent you."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "1-p-5-4-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { join(field.stringValue) }
    }

    @objc func copyCode() {
        guard let s = session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(encode(s), forType: .string)
    }

    @objc func leave() {
        session = nil
        lastPhaseKey = nil
        UserDefaults.standard.removeObject(forKey: savedCodeKey)
        tick()
    }

    @objc func openArtifact() {
        NSWorkspace.shared.open(artifactURL)
    }

    func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

if CommandLine.arguments.contains("--test") {
    exit(runTests() ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
