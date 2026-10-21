// Study Timer menu bar app.
// Click the ring in the menu bar to start, pause, skip or join a session.
// Reads and writes the same share codes as the Study Timer web page, and
// computes the countdown from this Mac's clock.

import AppKit
import SwiftUI
import AVFoundation
import UserNotifications
import ServiceManagement
import UniformTypeIdentifiers

// ===== Share code logic (mirrors the web timer's pure functions) =====

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

func totalSeconds(_ s: Session) -> Double {
    Double(s.rounds * s.focus * 60 + (s.rounds - 1) * s.brk * 60)
}

// How far through the current phase, 0...1.
func phaseProgress(_ s: Session, _ p: PhaseInfo) -> Double {
    switch p.state {
    case .focus: return min(1, max(0, 1 - p.remaining / Double(s.focus * 60)))
    case .brk: return min(1, max(0, 1 - p.remaining / Double(s.brk * 60)))
    case .finished: return 1
    case .notStarted: return 0
    }
}

// The aura's breath, 0 (exhaled) ... 1 (inhaled). Locked to the session clock,
// so it's the same on every device running the same code: one breath every
// 6 seconds, quickening to every 2 seconds in the last minute of a phase.
// Phases always end on a whole minute, so the switch never jumps.
func breath(elapsed: Double, remaining: Double, active: Bool) -> Double {
    let cycle = active && remaining <= 60 ? 2.0 : 6.0
    return (1 - cos(2 * Double.pi * elapsed / cycle)) / 2
}

// Prism theme: the aura's hue drifts ±50° once a minute, on the session clock.
func hueDrift(elapsed: Double) -> Double {
    50 * sin(2 * Double.pi * elapsed / 60)
}

// Pausing and skipping work by moving the start time, so the session is still
// one share code. Start times stay whole seconds so codes reproduce exactly.
func withStart(_ s: Session, _ start: Double) -> Session {
    Session(focus: s.focus, brk: s.brk, rounds: s.rounds, startUtc: start)
}

// Resume after a pause: push the start later by however long it was paused.
func resumed(_ s: Session, pausedAt: Double, now: Double) -> Session {
    withStart(s, s.startUtc + max(0, (now - pausedAt).rounded(.up)))
}

// Skip: pull the start earlier so the current phase ends right at `at`.
func skipped(_ s: Session, at: Double) -> Session {
    let p = getPhase(s, now: at)
    if p.state == .finished { return s }
    return withStart(s, s.startUtc - p.remaining.rounded(.up))
}

// Rounds up, so the display reads 00:01 until the exact boundary.
func formatClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// Compact menu bar time: "19m" (rounded up), or "42s" in the last minute.
func formatShort(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    if total < 60 { return "\(total)s" }
    return "\((total + 59) / 60)m"
}

func formatDuration(_ seconds: Double) -> String {
    let mins = Int((seconds / 60).rounded())
    let h = mins / 60, m = mins % 60
    if h == 0 { return "\(m) min" }
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}

func clockTime(_ epoch: Double) -> String {
    Date(timeIntervalSince1970: epoch).formatted(date: .omitted, time: .shortened).lowercased()
}

// ----- Spotify links and invites -----

// "https://open.spotify.com/intl-de/playlist/ID?si=…" or "spotify:playlist:ID" → "spotify:playlist:ID"
func spotifyURI(from link: String) -> String? {
    let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
    let kinds: Set<String> = ["playlist", "album", "track", "artist", "show", "episode"]
    if text.hasPrefix("spotify:") {
        let parts = text.split(separator: ":").map(String.init)
        return parts.count == 3 && kinds.contains(parts[1]) && !parts[2].isEmpty ? text : nil
    }
    guard let url = URL(string: text), let host = url.host, host.hasSuffix("spotify.com") else { return nil }
    let path = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
    guard path.count >= 2, kinds.contains(path[0]), !path[1].isEmpty else { return nil }
    return "spotify:\(path[0]):\(path[1])"
}

func inviteText(code: String, jam: String?) -> String {
    guard let jam = jam else { return code }
    return "study with me: \(code)\nlisten along (spotify jam): \(jam)"
}

// Pulls a share code and a Spotify link out of whatever was pasted:
// a bare code, or a whole invite message from a chat app.
func parseInvite(_ text: String) -> (code: String?, link: String?) {
    func first(_ pattern: String, _ options: NSRegularExpression.Options = []) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    let codes = first("[0-9a-z]+(?:-[0-9a-z]+){5}", [.caseInsensitive])
    let code = codes.first { if case .ok = decode($0) { return true } else { return false } }
    let link = first("https?://(?:open\\.spotify\\.com|spotify\\.link)/[^\\s]+").first
    return (code, link)
}

// ----- Alerts -----

/// What an alert says. Words in braces, like {round}, are filled in when
/// it's sent (see `alertTokens`).
struct AlertText: Codable, Equatable {
    var title: String
    var body: String
}

/// The fill-in words, and what each becomes.
struct AlertToken: Identifiable {
    let token: String
    let meaning: String
    var id: String { token }
}
let alertTokens = [
    AlertToken(token: "{round}", meaning: "this round's number"),
    AlertToken(token: "{rounds}", meaning: "how many rounds in all"),
    AlertToken(token: "{next}", meaning: "the next round's number"),
    AlertToken(token: "{focus}", meaning: "focus length, like 25 min"),
    AlertToken(token: "{break}", meaning: "break length, like 5 min"),
    AlertToken(token: "{time}", meaning: "when this part ends, like 3:05 pm"),
]

func alertValues(_ s: Session, round: Int, ends: Double) -> [String: String] {
    ["round": "\(round)", "rounds": "\(s.rounds)", "next": "\(min(round + 1, s.rounds))",
     "focus": "\(s.focus) min", "break": "\(s.brk) min", "time": clockTime(ends)]
}

/// Fills in the words it knows; anything else in braces stays as typed.
func fillAlert(_ template: String, _ values: [String: String]) -> String {
    var out = template
    for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: value) }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct AlertEvent: Equatable {
    let kind: ChimeEvent
    let at: Double
    let title: String
    let body: String
}

/// Every alert a session gives, in order, worded from `texts` (or the
/// defaults). Only the kinds in `on` are included, and the 1-minute
/// warnings need a phase of 3 minutes or more.
func alertSchedule(_ s: Session, on: Set<ChimeEvent>, texts: [ChimeEvent: AlertText] = [:]) -> [AlertEvent] {
    let f = Double(s.focus * 60), b = Double(s.brk * 60)
    var events: [AlertEvent] = []
    func add(_ kind: ChimeEvent, _ at: Double, round: Int, ends: Double) {
        guard on.contains(kind) else { return }
        let text = texts[kind] ?? kind.defaultText
        let values = alertValues(s, round: round, ends: ends)
        let title = fillAlert(text.title, values)
        events.append(AlertEvent(kind: kind, at: at,
                                 title: title.isEmpty ? fillAlert(kind.defaultText.title, values) : title,
                                 body: fillAlert(text.body, values)))
    }
    for i in 0..<s.rounds {
        let round = i + 1
        let focusStart = s.startUtc + Double(i) * (f + b)
        let focusEnd = focusStart + f
        add(.focus, focusStart, round: round, ends: focusEnd)
        if s.focus >= 3 { add(.focusWarning, focusEnd - 60, round: round, ends: focusEnd) }
        if round == s.rounds {
            add(.done, focusEnd, round: round, ends: focusEnd)
        } else {
            add(.brk, focusEnd, round: round, ends: focusEnd + b)
            if s.brk >= 3 { add(.warning, focusEnd + b - 60, round: round, ends: focusEnd + b) }
        }
    }
    return events
}

// ----- The setup dial -----
// One round on a clock-like face: focus from the top, then break. A lap is
// two hours, or four for rounds longer than that.

enum DialHandle { case focus, brk }

func dialLap(focus: Int, brk: Int) -> Double { focus + brk <= 120 ? 120 : 240 }

/// How far round the dial a point is, clockwise from the top, 0 to 1
/// (dx, dy from the center, with y pointing down).
func dialFraction(dx: Double, dy: Double) -> Double {
    let a = atan2(dx, -dy) / (2 * Double.pi)
    return a < 0 ? a + 1 : a
}

/// Follows the pointer the short way round, so crossing the top keeps
/// counting (0.95 → 1.05) instead of jumping a whole lap.
func dialUnwrap(_ from: Double, to pointer: Double) -> Double {
    var d = pointer - (from - from.rounded(.down))
    if d > 0.5 { d -= 1 } else if d < -0.5 { d += 1 }
    return from + d
}

/// The handle nearer the pointer (distance measured round the dial).
func nearestDialHandle(pointer: Double, focusEnd: Double, breakEnd: Double) -> DialHandle {
    func gap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }
    return gap(pointer, focusEnd) <= gap(pointer, breakEnd) ? .focus : .brk
}

/// Focus and break with a handle at `position` laps round: focus in 5-minute
/// steps, break in 1-minute steps, kept in range and on the dial.
func dialValues(_ handle: DialHandle, position: Double, focus: Int, brk: Int, lap: Double,
                focusRange: ClosedRange<Int> = 5...180, breakRange: ClosedRange<Int> = 1...60) -> (focus: Int, brk: Int) {
    let minutes = position * lap
    switch handle {
    case .focus:
        let top = min(focusRange.upperBound, Int(lap) - brk)
        return (min(top, max(focusRange.lowerBound, Int((minutes / 5).rounded()) * 5)), brk)
    case .brk:
        let top = min(breakRange.upperBound, Int(lap) - focus)
        return (focus, min(top, max(breakRange.lowerBound, Int((minutes - Double(focus)).rounded()))))
    }
}

// ----- Broadcast to other apps -----

// Study Timer announces its session to other apps on this Mac (for example a
// Vorssaint build with the Study Timer patch, which shows it in the notch).
// Other apps can ask for the current session and send pause, skip and end.
enum Broadcast {
    static let state = Notification.Name("com.braxtonhauw.studytimer.state")
    static let request = Notification.Name("com.braxtonhauw.studytimer.request")
    static let command = Notification.Name("com.braxtonhauw.studytimer.command")

    // The whole session in a few numbers; listeners compute the countdown themselves.
    static func info(session: Session?, pausedAt: Double?) -> [String: Any] {
        guard let s = session else { return ["active": false] }
        return ["active": true, "focus": s.focus, "brk": s.brk, "rounds": s.rounds,
                "startUtc": s.startUtc, "pausedAt": pausedAt ?? 0, "code": encode(s)]
    }

    enum Command: Equatable {
        case start(focus: Int, brk: Int, rounds: Int)
        case togglePause, skip, end, unknown
    }

    // A command from another app. "start" brings focus, brk and rounds, kept
    // inside Study Timer's limits.
    static func command(from info: [AnyHashable: Any]?) -> Command {
        func int(_ key: String) -> Int? {
            if let n = info?[key] as? Int { return n }
            if let n = info?[key] as? NSNumber { return n.intValue }
            return nil
        }
        switch info?["action"] as? String {
        case "start":
            guard let f = int("focus"), let b = int("brk"), let r = int("rounds") else { return .unknown }
            return .start(focus: min(180, max(1, f)), brk: min(60, max(1, b)), rounds: min(12, max(1, r)))
        case "togglePause": return .togglePause
        case "skip": return .skip
        case "end": return .end
        default: return .unknown
        }
    }
}

// ----- Background sound -----

enum AmbientKind: String, CaseIterable, Identifiable {
    case off, white, pink, brown, rain, ocean
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "off"
        case .white: return "white noise"
        case .pink: return "pink noise"
        case .brown: return "brown noise"
        case .rain: return "rain"
        case .ocean: return "ocean"
        }
    }
}

// Synthesizes looping background sound, one sample at a time, so there are
// no audio files and no loop seams. Runs on the audio thread: no allocation.
// `kind` and `target` are set from the main thread; the generator eases its
// gain toward `target`, so focus and break changes fade instead of cutting.
final class NoiseGenerator {
    var kind: AmbientKind = .off
    var target: Float = 0
    private(set) var gain: Float = 0
    let sampleRate: Double
    private let fade: Float
    private var seed: UInt32 = 0x9E37_79B9
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0
    private var brownLevel: Float = 0
    private var hpIn: Float = 0, hpOut: Float = 0
    private var drop: Float = 0
    private var t: Double = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fade = Float(4 / (1.5 * sampleRate)) // about 0.4 s to fade in or out
    }

    @inline(__always) private func white() -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }
    // Paul Kellet's pink noise filter.
    @inline(__always) private func pink(_ w: Float) -> Float {
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        return b0 + b1 + b2 + w * 0.1848
    }
    @inline(__always) private func brown(_ w: Float) -> Float {
        brownLevel = (brownLevel + 0.02 * w) / 1.02
        return brownLevel
    }

    func next() -> Float {
        gain += (target - gain) * fade
        if gain < 0.00005 && target == 0 { gain = 0; return 0 }
        let w = white()
        var s: Float
        switch kind {
        case .off: s = 0
        case .white: s = w * 0.14
        case .pink: s = pink(w) * 0.065
        case .brown: s = brown(w) * 2.8
        case .rain:
            // A steady high hiss plus about 27 random droplets a second.
            let p = pink(w) * 0.05
            hpOut = 0.97 * (hpOut + p - hpIn); hpIn = p
            if seed & 0xFFFF < 40 { drop = 0.3 + 0.7 * abs(white()) }
            drop *= 0.993
            s = hpOut * 1.5 + drop * w * 0.5
        case .ocean:
            // Brown noise swelling like a wave every 9 seconds.
            t += 1 / sampleRate
            let swell = Float((1 - cos(2 * Double.pi * t / 9)) / 2)
            s = brown(w) * 2.8 * (0.25 + 0.75 * swell)
        }
        return max(-1, min(1, s * gain))
    }
}

// ===== Self-test (run with --test) =====

func runTests() -> Bool {
    var failures = 0
    func check(_ name: String, _ pass: Bool) {
        print("\(pass ? "✓" : "✗") \(name)")
        if !pass { failures += 1 }
    }
    // Codes produced by the web timer
    let fromWeb: [(String, Session)] = [
        ("1-p-5-4-tn2co0-3r", Session(focus: 25, brk: 5, rounds: 4, startUtc: 1792260000)),
        ("1-1e-a-3-tn7pq0-9h", Session(focus: 50, brk: 10, rounds: 3, startUtc: 1792510200)),
        ("1-1-1-1-q3eio0-xt", Session(focus: 1, brk: 1, rounds: 1, startUtc: 1577836800)),
        ("1-50-1o-c-1vuhmnz-ps", Session(focus: 180, brk: 60, rounds: 12, startUtc: 4102444799)),
    ]
    for (code, expected) in fromWeb {
        if case .ok(let s) = decode(code) { check("decode \(code)", s == expected) } else { check("decode \(code)", false) }
        check("encode matches web timer: \(code)", encode(expected) == code)
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

    // Pause and skip
    let t0 = s.startUtc + 600 // 10 min into focus, 15:00 left
    let r = resumed(s, pausedAt: t0, now: t0 + 90)
    let pr = getPhase(r, now: t0 + 90)
    check("pause 90 s then resume keeps 15:00 left", pr.state == .focus && pr.remaining == 900)
    let sk = skipped(s, at: t0)
    let ps = getPhase(sk, now: t0)
    check("skip during focus jumps to a full break", ps.state == .brk && ps.round == 1 && ps.remaining == 300)
    let early = withStart(s, t0 + 300)
    let pe = getPhase(skipped(early, at: t0), now: t0)
    check("skip before start begins focus now", pe.state == .focus && pe.remaining == 1500)
    check("skip keeps a valid share code", validate(sk) == nil && encode(sk).count <= 20)
    check("formatDuration 115 min → 1 h 55 min", formatDuration(115 * 60) == "1 h 55 min")
    check("progress 10 min into 25 min focus is 0.4", abs(phaseProgress(s, getPhase(s, now: t0)) - 0.4) < 1e-9)
    check("short time: 18:42 → 19m, 1:00 → 1m, 0:42 → 42s",
          formatShort(1122) == "19m" && formatShort(60) == "1m" && formatShort(42) == "42s")

    // Breathing
    check("breath starts exhaled", breath(elapsed: 0, remaining: 900, active: true) < 1e-9)
    check("breath is full at 3 s", abs(breath(elapsed: 3, remaining: 900, active: true) - 1) < 1e-9)
    check("breath quickens in the last minute", abs(breath(elapsed: 1, remaining: 30, active: true) - 1) < 1e-9)
    check("breath is continuous where it quickens",
          abs(breath(elapsed: 1440, remaining: 60.0001, active: true) - breath(elapsed: 1440, remaining: 60, active: true)) < 1e-9)
    check("prism hue drift is 0° at start and +50° at 15 s",
          abs(hueDrift(elapsed: 0)) < 1e-9 && abs(hueDrift(elapsed: 15) - 50) < 1e-9)

    // Spotify links and invites
    check("spotify web link → URI",
          spotifyURI(from: "https://open.spotify.com/playlist/37i9dQZF1DX8Uebhn9wzrS?si=abc") == "spotify:playlist:37i9dQZF1DX8Uebhn9wzrS")
    check("spotify localized link → URI",
          spotifyURI(from: "https://open.spotify.com/intl-fr/album/4aawyAB9vmqN3uQ7FjRGTy") == "spotify:album:4aawyAB9vmqN3uQ7FjRGTy")
    check("spotify URI passes through", spotifyURI(from: " spotify:track:11dFghVXANMlKmJXsNCbNl ") != nil)
    check("non-spotify link rejected", spotifyURI(from: "https://example.com/playlist/x") == nil)
    let jam = "https://spotify.link/AbC123xyz"
    let parsed = parseInvite(inviteText(code: "1-p-5-4-tn2co0-3r", jam: jam))
    check("invite round trip keeps code and jam link", parsed.code == "1-p-5-4-tn2co0-3r" && parsed.link == jam)
    check("bare code still parses", parseInvite("1-p-5-4-tn2co0-3r").code == "1-p-5-4-tn2co0-3r")
    check("invite without a code finds no code", parseInvite("hey study-with-me later?").code == nil)
    let info = Broadcast.info(session: s, pausedAt: nil)
    check("broadcast carries the session", info["active"] as? Bool == true && info["focus"] as? Int == 25
          && info["rounds"] as? Int == 2 && info["startUtc"] as? Double == s.startUtc)
    check("broadcast with no session says inactive", Broadcast.info(session: nil, pausedAt: nil)["active"] as? Bool == false)
    check("start command from Vorssaint parses",
          Broadcast.command(from: ["action": "start", "focus": 50, "brk": 10, "rounds": 3]) == .start(focus: 50, brk: 10, rounds: 3))
    check("start command is kept inside the limits",
          Broadcast.command(from: ["action": "start", "focus": 500, "brk": 0, "rounds": 24]) == .start(focus: 180, brk: 1, rounds: 12))
    check("pause, skip and end commands parse",
          Broadcast.command(from: ["action": "togglePause"]) == .togglePause && Broadcast.command(from: ["action": "skip"]) == .skip
          && Broadcast.command(from: ["action": "end"]) == .end && Broadcast.command(from: ["action": "launch-rockets"]) == .unknown)

    // Alerts for 25/5/2: lock in, 1 min before break, break, 1 min before
    // break ends, back to focus, 1 min left, done.
    let all = alertSchedule(s, on: Set(ChimeEvent.allCases))
    check("25/5/2 gives 7 alerts in order", all.map(\.kind) == [.focus, .focusWarning, .brk, .warning, .focus, .focusWarning, .done])
    check("1 min before break comes at 24:00", all[1].at == s.startUtc + 1440)
    check("1 min before break ends comes at 29:00", all[3].at == s.startUtc + 1740)
    check("alerts you turn off are left out",
          alertSchedule(s, on: [.brk, .done]).map(\.kind) == [.brk, .done])
    check("no 1-minute warnings for 2-minute phases",
          alertSchedule(Session(focus: 2, brk: 2, rounds: 2, startUtc: s.startUtc), on: Set(ChimeEvent.allCases))
            .allSatisfy { $0.kind != .focusWarning && $0.kind != .warning })
    check("12 rounds fit in macOS's 64 pending notifications",
          alertSchedule(Session(focus: 25, brk: 5, rounds: 12, startUtc: s.startUtc), on: Set(ChimeEvent.allCases)).count <= 64)
    check("default break alert fills in the break length",
          all[2].title == "break time" && all[2].body == "Round 1 done. Take 5 min away from the screen.")
    // The setup dial
    check("dial: top is 0, right ¼, bottom ½, left ¾",
          dialFraction(dx: 0, dy: -1) == 0 && abs(dialFraction(dx: 1, dy: 0) - 0.25) < 1e-9
          && abs(dialFraction(dx: 0, dy: 1) - 0.5) < 1e-9 && abs(dialFraction(dx: -1, dy: 0) - 0.75) < 1e-9)
    check("dial: dragging past the top keeps counting", abs(dialUnwrap(0.95, to: 0.05) - 1.05) < 1e-9
          && abs(dialUnwrap(1.05, to: 0.9) - 0.9) < 1e-9)
    check("dial: a quarter lap of 2 hours is 30 min focus", dialValues(.focus, position: 0.25, focus: 25, brk: 5, lap: 120) == (30, 5))
    check("dial: focus snaps to 5 minutes", dialValues(.focus, position: 0.3, focus: 25, brk: 5, lap: 120).focus == 35)
    check("dial: break end at 36 min after 25 focus is an 11 min break",
          dialValues(.brk, position: 0.3, focus: 25, brk: 5, lap: 120) == (25, 11))
    check("dial: focus stays on the dial and in range",
          dialValues(.focus, position: 1.4, focus: 25, brk: 10, lap: 120).focus == 110
          && dialValues(.focus, position: -0.2, focus: 25, brk: 5, lap: 120).focus == 5)
    check("dial: break stays between 1 and 60 min",
          dialValues(.brk, position: 0.1, focus: 25, brk: 5, lap: 120).brk == 1
          && dialValues(.brk, position: 0.9, focus: 25, brk: 5, lap: 120).brk == 60)
    check("dial: long rounds get a 4-hour face", dialLap(focus: 90, brk: 15) == 120 && dialLap(focus: 120, brk: 30) == 240)
    check("dial: grabs the nearer end", nearestDialHandle(pointer: 0.21, focusEnd: 0.208, breakEnd: 0.25) == .focus
          && nearestDialHandle(pointer: 0.3, focusEnd: 0.208, breakEnd: 0.25) == .brk)

    let custom = alertSchedule(s, on: [.brk], texts: [.brk: AlertText(title: "{round}/{rounds} done", body: "next {next} · {focus} · {break}")])
    check("your own wording fills in every word", custom.first?.title == "1/2 done" && custom.first?.body == "next 2 · 25 min · 5 min")
    let timed = alertSchedule(s, on: [.warning], texts: [.warning: AlertText(title: "t", body: "{time}")])
    check("{time} is when the break ends", timed.first?.body == clockTime(s.startUtc + 1800))
    check("unknown words are left as typed, and an empty title falls back to the default",
          alertSchedule(s, on: [.done], texts: [.done: AlertText(title: " ", body: "{snack} time")]).first
            .map { $0.title == "session complete" && $0.body == "{snack} time" } == true)

    // Background sound: every kind makes sound, never clips, and fades to silence.
    for kind in AmbientKind.allCases where kind != .off {
        let g = NoiseGenerator(sampleRate: 44100)
        g.kind = kind; g.target = 1
        for _ in 0..<44100 { _ = g.next() }
        var sum: Double = 0, peak: Float = 0
        for _ in 0..<88200 { let v = g.next(); sum += Double(v * v); peak = max(peak, abs(v)) }
        let rms = (sum / 88200).squareRoot()
        g.target = 0
        for _ in 0..<(44100 * 4) { _ = g.next() }
        check("\(kind.title): audible, no clipping, fades out",
              rms > 0.05 && rms < 0.25 && peak < 1 && g.gain == 0)
    }

    print(failures == 0 ? "All passed" : "\(failures) failed")
    return failures == 0
}

// ===== App state =====

let webTimerURL = URL(string: "https://claude.ai/artifact/JnMKumzc6V92D4AHpx1K9L")!

enum Key {
    static let code = "lastShareCode"
    static let pausedAt = "pausedAt"
    static let jam = "jamLink"
    static let notifications = "notificationsOn"
    static let breakWarning = "breakWarningOn" // before 2.2; read once to carry the setting over
    static let alerts = "alertsOn"
    static let alertTexts = "alertTexts"
    static let pictureChoices = "pictureChoices"
    static let theme = "theme"
    static let ambient = "ambient"
    static let ambientVolume = "ambientVolume"
    static let ambientInBreaks = "ambientInBreaks"
    static let chimes = "chimes"
    static let chimeVolume = "chimeVolume"
    static let barStyle = "barStyle"
    static let barMinutes = "barMinutes"
    static let spotifyOnStart = "spotifyOnStart"
    static let spotifyPlaylist = "spotifyPlaylist"
    static let spotifyPauseOnBreak = "spotifyPauseOnBreak"
    static let presets = "presets"
}

enum BarStyle: String, CaseIterable, Identifiable {
    case ringAndTime, ring, time
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ringAndTime: return "ring + time"
        case .ring: return "ring"
        case .time: return "time"
        }
    }
}

// The moments Study Timer tells you about. Each can be turned off, and each
// has its own chime. (`warning` is the 1 minute before a break ends; the
// raw values are what saved chime choices use, so they stay as they are.)
enum ChimeEvent: String, CaseIterable, Identifiable {
    case focus, focusWarning, brk, warning, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .focus: return "focus starts"
        case .focusWarning: return "1 min before break"
        case .brk: return "break starts"
        case .warning: return "1 min before break ends"
        case .done: return "session done"
        }
    }
    var defaultSound: String {
        switch self {
        case .focus: return "Glass"
        case .focusWarning: return "Tink"
        case .brk: return "Submarine"
        case .warning: return "Tink"
        case .done: return "Hero"
        }
    }
    var defaultText: AlertText {
        switch self {
        case .focus: return AlertText(title: "lock in", body: "Round {round} of {rounds} · {focus}. Phone down.")
        case .focusWarning: return AlertText(title: "1 minute left", body: "Round {round} of {rounds} wraps up at {time}.")
        case .brk: return AlertText(title: "break time", body: "Round {round} done. Take {break} away from the screen.")
        case .warning: return AlertText(title: "1 minute left on break", body: "Round {next} starts at {time}.")
        case .done: return AlertText(title: "session complete", body: "All {rounds} rounds done. Nice work.")
        }
    }
}

// macOS's built-in sounds, available to every app by name.
let chimeSounds = ["none", "Glass", "Ping", "Pop", "Purr", "Tink", "Hero", "Submarine",
                   "Bottle", "Blow", "Frog", "Funk", "Morse", "Sosumi", "Basso"]

/// Plays a chime from /System/Library/Sounds like any other audio, so it
/// follows your Mac's main volume (not the alert volume). Returns false if
/// macOS couldn't play it.
@discardableResult
func playChime(_ name: String, volume: Double) -> Bool {
    ChimePlayer.shared.play(name, volume: volume)
}

final class ChimePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = ChimePlayer()
    private var playing: [AVAudioPlayer] = []   // a player stops if nothing holds it

    func play(_ name: String, volume: Double) -> Bool {
        guard name != "none" else { return true }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = Float(max(0, min(1, volume)))
            player.delegate = self
            playing.append(player)
            if player.play() { return true }
            playing.removeAll { $0 === player }
        }
        // Not a built-in file: any sound macOS knows by this name.
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            NSLog("Study Timer: no sound named \(name)")
            return false
        }
        sound.volume = Float(volume)
        let ok = sound.play()
        if !ok { NSLog("Study Timer: macOS wouldn't play \(name)") }
        return ok
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playing.removeAll { $0 === player } }
    }
}

struct Preset: Codable, Hashable, Identifiable {
    var focus: Int
    var brk: Int
    var rounds: Int
    var id: String { "\(focus)-\(brk)-\(rounds)" }
}
let defaultPresets = [Preset(focus: 25, brk: 5, rounds: 4), Preset(focus: 50, brk: 10, rounds: 3), Preset(focus: 90, brk: 15, rounds: 2)]
let maxPresets = 6

// Spotify only lets other apps play, pause and open things, not start a Jam,
// so the panel opens Spotify and shares whatever Jam link you paste in.
enum Spotify {
    static let bundleID = "com.spotify.client"
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    // The first script asks macOS for permission to control Spotify.
    private static func run(_ source: String) {
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error = error { NSLog("Spotify script failed: \(error)") }
        }
    }
    static func play() {
        guard installed else { return }
        run("if application \"Spotify\" is running then tell application \"Spotify\" to play")
    }
    static func pause() {
        guard installed else { return }
        run("if application \"Spotify\" is running then tell application \"Spotify\" to pause")
    }
    static func openApp() {
        let url = installed ? URL(string: "spotify:")! : URL(string: "https://open.spotify.com")!
        NSWorkspace.shared.open(url)
    }
    static func open(_ link: String) {
        if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) { NSWorkspace.shared.open(url) }
    }
    // Opens Spotify and starts the playlist, or just opens Spotify if no link is set.
    static func start(playlist link: String) {
        guard let uri = spotifyURI(from: link) else { openApp(); return }
        if installed {
            run("tell application \"Spotify\"\nactivate\nplay track \"\(uri)\"\nend tell")
        } else {
            open(link)
        }
    }
}

// Plays the background sound through the Mac's speakers.
final class AmbiencePlayer {
    private let engine = AVAudioEngine()
    private var generator: NoiseGenerator?
    private var stopWork: DispatchWorkItem?

    // level 0 fades out; the engine stops a few seconds after it goes quiet.
    func update(kind: AmbientKind, level: Float) {
        let wanted = kind != .off && level > 0
        if wanted {
            stopWork?.cancel(); stopWork = nil
            guard let g = ensureRunning() else { return }
            g.kind = kind
            g.target = level
        } else if let g = generator, g.target != 0 {
            g.target = 0
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.generator?.target == 0 else { return }
                self.engine.pause()
            }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func ensureRunning() -> NoiseGenerator? {
        if generator == nil {
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let g = NoiseGenerator(sampleRate: rate > 0 ? rate : 44100)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: g.sampleRate, channels: 2) else { return nil }
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                for frame in 0..<Int(frameCount) {
                    let sample = g.next()
                    for buffer in buffers {
                        buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                    }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            generator = g
        }
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("Audio failed to start: \(error)"); return nil }
        }
        return generator
    }
}

@MainActor
final class TimerModel: ObservableObject {
    private let defaults = UserDefaults.standard
    private let ambience = AmbiencePlayer()
    private var activity: NSObjectProtocol?

    @Published var session: Session?
    @Published var pausedAt: Double?
    @Published var jamLink: String? { didSet { defaults.set(jamLink, forKey: Key.jam) } }
    @Published var now = Date().timeIntervalSince1970
    @Published var codeChanged = false          // paused/skipped since the code was last copied
    @Published var notificationsAllowed = true  // what macOS says
    @Published var showSettings = false
    @Published var editingAlert: ChimeEvent?    // Settings → a notification's own page

    // Your wording for each alert (missing = the default) and its picture.
    @Published var alertTexts: [ChimeEvent: AlertText] = [:] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: alertTexts.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(raw), forKey: Key.alertTexts)
            rescheduleSoon()
        }
    }
    @Published private(set) var pictures: [ChimeEvent: NSImage] = [:]
    /// Which picture each alert uses: a built-in one's id, or "custom" for your own.
    @Published private(set) var pictureChoices: [ChimeEvent: String] = [:] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: pictureChoices.map { ($0.key.rawValue, $0.value) }),
                         forKey: Key.pictureChoices)
        }
    }
    @Published var testProblem: String?        // why the last test didn't pop up, if macOS said
    var pickPicture: ((ChimeEvent) -> Void)?   // the app shows the file picker

    // ----- Settings (saved as they change) -----
    @Published var themeID = "aura" {
        didSet {
            defaults.set(themeID, forKey: Key.theme)
            currentTheme = themes.first { $0.id == themeID } ?? themes[0]
            onThemeChange?()
        }
    }
    @Published var notificationsOn = true { didSet { defaults.set(notificationsOn, forKey: Key.notifications); if notificationsOn { requestAuthorization() }; reschedule() } }
    /// Which moments alert you (a pop-up if notifications are on, plus its chime).
    @Published var alerts: Set<ChimeEvent> = Set(ChimeEvent.allCases) {
        didSet { defaults.set(alerts.map(\.rawValue).sorted(), forKey: Key.alerts); reschedule() }
    }
    @Published var ambient: AmbientKind = .off { didSet { defaults.set(ambient.rawValue, forKey: Key.ambient); updateAmbience() } }
    @Published var ambientVolume = 0.5 { didSet { defaults.set(ambientVolume, forKey: Key.ambientVolume); updateAmbience() } }
    @Published var ambientInBreaks = false { didSet { defaults.set(ambientInBreaks, forKey: Key.ambientInBreaks); updateAmbience() } }
    @Published var chimes: [String: String] = [:] { didSet { defaults.set(chimes, forKey: Key.chimes) } }
    @Published var chimeVolume = 0.8 { didSet { defaults.set(chimeVolume, forKey: Key.chimeVolume) } }
    @Published var barStyle: BarStyle = .ringAndTime { didSet { defaults.set(barStyle.rawValue, forKey: Key.barStyle); onThemeChange?() } }
    @Published var barMinutes = false { didSet { defaults.set(barMinutes, forKey: Key.barMinutes); onThemeChange?() } }
    @Published var spotifyOnStart = false { didSet { defaults.set(spotifyOnStart, forKey: Key.spotifyOnStart) } }
    @Published var spotifyPlaylist = "" { didSet { defaults.set(spotifyPlaylist, forKey: Key.spotifyPlaylist) } }
    @Published var spotifyPauseOnBreak = false { didSet { defaults.set(spotifyPauseOnBreak, forKey: Key.spotifyPauseOnBreak) } }
    @Published var presets: [Preset] = defaultPresets {
        didSet { defaults.set(try? JSONEncoder().encode(presets), forKey: Key.presets) }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var onThemeChange: (() -> Void)?   // also redraws the menu bar
    private var lastPhaseKey: String?
    private var warnArmed: String?  // the phase whose 1-minute chime is still to come

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [Key.notifications: true, Key.breakWarning: true, Key.ambientVolume: 0.5, Key.chimeVolume: 0.8])
        themeID = d.string(forKey: Key.theme) ?? "aura"
        currentTheme = themes.first { $0.id == themeID } ?? themes[0]
        notificationsOn = d.bool(forKey: Key.notifications)
        if let saved = d.stringArray(forKey: Key.alerts) {
            alerts = Set(saved.compactMap(ChimeEvent.init(rawValue:)))
        } else if !d.bool(forKey: Key.breakWarning) {
            alerts.remove(.warning) // the old break-warning switch was off
        }
        if let data = d.data(forKey: Key.alertTexts),
           let raw = try? JSONDecoder().decode([String: AlertText].self, from: data) {
            alertTexts = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in ChimeEvent(rawValue: k).map { ($0, v) } })
        }
        let savedChoices = (d.dictionary(forKey: Key.pictureChoices) as? [String: String]) ?? [:]
        for kind in ChimeEvent.allCases {
            if let image = NSImage(contentsOf: Self.pictureURL(kind)) {
                pictures[kind] = image
                pictureChoices[kind] = savedChoices[kind.rawValue] ?? "custom"
            }
        }
        ambient = AmbientKind(rawValue: d.string(forKey: Key.ambient) ?? "") ?? .off
        ambientVolume = d.double(forKey: Key.ambientVolume)
        ambientInBreaks = d.bool(forKey: Key.ambientInBreaks)
        chimes = (d.dictionary(forKey: Key.chimes) as? [String: String]) ?? [:]
        chimeVolume = d.double(forKey: Key.chimeVolume)
        barStyle = BarStyle(rawValue: d.string(forKey: Key.barStyle) ?? "") ?? .ringAndTime
        barMinutes = d.bool(forKey: Key.barMinutes)
        spotifyOnStart = d.bool(forKey: Key.spotifyOnStart)
        spotifyPlaylist = d.string(forKey: Key.spotifyPlaylist) ?? ""
        spotifyPauseOnBreak = d.bool(forKey: Key.spotifyPauseOnBreak)
        if let data = d.data(forKey: Key.presets), let saved = try? JSONDecoder().decode([Preset].self, from: data), !saved.isEmpty {
            presets = saved
        }
        if let saved = d.string(forKey: Key.code), case .ok(let s) = decode(saved) {
            session = s
            let p = d.double(forKey: Key.pausedAt)
            pausedAt = p > 0 ? p : nil
            jamLink = d.string(forKey: Key.jam)
        }
    }

    // ----- Derived -----
    var isPaused: Bool { pausedAt != nil }
    var effectiveNow: Double { pausedAt ?? now }
    var phase: PhaseInfo? { session.map { getPhase($0, now: effectiveNow) } }
    var code: String? { session.map(encode) }

    func chime(for event: ChimeEvent) -> String { chimes[event.rawValue] ?? event.defaultSound }
    func setChime(_ name: String, for event: ChimeEvent) {
        chimes[event.rawValue] = name   // Settings plays it as a preview
    }

    // ----- Actions -----
    func start(focus: Int, brk: Int, rounds: Int) {
        let s = Session(focus: focus, brk: brk, rounds: rounds, startUtc: Date().timeIntervalSince1970.rounded(.down))
        if validate(s) != nil { return }
        set(s, paused: nil)
        jamLink = nil
        codeChanged = false
        if spotifyOnStart { Spotify.start(playlist: spotifyPlaylist) }
    }

    // Accepts a bare code or a whole invite message. Returns an error, or nil when joined.
    func join(_ text: String) -> String? {
        let invite = parseInvite(text)
        switch decode(invite.code ?? text) {
        case .ok(let s):
            set(s, paused: nil)
            codeChanged = false
            jamLink = invite.link
            if let link = invite.link {
                Spotify.open(link)  // join their Jam
            } else if spotifyOnStart {
                Spotify.start(playlist: spotifyPlaylist)
            }
            return nil
        case .fail(let error):
            return error
        }
    }

    func togglePause() {
        guard let s = session else { return }
        let t = Date().timeIntervalSince1970
        if let p = pausedAt {
            set(resumed(s, pausedAt: p, now: t), paused: nil)
        } else {
            set(s, paused: t.rounded(.down))
        }
        codeChanged = true
    }

    func skip() {
        guard let s = session else { return }
        set(skipped(s, at: effectiveNow.rounded(.down)), paused: pausedAt)
        codeChanged = true
    }

    func restart() {
        guard let s = session else { return }
        let jam = jamLink
        start(focus: s.focus, brk: s.brk, rounds: s.rounds)
        jamLink = jam
    }

    func end() {
        session = nil
        pausedAt = nil
        jamLink = nil
        lastPhaseKey = nil
        codeChanged = false
        defaults.removeObject(forKey: Key.code)
        defaults.removeObject(forKey: Key.pausedAt)
        reschedule()
        updateAmbience()
        broadcast()
    }

    func broadcast() {
        DistributedNotificationCenter.default().postNotificationName(
            Broadcast.state, object: nil,
            userInfo: Broadcast.info(session: session, pausedAt: pausedAt), deliverImmediately: true)
    }

    // Pause, skip and end from another app (Vorssaint's notch buttons).
    func handle(_ command: Broadcast.Command) {
        switch command {
        case .start(let focus, let brk, let rounds):
            // Starting from Vorssaint's pomodoro: also make it the setup shown here.
            defaults.set(focus, forKey: "setupFocus")
            defaults.set(brk, forKey: "setupBreak")
            defaults.set(rounds, forKey: "setupRounds")
            start(focus: focus, brk: brk, rounds: rounds)
        case .togglePause: if session != nil { togglePause() }
        case .skip: if session != nil { skip() }
        case .end: if session != nil { end() }
        case .unknown: break
        }
    }

    // Lets listeners know Study Timer is gone, so they stop sending it commands.
    func broadcastQuit() {
        DistributedNotificationCenter.default().postNotificationName(
            Broadcast.state, object: nil, userInfo: ["active": false, "quitting": true], deliverImmediately: true)
    }

    func copyCode() {
        guard let c = code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(inviteText(code: c, jam: jamLink), forType: .string)
        codeChanged = false
    }

    // Returns false when the clipboard has no Spotify link.
    func pasteJamLink() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string),
              let link = parseInvite(text).link else { return false }
        jamLink = link
        return true
    }

    func addPreset(focus: Int, brk: Int, rounds: Int) {
        let p = Preset(focus: focus, brk: brk, rounds: rounds)
        guard !presets.contains(p), presets.count < maxPresets else { return }
        presets.append(p)
    }
    func deletePreset(_ p: Preset) {
        presets.removeAll { $0 == p }
        if presets.isEmpty { presets = defaultPresets }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func set(_ s: Session, paused: Double?) {
        session = s
        pausedAt = paused
        lastPhaseKey = nil
        warnArmed = nil
        defaults.set(encode(s), forKey: Key.code)
        if let p = paused { defaults.set(p, forKey: Key.pausedAt) } else { defaults.removeObject(forKey: Key.pausedAt) }
        reschedule()
        updateAmbience()
        broadcast()
    }

    // Called every half second.
    func tick() {
        now = Date().timeIntervalSince1970
        keepAwakeForTimers()
        updateAmbience()
        guard let s = session, let p = phase else { lastPhaseKey = nil; return }

        // Chimes and Spotify follow phase changes (not the first tick after
        // launch, start, join or skip, so nothing rings unexpectedly).
        let key = "\(p.state)-\(p.round)"
        if let last = lastPhaseKey, last != key {
            switch p.state {
            case .focus:
                if alerts.contains(.focus) { playChime(chime(for: .focus), volume: chimeVolume) }
                if spotifyPauseOnBreak { Spotify.play() }
            case .brk:
                if alerts.contains(.brk) { playChime(chime(for: .brk), volume: chimeVolume) }
                if spotifyPauseOnBreak { Spotify.pause() }
            case .finished:
                if alerts.contains(.done) { playChime(chime(for: .done), volume: chimeVolume) }
                if spotifyPauseOnBreak { Spotify.pause() }
            case .notStarted:
                break
            }
        }
        lastPhaseKey = key

        // 1-minute warnings (before a break, and before a break ends), only
        // if we saw this phase with more than a minute left.
        if !isPaused, p.state == .focus || p.state == .brk {
            let kind: ChimeEvent = p.state == .focus ? .focusWarning : .warning
            let length = p.state == .focus ? s.focus : s.brk
            if alerts.contains(kind) && length >= 3 {
                if p.remaining > 60 {
                    warnArmed = key
                } else if warnArmed == key {
                    playChime(chime(for: kind), volume: chimeVolume)
                    warnArmed = nil
                }
            }
        }
    }

    private func updateAmbience() {
        var level: Float = 0
        if let p = phase, !isPaused, p.state == .focus || (p.state == .brk && ambientInBreaks) {
            level = Float(ambientVolume)
        }
        ambience.update(kind: ambient, level: level)
    }

    // macOS slows timers in background apps (App Nap). During a session that
    // would make chimes late, so ask it not to while a session is running.
    private func keepAwakeForTimers() {
        if session != nil, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Study session timer")
        } else if session == nil, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // ----- Notifications -----
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationsAllowed = granted }
        }
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in self.notificationsAllowed = ok }
        }
    }

    func setAlert(_ kind: ChimeEvent, _ on: Bool) {
        if on { alerts.insert(kind) } else { alerts.remove(kind) }
    }

    // ----- What notifications look like -----
    func text(for kind: ChimeEvent) -> AlertText { alertTexts[kind] ?? kind.defaultText }

    func setText(_ text: AlertText, for kind: ChimeEvent) {
        alertTexts[kind] = text == kind.defaultText ? nil : text
    }

    func resetLook(_ kind: ChimeEvent) {
        alertTexts[kind] = nil
        removePicture(for: kind)
    }

    static let pictureFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StudyTimerBar/Pictures", isDirectory: true)
    static func pictureURL(_ kind: ChimeEvent) -> URL {
        pictureFolder.appendingPathComponent("\(kind.rawValue).png")
    }

    /// Saves a small copy of the picture (so notifications stay light).
    func setPicture(from url: URL, for kind: ChimeEvent, choice: String = "custom") {
        guard let image = NSImage(contentsOf: url), let png = pngThumbnail(image, maxSide: 400) else { return }
        try? FileManager.default.createDirectory(at: Self.pictureFolder, withIntermediateDirectories: true)
        guard (try? png.write(to: Self.pictureURL(kind), options: .atomic)) != nil else { return }
        pictures[kind] = NSImage(data: png)
        pictureChoices[kind] = choice
        reschedule()
    }

    func useBuiltInPicture(_ id: String, for kind: ChimeEvent) {
        guard let url = builtInPictureURL(id) else { return }
        setPicture(from: url, for: kind, choice: id)
    }

    func removePicture(for kind: ChimeEvent) {
        try? FileManager.default.removeItem(at: Self.pictureURL(kind))
        pictureChoices[kind] = nil
        if pictures.removeValue(forKey: kind) != nil { reschedule() }
    }

    // macOS moves an attachment's file into its own store, so each
    // notification gets its own copy of the picture.
    private func attachment(for kind: ChimeEvent) -> UNNotificationAttachment? {
        guard pictures[kind] != nil else { return nil }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("studytimer-\(UUID().uuidString).png")
        guard (try? FileManager.default.copyItem(at: Self.pictureURL(kind), to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: kind.rawValue, url: copy,
                                             options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
    }

    /// This alert as it would read now: the next one in your session, or one
    /// from a sample 25/5 ×4 session.
    func sampleAlert(_ kind: ChimeEvent) -> AlertEvent {
        let t = Date().timeIntervalSince1970
        let s = session ?? Session(focus: 25, brk: 5, rounds: 4, startUtc: t)
        let events = alertSchedule(s, on: [kind], texts: alertTexts)
        return events.first { $0.at > t } ?? events.first
            ?? AlertEvent(kind: kind, at: t, title: text(for: kind).title, body: text(for: kind).body)
    }

    /// Pops up the real notification now, with its chime.
    func sendTest(_ kind: ChimeEvent) {
        let e = sampleAlert(kind)
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.body = e.body
        if let a = attachment(for: kind) { content.attachments = [a] }
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        testProblem = nil
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationsAllowed = granted }
            guard granted else { return }
            center.add(request) { error in
                guard let error else { return }
                NSLog("Study Timer: test notification failed: \(error)")
                Task { @MainActor in self.testProblem = "macOS didn't take the notification: \(error.localizedDescription)" }
            }
        }
        playChime(chime(for: kind), volume: chimeVolume)
    }

    // Typing a new wording reschedules once you pause, not on every key.
    private var rescheduleWork: DispatchWorkItem?
    private func rescheduleSoon() {
        rescheduleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reschedule() } }
        rescheduleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // Every alert is scheduled ahead of time, so it arrives on time even if
    // the Mac is busy. They're silent: the app plays your chosen chimes.
    func reschedule() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard notificationsOn, let s = session, pausedAt == nil else { return }

        let t = Date().timeIntervalSince1970
        for (n, e) in alertSchedule(s, on: alerts, texts: alertTexts).enumerated() where e.at - t > 0.5 {
            let content = UNMutableNotificationContent()
            content.title = e.title
            content.body = e.body
            if let a = attachment(for: e.kind) { content.attachments = [a] }
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                        from: Date(timeIntervalSince1970: e.at))
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: "phase-\(n)", content: content, trigger: trigger))
        }
    }
}

// Show banners even while the panel is open.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

// ===== Look: themes =====

func rgb(_ hex: UInt32) -> (Double, Double, Double) {
    (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
}
func color(_ hex: UInt32, _ alpha: Double = 1) -> Color {
    let (r, g, b) = rgb(hex)
    return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
}
func nsColor(_ hex: UInt32, _ alpha: Double = 1) -> NSColor {
    let (r, g, b) = rgb(hex)
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

// The 8 notification pictures that come with the app (menubar/pictures).
struct BuiltInPicture: Identifiable {
    let id: String
    let title: String
}
let builtInPictures = [
    BuiltInPicture(id: "aura", title: "aura ring"),
    BuiltInPicture(id: "coffee", title: "coffee"),
    BuiltInPicture(id: "hourglass", title: "hourglass"),
    BuiltInPicture(id: "moon", title: "moon"),
    BuiltInPicture(id: "sprout", title: "sprout"),
    BuiltInPicture(id: "sunrise", title: "sunrise"),
    BuiltInPicture(id: "sparkle", title: "sparkle"),
    BuiltInPicture(id: "waves", title: "waves"),
]

func builtInPictureURL(_ id: String) -> URL? {
    Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Pictures")
}

// Small copies for the picture menu.
let builtInPictureIcons: [String: NSImage] = Dictionary(uniqueKeysWithValues: builtInPictures.compactMap { p in
    guard let url = builtInPictureURL(p.id), let image = NSImage(contentsOf: url) else { return nil }
    image.size = NSSize(width: 20, height: 20)
    return (p.id, image)
})

/// A PNG of `image`, scaled down so its longer side is at most `maxSide` pixels.
func pngThumbnail(_ image: NSImage, maxSide: CGFloat) -> Data? {
    guard let source = image.representations.first, source.pixelsWide > 0 || image.size.width > 0 else { return nil }
    let w0 = CGFloat(source.pixelsWide > 0 ? source.pixelsWide : Int(image.size.width))
    let h0 = CGFloat(source.pixelsHigh > 0 ? source.pixelsHigh : Int(image.size.height))
    let scale = min(1, maxSide / max(w0, h0))
    let w = max(1, Int((w0 * scale).rounded())), h = max(1, Int((h0 * scale).rounded()))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// A theme changes colors and the aura; layout and fonts stay the same.
struct Theme: Identifiable {
    let id: String
    let name: String
    let dark: Bool
    let bg: UInt32
    let ink: UInt32
    let muted: UInt32
    let line: UInt32        // hairlines, tracks and outlines use this at low alpha
    let lineAlpha: Double
    let glass: UInt32       // translucent fills
    let glassAlpha: Double
    let wait: UInt32        // phase colors
    let focus: UInt32
    let brk: UInt32
    let done: UInt32
    let warn: UInt32
    let glow: Double        // aura strength, 0...1
    let iridescent: Bool    // Prism: rainbow ring, hue-drifting aura
    let templateIcon: Bool  // Mono: menu bar icon follows the menu bar's own color
}

let themes: [Theme] = [
    Theme(id: "aura", name: "Aura", dark: true, bg: 0x0E1433, ink: 0xEEF1FF, muted: 0xA9B2D6,
          line: 0xAFC3FF, lineAlpha: 0.14, glass: 0xFFFFFF, glassAlpha: 0.05,
          wait: 0xB9A7FF, focus: 0x8CCBFF, brk: 0x7FE6C5, done: 0xFFD58C, warn: 0xFFC46B,
          glow: 1.0, iridescent: false, templateIcon: false),
    Theme(id: "cloud", name: "Cloud", dark: false, bg: 0xF7F9FC, ink: 0x17203A, muted: 0x5A6482,
          line: 0x17203A, lineAlpha: 0.10, glass: 0x17203A, glassAlpha: 0.04,
          wait: 0x8B74E0, focus: 0x3D8BDA, brk: 0x23A487, done: 0xC8922A, warn: 0xA86400,
          glow: 0.6, iridescent: false, templateIcon: false),
    Theme(id: "mochi", name: "Mochi", dark: false, bg: 0xFFF3EE, ink: 0x4A3844, muted: 0x7D6673,
          line: 0x4A3844, lineAlpha: 0.10, glass: 0x4A3844, glassAlpha: 0.04,
          wait: 0xC5ADEE, focus: 0x93C2EE, brk: 0x9AD8B6, done: 0xF0C27E, warn: 0xA86400,
          glow: 0.8, iridescent: false, templateIcon: false),
    Theme(id: "mono", name: "Mono", dark: true, bg: 0x0B0B0B, ink: 0xF2F2F2, muted: 0x9C9C9C,
          line: 0xFFFFFF, lineAlpha: 0.12, glass: 0xFFFFFF, glassAlpha: 0.05,
          wait: 0x6E6E6E, focus: 0xF2F2F2, brk: 0xA8A8A8, done: 0xF2F2F2, warn: 0xE0E0E0,
          glow: 0.25, iridescent: false, templateIcon: true),
    Theme(id: "prism", name: "Prism", dark: true, bg: 0x0D0B1A, ink: 0xF3EFFF, muted: 0xADA6C9,
          line: 0xC8B8FF, lineAlpha: 0.14, glass: 0xFFFFFF, glassAlpha: 0.05,
          wait: 0xC9A7FF, focus: 0x8CCBFF, brk: 0x7FE6C5, done: 0xFFD58C, warn: 0xFFC46B,
          glow: 1.0, iridescent: true, templateIcon: false),
]

// Set by TimerModel when the theme changes; every view reads colors through Aura.
var currentTheme: Theme = themes[0]

let prismColors = [0x8CCBFF, 0xC9A7FF, 0xFFB3D9, 0xFFD58C, 0x7FE6C5, 0x8CCBFF].map { color(UInt32($0)) }

enum Aura {
    static var t: Theme { currentTheme }
    static var bg: Color { color(t.bg) }
    static var ink: Color { color(t.ink) }
    static var muted: Color { color(t.muted) }
    static var line: Color { color(t.line, t.lineAlpha) }
    static var lineStrong: Color { color(t.line, t.lineAlpha * 1.6) }
    static var divider: Color { color(t.line, t.lineAlpha * 0.7) }
    static var track: Color { color(t.line, t.lineAlpha * 0.85) }
    static var glass: Color { color(t.glass, t.glassAlpha) }
    static var warn: Color { color(t.warn) }

    static func hex(_ s: PhaseState) -> UInt32 {
        switch s {
        case .notStarted: return t.wait
        case .focus: return t.focus
        case .brk: return t.brk
        case .finished: return t.done
        }
    }
    static func tint(_ s: PhaseState) -> Color { color(hex(s)) }

    static func glowTint(_ s: PhaseState, elapsed: Double) -> Color {
        guard t.iridescent else { return tint(s) }
        var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        nsColor(hex(s)).getHue(&h, saturation: &sat, brightness: &br, alpha: &a)
        var nh = (Double(h) + hueDrift(elapsed: elapsed) / 360).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }
        return Color(hue: nh, saturation: Double(sat), brightness: Double(br))
    }

    // Fonts ship inside the app (see build.sh). If one is missing, SwiftUI
    // falls back to the system font, so the app still works.
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", fixedSize: size)
    }
    static func display(_ size: CGFloat, heavy: Bool = true) -> Font {
        .custom(heavy ? "Syne-ExtraBold" : "Syne-Bold", fixedSize: size)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "DMSans-Medium"
        case .semibold, .bold, .heavy, .black: name = "DMSans-SemiBold"
        default: name = "DMSans-Regular"
        }
        return .custom(name, fixedSize: size)
    }
}

func registerBundledFonts() {
    guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
          let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

// ----- Reusable pieces -----

// The aura stays inside the panel at its fullest breath (228 × 1.04 plus the
// blur is under the panel's 320 points), so the panel's edges never seem to
// move as it breathes. A wider glow got cut off at the edges.
struct Glow: View {
    let tint: Color
    let breath: Double   // 0...1
    let dimmed: Bool
    var size: CGFloat = 228

    var body: some View {
        let strength = Aura.t.glow
        Circle()
            .fill(RadialGradient(gradient: Gradient(colors: [tint, tint.opacity(0)]),
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .scaleEffect(dimmed ? 0.9 : 0.9 + 0.14 * breath)
            .opacity((dimmed ? 0.2 : 0.35 + 0.4 * breath) * strength)
            .blur(radius: 18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ProgressRing: View {
    let progress: Double
    let tint: Color
    var diameter: CGFloat = 192
    var lineWidth: CGFloat = 8
    var showHead = true

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            Circle().stroke(Aura.track, lineWidth: lineWidth)
            Group {
                if Aura.t.iridescent {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(AngularGradient(gradient: Gradient(colors: prismColors), center: .center), style: style)
                } else {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tint, style: style)
                }
            }
            .rotationEffect(.degrees(-90))
            .shadow(color: tint.opacity(0.7 * Aura.t.glow), radius: 6)
            if showHead {
                Circle()
                    .fill(Aura.ink)
                    .frame(width: lineWidth + 6, height: lineWidth + 6)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(360 * progress))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The setup dial: one round from the top, focus (blue) then break (mint),
/// on a two-hour face (four hours for longer rounds). Hover or click it to
/// show a handle at the end of each; drag anywhere on it to move the nearer
/// one, which follows your pointer round the ring.
struct DialRing: View {
    @Binding var focus: Int
    @Binding var brk: Int
    var size: CGFloat = 108

    private struct Drag {
        let handle: DialHandle
        let lap: Double          // fixed for the whole drag, so the face doesn't rescale under you
        let startPosition: Double
        let startPointer: Double
        var pointer: Double      // unwrapped, so crossing the top keeps counting
    }

    @State private var hovering = false
    @State private var tapped = false
    @State private var drag: Drag?

    private let lineWidth: CGFloat = 7
    private var radius: CGFloat { size / 2 - 4 - lineWidth / 2 }

    var body: some View {
        let lap = drag?.lap ?? dialLap(focus: focus, brk: brk)
        let focusEnd = Double(focus) / lap
        let breakEnd = min(1, Double(focus + brk) / lap)
        let showHandles = hovering || tapped || drag != nil
        let showingBreak = drag?.handle == .brk
        ZStack {
            Circle().stroke(Aura.line, lineWidth: lineWidth)
                .padding(4 + lineWidth / 2)
            arc(from: 0, to: focusEnd, tint: Aura.tint(.focus))
            arc(from: focusEnd, to: breakEnd, tint: Aura.tint(.brk))
            if showHandles {
                handle(at: focusEnd, tint: Aura.tint(.focus), active: drag?.handle == .focus)
                handle(at: breakEnd, tint: Aura.tint(.brk), active: showingBreak)
            }
            VStack(spacing: 0) {
                Text("\(showingBreak ? brk : focus)").font(Aura.mono(26)).foregroundStyle(Aura.ink)
                Text(showingBreak ? "min break" : "min focus")
                    .font(Aura.body(11))
                    .foregroundStyle(showingBreak ? Aura.tint(.brk) : Aura.muted)
            }
            .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.15), value: showHandles)
        .contentShape(Circle())
        .onHover { inside in
            hovering = inside
            if !inside { tapped = false }
            if drag == nil { (inside ? NSCursor.openHand : NSCursor.arrow).set() }
        }
        .onDisappear { if hovering { NSCursor.arrow.set() } }
        .onTapGesture { tapped.toggle() }
        .gesture(dragGesture)
        .help("Drag the ends of the ring to set focus and break")
    }

    private func arc(from: Double, to: Double, tint: Color) -> some View {
        Circle()
            .trim(from: from, to: max(from, to))
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(4 + lineWidth / 2)
    }

    private func handle(at fraction: Double, tint: Color, active: Bool) -> some View {
        let a = fraction * 2 * Double.pi
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(tint, lineWidth: 3))
            .frame(width: active ? 18 : 15, height: active ? 18 : 15)
            .shadow(color: tint.opacity(0.7), radius: active ? 6 : 3)
            .position(x: size / 2 + radius * CGFloat(sin(a)), y: size / 2 - radius * CGFloat(cos(a)))
            .transition(.scale.combined(with: .opacity))
            .allowsHitTesting(false)
    }

    private func fraction(_ p: CGPoint) -> Double {
        dialFraction(dx: Double(p.x - size / 2), dy: Double(p.y - size / 2))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { g in
                var d: Drag
                if let current = drag {
                    d = current
                } else {
                    let lap = dialLap(focus: focus, brk: brk)
                    let start = fraction(g.startLocation)
                    let focusEnd = Double(focus) / lap, breakEnd = Double(focus + brk) / lap
                    let h = nearestDialHandle(pointer: start, focusEnd: focusEnd, breakEnd: breakEnd)
                    d = Drag(handle: h, lap: lap, startPosition: h == .focus ? focusEnd : breakEnd,
                             startPointer: start, pointer: start)
                    NSCursor.closedHand.set()
                }
                d.pointer = dialUnwrap(d.pointer, to: fraction(g.location))
                drag = d
                let v = dialValues(d.handle, position: d.startPosition + (d.pointer - d.startPointer),
                                   focus: focus, brk: brk, lap: d.lap)
                guard v.focus != focus || v.brk != brk else { return }
                focus = v.focus
                brk = v.brk
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            .onEnded { _ in
                drag = nil
                (hovering ? NSCursor.openHand : NSCursor.arrow).set()
            }
    }
}

struct GlassButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Aura.ink)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Aura.glass))
                .overlay(Circle().strokeBorder(Aura.lineStrong, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct InkButton: View {
    let title: String
    let icon: String
    var height: CGFloat = 46
    var glow: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(Aura.body(14, .semibold))
            }
            .foregroundStyle(Aura.bg)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(Aura.ink))
            .shadow(color: (glow ?? .clear).opacity(0.45), radius: 12)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PillButton: View {
    let title: String
    var height: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Aura.body(12, .semibold))
                .foregroundStyle(Aura.ink)
                .padding(.horizontal, 14)
                .frame(height: height)
                .overlay(Capsule().strokeBorder(Aura.lineStrong, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 14).fill(Aura.glass))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Aura.line, lineWidth: 1))
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Aura.divider).frame(height: 1) }
}

// ===== Panel =====

let panelWidth: CGFloat = 320

struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @ObservedObject var model: TimerModel
    /// The panel's height, whenever it changes. The popover is sized from
    /// this (never from SwiftUI's own sizing), so its width can't change.
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.showSettings {
                if let kind = model.editingAlert {
                    AlertEditor(model: model, kind: kind)
                } else {
                    SettingsView(model: model)
                }
            } else {
                if let s = model.session {
                    RunningView(model: model, session: s)
                } else {
                    SetupView(model: model)
                }
                if model.notificationsOn && !model.notificationsAllowed {
                    NotificationWarning()
                }
                Footer(model: model)
            }
        }
        .padding(22)
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true) // its own height, whatever the window's
        .background(GeometryReader { g in
            Color.clear.preference(key: PanelHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { h in onHeight(h) }
        // Pinned to the top, so the frame the window takes to catch up never shows.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Aura.bg)
        .environment(\.colorScheme, Aura.t.dark ? .dark : .light)
        .tint(Aura.tint(.focus))
        .id(model.themeID) // rebuild every view when the theme changes
    }
}

struct RunningView: View {
    @ObservedObject var model: TimerModel
    let session: Session
    @State private var copied = false
    @State private var jamHint: String?

    var body: some View {
        // Redraws ~30 times a second while the panel is open, so the ring and
        // aura move smoothly. Stops while paused.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.isPaused)) { ctx in
            let t = ctx.date.timeIntervalSince1970
            let eff = model.pausedAt ?? t
            let p = getPhase(session, now: eff)
            content(p, eff: eff, now: t)
        }
    }

    @ViewBuilder
    private func content(_ p: PhaseInfo, eff: Double, now: Double) -> some View {
        let tint = Aura.tint(p.state)
        let active = p.state == .focus || p.state == .brk
        let progress = phaseProgress(session, p)
        let b = breath(elapsed: eff - session.startUtc, remaining: p.remaining, active: active)

        VStack(spacing: 18) {
            HStack {
                Text(label(p)).font(Aura.display(13, heavy: false)).foregroundStyle(Aura.ink)
                Spacer()
                Text(String(format: "round %02d / %02d", max(1, p.round), session.rounds))
                    .font(Aura.mono(11)).foregroundStyle(Aura.muted)
            }

            ZStack {
                Glow(tint: Aura.glowTint(p.state, elapsed: eff - session.startUtc), breath: b, dimmed: model.isPaused)
                ProgressRing(progress: progress, tint: tint, showHead: active)
                VStack(spacing: 6) {
                    if p.state == .finished {
                        Text("done").font(Aura.display(34)).foregroundStyle(Aura.ink)
                    } else {
                        Text(formatClock(p.remaining))
                            .font(Aura.mono(46))
                            .kerning(-1.5)
                            .monospacedDigit()
                            .foregroundStyle(model.isPaused ? Aura.muted : Aura.ink)
                    }
                    Text(nextLine(p, now: now)).font(Aura.body(12)).foregroundStyle(Aura.muted)
                }
            }
            .frame(width: 220, height: 220)
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                ForEach(1...session.rounds, id: \.self) { r in
                    let done = r < p.round || p.state == .finished || (r == p.round && p.state == .brk)
                    let current = r == p.round && p.state == .focus
                    Circle()
                        .fill(done ? Aura.ink : (current ? tint : Color.clear))
                        .overlay(Circle().strokeBorder(done || current ? Color.clear : Aura.lineStrong, lineWidth: 1))
                        .frame(width: 10, height: 10)
                        .shadow(color: current ? tint : .clear, radius: 5)
                }
            }
            .accessibilityHidden(true)

            if p.state == .finished {
                HStack(spacing: 8) {
                    InkButton(title: "go again", icon: "arrow.clockwise", glow: tint) { model.restart() }
                        .keyboardShortcut(.defaultAction)
                    PillButton(title: "new", height: 46) { model.end() }
                }
            } else {
                HStack(spacing: 8) {
                    InkButton(title: model.isPaused ? "resume" : "pause",
                              icon: model.isPaused ? "play.fill" : "pause.fill") { model.togglePause() }
                        .keyboardShortcut(.space, modifiers: [])
                    GlassButton(icon: "forward.end.fill",
                                help: p.state == .notStarted ? "Start now" : "Skip to next phase") { model.skip() }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    GlassButton(icon: "stop.fill", help: "End session") { model.end() }
                }

                if let code = model.code {
                    Card {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.codeChanged ? "code changed, send the new one" : "study with someone")
                                        .font(Aura.body(11))
                                        .foregroundStyle(model.codeChanged ? Aura.warn : Aura.muted)
                                    Text(code).font(Aura.mono(12)).foregroundStyle(Aura.ink).textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                                PillButton(title: copied ? "copied" : "copy") {
                                    model.copyCode()
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                                }
                                .help(model.jamLink == nil ? "Copy the share code" : "Copy the share code and your Jam link")
                            }
                            .padding(.vertical, 10).padding(.leading, 14).padding(.trailing, 10)
                            RowDivider()
                            jamRow
                        }
                    }
                }
            }
        }
    }

    // Listen together: Spotify can't be told to start a Jam, so this opens
    // Spotify, and shares the Jam link you paste here along with the code.
    private var jamRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("listen together").font(Aura.body(11)).foregroundStyle(Aura.muted)
                Text(jamHint ?? (model.jamLink == nil ? "start a Jam in Spotify, copy its link" : "jam link shared with your code"))
                    .font(Aura.body(11))
                    .foregroundStyle(jamHint == nil ? Aura.ink : Aura.warn)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let link = model.jamLink {
                PillButton(title: "open") { Spotify.open(link) }
                Button { model.jamLink = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Aura.muted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove the Jam link")
                .accessibilityLabel("Remove the Jam link")
            } else {
                Button { Spotify.openApp() } label: {
                    Image(systemName: "music.note").font(.system(size: 12, weight: .semibold)).foregroundStyle(Aura.ink)
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(Aura.lineStrong, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Open Spotify")
                .accessibilityLabel("Open Spotify")
                PillButton(title: "paste") {
                    if model.pasteJamLink() {
                        jamHint = nil
                    } else {
                        jamHint = "copy the Jam link in Spotify first"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { jamHint = nil }
                    }
                }
                .help("Paste the Jam link from your clipboard")
            }
        }
        .padding(.vertical, 10).padding(.leading, 14).padding(.trailing, 10)
    }

    private func label(_ p: PhaseInfo) -> String {
        if model.isPaused && p.state != .finished { return "paused" }
        switch p.state {
        case .notStarted: return "starts in"
        case .focus: return "focus"
        case .brk: return "break"
        case .finished: return "session complete"
        }
    }

    private func nextLine(_ p: PhaseInfo, now: Double) -> String {
        if model.isPaused && p.state != .finished { return "space to resume" }
        let ends = clockTime(now + p.remaining)
        switch p.state {
        case .notStarted: return "starts at \(clockTime(session.startUtc))"
        case .focus: return p.round == p.totalRounds ? "ends at \(ends)" : "\(session.brk) min break at \(ends)"
        case .brk: return "round \(p.round + 1) at \(ends)"
        case .finished: return "\(formatDuration(Double(session.rounds * session.focus * 60))) focused"
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: TimerModel
    @AppStorage("setupFocus") private var focus = 25
    @AppStorage("setupBreak") private var brk = 5
    @AppStorage("setupRounds") private var rounds = 4
    @State private var joinText = ""
    @State private var joinError: String?
    private let focusRange = 5...180
    private let breakRange = 1...60

    var body: some View {
        let preview = Session(focus: focus, brk: brk, rounds: rounds, startUtc: model.now)
        let current = Preset(focus: focus, brk: brk, rounds: rounds)
        let canSave = !model.presets.contains(current) && model.presets.count < maxPresets
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                DialRing(focus: $focus, brk: $brk)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("One round: \(focus) minutes focus, \(brk) minutes break")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: focus = min(focusRange.upperBound, focus + 5)
                        case .decrement: focus = max(focusRange.lowerBound, focus - 5)
                        @unknown default: break
                        }
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text("lock in").font(Aura.display(24)).foregroundStyle(Aura.ink)
                    Text("\(rounds) rounds · \(formatDuration(totalSeconds(preview)))\ndone around \(clockTime(model.now + totalSeconds(preview)))")
                        .font(Aura.body(12)).foregroundStyle(Aura.muted).lineSpacing(3)
                }
            }

            // Presets: click to use, right-click to delete, + to save the current setup.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(model.presets) { p in
                    let selected = p == current
                    Button {
                        focus = p.focus; brk = p.brk; rounds = p.rounds
                    } label: {
                        VStack(spacing: 0) {
                            Text("\(p.focus) / \(p.brk)").font(Aura.body(12, selected ? .semibold : .regular))
                            Text("×\(p.rounds)").font(Aura.mono(9)).opacity(0.7)
                        }
                        .foregroundStyle(selected ? Aura.bg : Aura.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(selected ? Aura.ink : Aura.glass))
                        .overlay(Capsule().strokeBorder(selected ? Color.clear : Aura.lineStrong, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help("Right-click to delete")
                    .contextMenu {
                        Button("Delete preset") { model.deletePreset(p) }
                    }
                }
                if canSave {
                    Button {
                        model.addPreset(focus: focus, brk: brk, rounds: rounds)
                    } label: {
                        Label("save", systemImage: "plus")
                            .font(Aura.body(12))
                            .foregroundStyle(Aura.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .overlay(Capsule().strokeBorder(Aura.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Save \(focus)/\(brk) ×\(rounds) as a preset")
                }
            }

            Card {
                VStack(spacing: 0) {
                    StepRow(dot: Aura.tint(.focus), label: "focus", value: $focus, range: focusRange, step: 5, unit: "min")
                    RowDivider()
                    StepRow(dot: Aura.tint(.brk), label: "break", value: $brk, range: breakRange, step: 1, unit: "min")
                    RowDivider()
                    StepRow(dot: nil, label: "rounds", value: $rounds, range: 1...12, step: 1, unit: "")
                }
            }

            InkButton(title: "start focusing", icon: "play.fill", height: 48, glow: Aura.tint(.focus)) {
                model.start(focus: focus, brk: brk, rounds: rounds)
            }
            .keyboardShortcut(.defaultAction)

            VStack(alignment: .leading, spacing: 6) {
                Text("join a friend").font(Aura.body(12)).foregroundStyle(Aura.muted)
                HStack(spacing: 6) {
                    TextField("paste share code", text: $joinText)
                        .textFieldStyle(.plain)
                        .font(Aura.mono(12))
                        .foregroundStyle(Aura.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Capsule().fill(Aura.glass))
                        .overlay(Capsule().strokeBorder(Aura.lineStrong, lineWidth: 1))
                        .onSubmit(join)
                    Button {
                        joinText = NSPasteboard.general.string(forType: .string) ?? ""
                        join()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Aura.ink)
                            .frame(width: 40, height: 40)
                            .overlay(Circle().strokeBorder(Aura.lineStrong, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Join the code on your clipboard")
                    .accessibilityLabel("Join the code on your clipboard")
                    PillButton(title: "join", height: 40, action: join)
                }
                if let e = joinError {
                    Text(e).font(Aura.body(11)).foregroundStyle(Aura.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .background(alignment: .topLeading) {
            Glow(tint: Aura.tint(.focus), breath: 0.5, dimmed: false, size: 240)
                .offset(x: -80, y: -90)
        }
    }

    private func join() {
        joinError = model.join(joinText)
        if joinError == nil { joinText = "" }
    }
}

struct StepRow: View {
    let dot: Color?
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                if let d = dot {
                    Circle().fill(d).frame(width: 8, height: 8)
                } else {
                    Circle().strokeBorder(Aura.muted, lineWidth: 1).frame(width: 8, height: 8)
                }
                Text(label).font(Aura.body(13)).foregroundStyle(Aura.ink)
            }
            Spacer()
            HStack(spacing: 4) {
                round("minus", "Less \(label)") { value = max(range.lowerBound, value - step) }
                    .disabled(value <= range.lowerBound)
                Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                    .font(Aura.mono(13)).foregroundStyle(Aura.ink)
                    .frame(width: 64)
                round("plus", "More \(label)") { value = min(range.upperBound, value + step) }
                    .disabled(value >= range.upperBound)
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
    }

    private func round(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Aura.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Aura.glass))
                .overlay(Circle().strokeBorder(Aura.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
    }
}

// ===== Settings page =====

struct SettingsView: View {
    @ObservedObject var model: TimerModel
    @State private var chimeFailed: String?   // a chime macOS wouldn't play

    private func test(_ name: String) {
        chimeFailed = playChime(name, volume: model.chimeVolume) ? nil : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("settings").font(Aura.display(20)).foregroundStyle(Aura.ink)
                Spacer()
                PillButton(title: "done") { model.showSettings = false }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("theme") { themePicker }

                    section("background sound") {
                        row("sound") {
                            Picker("Background sound", selection: $model.ambient) {
                                ForEach(AmbientKind.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.menu).fixedSize()
                        }
                        RowDivider()
                        row("volume") {
                            Slider(value: $model.ambientVolume, in: 0...1).frame(width: 130)
                                .accessibilityLabel("Background sound volume")
                        }
                        RowDivider()
                        row("also during breaks") { toggle($model.ambientInBreaks, "Background sound during breaks") }
                    }

                    section("notifications") {
                        row("pop-up notifications") { toggle($model.notificationsOn, "Pop-up notifications") }
                        ForEach(ChimeEvent.allCases) { e in
                            RowDivider()
                            row(e.title) {
                                Button { model.editingAlert = e } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(model.alertTexts[e] != nil || model.pictures[e] != nil ? Aura.tint(.focus) : Aura.muted)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Change what this notification says, or add a picture")
                                .accessibilityLabel("Customize \(e.title)")
                                toggle(Binding(get: { model.alerts.contains(e) }, set: { model.setAlert(e, $0) }),
                                       "Alert when: \(e.title)")
                            }
                        }
                        Text(model.notificationsOn
                             ? "Each alert pops up and plays its chime. Click the pencil to change its words or add a picture."
                             : "Pop-ups are off, so the alerts you keep on only play their chimes.")
                            .font(Aura.body(11)).foregroundStyle(Aura.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }

                    section("chimes") {
                        ForEach(ChimeEvent.allCases) { e in
                            row(e.title) {
                                Button { test(model.chime(for: e)) } label: {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Aura.muted)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Play this chime")
                                .accessibilityLabel("Play the \(e.title) chime")
                                Picker(e.title, selection: Binding(get: { model.chime(for: e) },
                                                                   set: { model.setChime($0, for: e); test($0) })) {
                                    ForEach(chimeSounds, id: \.self) { Text($0.lowercased()).tag($0) }
                                }
                                .labelsHidden().pickerStyle(.menu).fixedSize()
                            }
                            RowDivider()
                        }
                        row("volume") {
                            Slider(value: $model.chimeVolume, in: 0...1) { editing in
                                if !editing { test(model.chime(for: .focus)) }
                            }
                            .frame(width: 130)
                            .accessibilityLabel("Chime volume")
                        }
                        if let failed = chimeFailed {
                            Text("macOS didn't play \(failed.lowercased()). Check the output and volume in System Settings → Sound.")
                                .font(Aura.body(11)).foregroundStyle(Aura.warn)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.bottom, 10)
                        }
                    }

                    section("menu bar") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("show").font(Aura.body(13)).foregroundStyle(Aura.ink)
                            Picker("Menu bar shows", selection: $model.barStyle) {
                                ForEach(BarStyle.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented)
                            Text("time as").font(Aura.body(13)).foregroundStyle(Aura.ink).padding(.top, 4)
                            Picker("Menu bar time format", selection: $model.barMinutes) {
                                Text("18:42").tag(false)
                                Text("19m").tag(true)
                            }
                            .labelsHidden().pickerStyle(.segmented)
                        }
                        // Small, so "ring + time" fits: at full size its three equal
                        // segments need 268 pt of the card's 252, and Settings flipped
                        // between two widths as SwiftUI and AppKit disagreed on its size.
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading) // as wide as the other cards
                        .padding(12)
                    }

                    section("spotify") {
                        row("open when a session starts") { toggle($model.spotifyOnStart, "Open Spotify when a session starts") }
                        RowDivider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("playlist to play").font(Aura.body(13)).foregroundStyle(Aura.ink)
                            TextField("paste a playlist or album link", text: $model.spotifyPlaylist)
                                .textFieldStyle(.plain)
                                .font(Aura.mono(11))
                                .foregroundStyle(Aura.ink)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(Capsule().fill(Aura.glass))
                                .overlay(Capsule().strokeBorder(Aura.lineStrong, lineWidth: 1))
                            if !model.spotifyPlaylist.isEmpty && spotifyURI(from: model.spotifyPlaylist) == nil {
                                Text("that doesn't look like a Spotify link").font(Aura.body(11)).foregroundStyle(Aura.warn)
                            }
                        }
                        .padding(12)
                        RowDivider()
                        row("pause music on breaks") { toggle($model.spotifyPauseOnBreak, "Pause Spotify on breaks") }
                        Text(Spotify.installed
                             ? "The first time, macOS asks to let Study Timer control Spotify. Jams: start one in Spotify, then paste its link in the timer panel."
                             : "Spotify isn't installed, so links open in your browser.")
                            .font(Aura.body(11)).foregroundStyle(Aura.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.bottom, 12)
                    }

                    section("general") {
                        row("open at login") {
                            toggle(Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }), "Open at login")
                        }
                        RowDivider()
                        HStack {
                            Button("open web timer") { NSWorkspace.shared.open(webTimerURL) }
                                .buttonStyle(.plain).font(Aura.body(13)).foregroundStyle(Aura.ink)
                            Spacer()
                            Button("quit") { NSApp.terminate(nil) }
                                .buttonStyle(.plain).font(Aura.body(13)).foregroundStyle(Aura.muted)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 40)
                    }
                }
                .padding(.bottom, 20)
            }
            .frame(height: 470)
            // No scroll bar: the fade at the bottom shows there's more.
            .scrollIndicators(.never)
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
            })
        }
    }

    private var themePicker: some View {
        HStack(spacing: 0) {
            ForEach(themes) { th in
                let selected = th.id == model.themeID
                Button { model.themeID = th.id } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(color(th.bg))
                            Circle().trim(from: 0, to: 0.7)
                                .stroke(th.iridescent
                                        ? AnyShapeStyle(AngularGradient(gradient: Gradient(colors: prismColors), center: .center))
                                        : AnyShapeStyle(color(th.focus)),
                                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .padding(7)
                        }
                        .frame(width: 40, height: 40)
                        .overlay(Circle().strokeBorder(selected ? Aura.ink : Aura.lineStrong, lineWidth: selected ? 2 : 1))
                        Text(th.name.lowercased()).font(Aura.body(11, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Aura.ink : Aura.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(th.name) theme")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        let inner = content()
        return VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(Aura.mono(10)).tracking(1).foregroundStyle(Aura.muted)
            Card { VStack(spacing: 0) { inner } }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        let inner = control()
        return HStack(spacing: 8) {
            Text(label).font(Aura.body(13)).foregroundStyle(Aura.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            inner
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 40)
    }

    private func toggle(_ binding: Binding<Bool>, _ label: String) -> some View {
        Toggle(label, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

// ===== A notification's own page (Settings → pencil) =====

struct AlertEditor: View {
    @ObservedObject var model: TimerModel
    let kind: ChimeEvent
    @State private var sent = false

    var body: some View {
        let text = model.text(for: kind)
        let sample = model.sampleAlert(kind)
        let picture = model.pictures[kind]
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("notification").font(Aura.display(20)).foregroundStyle(Aura.ink)
                Spacer()
                PillButton(title: "back") { model.editingAlert = nil }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Text("for").font(Aura.body(13)).foregroundStyle(Aura.muted)
                        Picker("Notification", selection: Binding(get: { kind }, set: { model.editingAlert = $0 })) {
                            ForEach(ChimeEvent.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        Spacer(minLength: 0)
                    }

                    NotificationPreview(title: sample.title, message: sample.body, picture: picture)

                    VStack(alignment: .leading, spacing: 8) {
                        heading("words")
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                field("title", placeholder: kind.defaultText.title, lines: 1,
                                      text: Binding(get: { text.title },
                                                    set: { model.setText(AlertText(title: $0, body: model.text(for: kind).body), for: kind) }))
                                field("message", placeholder: kind.defaultText.body, lines: 4,
                                      text: Binding(get: { text.body },
                                                    set: { model.setText(AlertText(title: model.text(for: kind).title, body: $0), for: kind) }))
                                Text("click to add, it fills in when sent").font(Aura.body(11)).foregroundStyle(Aura.muted)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                                    ForEach(alertTokens) { t in
                                        Button { addToken(t.token) } label: {
                                            Text(t.token).font(Aura.mono(11)).foregroundStyle(Aura.ink)
                                                .frame(maxWidth: .infinity).frame(height: 28)
                                                .background(Capsule().fill(Aura.glass))
                                                .overlay(Capsule().strokeBorder(Aura.lineStrong, lineWidth: 1))
                                                .contentShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .help(t.meaning)
                                        .accessibilityLabel("Add \(t.token), \(t.meaning)")
                                    }
                                }
                            }
                            .padding(12)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        heading("picture")
                        Card {
                          VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Group {
                                    if let picture {
                                        Image(nsImage: picture).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(Aura.muted)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Aura.glass)
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Aura.line, lineWidth: 1))
                                .accessibilityHidden(true)
                                Text("shows on the right of the notification")
                                    .font(Aura.body(11)).foregroundStyle(Aura.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            RowDivider()
                            HStack(spacing: 8) {
                                Text("picture").font(Aura.body(13)).foregroundStyle(Aura.ink)
                                Spacer(minLength: 8)
                                Picker("Picture", selection: Binding(
                                    get: { model.pictureChoices[kind] ?? "none" },
                                    set: { choice in
                                        switch choice {
                                        case "none": model.removePicture(for: kind)
                                        case "pick": model.pickPicture?(kind)
                                        case "custom": break
                                        default: model.useBuiltInPicture(choice, for: kind)
                                        }
                                    })) {
                                    Text("no picture").tag("none")
                                    Divider()
                                    ForEach(builtInPictures) { p in
                                        if let icon = builtInPictureIcons[p.id] {
                                            Label { Text(p.title) } icon: { Image(nsImage: icon) }.tag(p.id)
                                        } else {
                                            Text(p.title).tag(p.id)
                                        }
                                    }
                                    Divider()
                                    if model.pictureChoices[kind] == "custom" {
                                        Text("your picture").tag("custom")
                                    }
                                    Text("choose your own…").tag("pick")
                                }
                                .labelsHidden().pickerStyle(.menu).fixedSize()
                                .help("Pick a picture for this notification")
                            }
                            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
                            .frame(minHeight: 40)
                          }
                        }
                    }

                    let changed = model.alertTexts[kind] != nil || picture != nil
                    HStack(spacing: 8) {
                        InkButton(title: sent ? "sent" : "send a test", icon: sent ? "checkmark" : "bell.fill",
                                  height: 42, glow: Aura.tint(.focus)) {
                            model.sendTest(kind)
                            sent = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sent = false }
                        }
                        PillButton(title: "reset", height: 42) { model.resetLook(kind) }
                            .disabled(!changed)
                            .opacity(changed ? 1 : 0.4)
                            .help("Back to the original words, with no picture")
                    }

                    Text(note)
                        .font(Aura.body(11))
                        .foregroundStyle(model.notificationsAllowed ? Aura.muted : Aura.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 20)
            }
            .frame(height: 470)
            .scrollIndicators(.never)
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
            })
        }
    }

    private var note: String {
        if !model.notificationsAllowed {
            return "macOS is blocking Study Timer's notifications. Turn them on in System Settings → Notifications."
        }
        if let problem = model.testProblem { return problem }
        let source = model.session == nil ? "a sample 25 / 5 ×4 session" : "your session"
        var lines = ["The preview uses \(source)."]
        if !model.notificationsOn { lines.append("Pop-ups are off in Settings, so only the test pops up.") }
        else if !model.alerts.contains(kind) { lines.append("This alert is off in Settings, so only the test pops up.") }
        lines.append("Hear the chime but see no pop-up? A Focus (like Do Not Disturb) is hiding it: allow Study Timer in System Settings → Focus.")
        return lines.joined(separator: " ")
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(Aura.mono(10)).tracking(1).foregroundStyle(Aura.muted)
    }

    private func field(_ name: String, placeholder: String, lines: Int, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(Aura.body(11)).foregroundStyle(Aura.muted)
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...lines)
                .textFieldStyle(.plain)
                .font(Aura.body(13))
                .foregroundStyle(Aura.ink)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Aura.glass))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Aura.lineStrong, lineWidth: 1))
                .accessibilityLabel("Notification \(name)")
        }
    }

    private func addToken(_ token: String) {
        var t = model.text(for: kind)
        t.body += (t.body.isEmpty || t.body.hasSuffix(" ") ? "" : " ") + token
        model.setText(t, for: kind)
    }
}

/// Roughly how macOS draws the banner: app icon, title, message, and the
/// picture on the right.
struct NotificationPreview: View {
    let title: String
    let message: String
    let picture: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("now").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let picture {
                Image(nsImage: picture).resizable().scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(title). \(message)")
    }
}

struct NotificationWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bell.slash").foregroundStyle(Aura.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are blocked for Study Timer.").font(Aura.body(11)).foregroundStyle(Aura.ink)
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(.link).font(Aura.body(11))
            }
        }
    }
}

struct Footer: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        HStack {
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Aura.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",")

            Spacer() // quit lives in Settings → General
        }
    }
}

// ===== Menu bar =====

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var item: NSStatusItem!
    let popover = NSPopover()
    var host: NSHostingController<PanelView>!
    var panelHeight: CGFloat = 0
    let model = TimerModel()
    let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy at a time: if Study Timer is already running, quit this one.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != NSRunningApplication.current }) {
            NSApp.terminate(nil)
            return
        }
        registerBundledFonts()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = NSFont(name: "SpaceMono-Regular", size: 12)
                ?? NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
        }

        // The popover is sized by hand: always 320 wide, and as tall as the
        // panel, changed instantly. Letting SwiftUI size it made the popover
        // animate to whatever size the panel reported mid-update (a theme
        // change rebuilds the whole panel), so it looked like it shrank and grew.
        host = NSHostingController(rootView: PanelView(model: model, onHeight: { [weak self] h in
            DispatchQueue.main.async { self?.fitPopover(height: h) }
        }))
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: panelWidth, height: 560)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        applyTheme()
        model.onThemeChange = { [weak self] in self?.applyTheme() }
        model.pickPicture = { [weak self] kind in self?.choosePicture(for: kind) }

        UNUserNotificationCenter.current().delegate = notificationDelegate
        if model.notificationsOn { model.requestAuthorization() }
        model.reschedule()

        // .common mode keeps the countdown moving while menus are open.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.tick()
                self?.updateButton()
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        // Clock jumps (sleep, time zone change) need fresh notifications.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.reschedule() }
        }

        // Other apps can ask for the session, start one, and send pause, skip and end.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Broadcast.request, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.broadcast() }
        }
        distributed.addObserver(forName: Broadcast.command, object: nil, queue: .main) { [weak self] note in
            let command = Broadcast.command(from: note.userInfo)
            MainActor.assumeIsolated { self?.model.handle(command) }
        }
        model.broadcast()

        model.tick()
        updateButton()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.broadcastQuit()
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = item.button else { return }
        model.refreshAuthorization()
        fitPopover(height: host.view.fittingSize.height)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // Back to the main page while closed, so it never switches as it opens.
    // (Not while a picture is being picked: the panel comes back where it was.)
    private var pickingPicture = false
    func popoverDidClose(_ notification: Notification) {
        guard !pickingPicture else { return }
        model.showSettings = false
        model.editingAlert = nil
    }

    // The panel steps aside for the file picker, then reopens on the same page.
    func choosePicture(for kind: ChimeEvent) {
        pickingPicture = true
        popover.performClose(nil)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for the “\(kind.title)” notification"
        panel.prompt = "Use Picture"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK, let url = panel.url { self.model.setPicture(from: url, for: kind) }
                self.pickingPicture = false
                self.showPopover()
            }
        }
    }

    func fitPopover(height: CGFloat) {
        let h = ceil(height)
        guard h > 0, abs(h - panelHeight) >= 1 || popover.contentSize.width != panelWidth else { return }
        panelHeight = h
        let animates = popover.animates
        popover.animates = false
        popover.contentSize = NSSize(width: panelWidth, height: h)
        popover.animates = animates
    }

    func applyTheme() {
        popover.appearance = NSAppearance(named: currentTheme.dark ? .darkAqua : .aqua)
        updateButton()
    }

    func updateButton() {
        guard let button = item?.button else { return }
        guard let s = model.session, let p = model.phase else {
            button.image = templateSymbol("circle")
            button.title = ""
            button.toolTip = "Study Timer"
            return
        }
        let template = currentTheme.templateIcon
        let tint = template ? NSColor.black.withAlphaComponent(model.isPaused ? 0.55 : 1)
                            : nsColor(Aura.hex(p.state), model.isPaused ? 0.55 : 1)
        let ring = ringIcon(progress: phaseProgress(s, p), tint: tint, template: template)
        let time = p.state == .finished ? "done" : (model.barMinutes ? formatShort(p.remaining) : formatClock(p.remaining))

        switch model.barStyle {
        case .ringAndTime:
            button.image = ring
            button.title = " \(time)"
        case .ring:
            button.image = ring
            button.title = ""
        case .time:
            button.image = nil
            button.title = model.isPaused && p.state != .finished ? "\u{23F8}\u{FE0E} \(time)" : time
        }
        button.toolTip = p.state == .finished
            ? "Session finished"
            : "\(model.isPaused ? "Paused · " : "")Round \(max(1, p.round)) of \(s.rounds) · \(formatClock(p.remaining)) left"
    }

    // A tiny version of the panel's ring, in the phase's color.
    func ringIcon(progress: Double, tint: NSColor, template: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let center = NSPoint(x: 8, y: 8), radius: CGFloat = 6
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.5
            tint.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if progress > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(progress), clockwise: true)
                arc.lineWidth = 2.5
                arc.lineCapStyle = .round
                tint.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Study Timer"
        return image
    }

    func templateSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Study Timer")
        image?.isTemplate = true
        return image
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
