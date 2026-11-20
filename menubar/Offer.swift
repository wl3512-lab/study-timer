// "lock in, hands-free": the timer offers itself instead of waiting to be opened.
//
// It offers only when all three are true:
//   1. your calendar is free right now (busy blocks from the planner's ~/.study-cache.json)
//   2. you've been active on the laptop for about 2 minutes
//   3. something is due in the next 7 days (the planner's focus list)
// You start it with one click or one key (⌃⌥L). Nothing starts on its own.
//
// Every offer, answer and start is logged on this Mac only, with the signals
// around it, so a small model can later learn when you actually want to study.
// Log: ~/Library/Application Support/StudyTimerBar/lockin-log.jsonl

import AppKit
import Carbon
import CoreGraphics
import SwiftUI

// ----- What the Mac can see right now -----

struct DueItem {
    let course: String
    let title: String
    let due: Date
    let hoursLeft: Double
}

struct OfferSignals: Codable {
    var calendarKnown: Bool
    var calendarFree: Bool
    var freeMinutes: Double?        // until the next busy block today (nil = free rest of day)
    var idleSeconds: Double
    var activeMinutes: Double       // unbroken stretch of keyboard/mouse use
    var frontApp: String?
    var browserDomain: String?      // only the site, never the full address
    var dueCourse: String?
    var dueTitle: String?
    var dueInHours: Double?
    var dueHoursLeft: Double?
    var dueCount7d: Int
    var minutesSinceSession: Double?
    var sessionRunning: Bool
    var hour: Int
    var weekday: Int                // 1 = Sunday
}

enum StudyCache {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/.study-cache.json")
    private static var cached: (stamp: Date, json: [String: Any])?

    static func load() -> [String: Any]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let stamp = attrs[.modificationDate] as? Date else { return nil }
        if let c = cached, c.stamp == stamp { return c.json }
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        cached = (stamp, json)
        return json
    }

    /// The planner writes times with an offset, with Z, or with neither (local time).
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for f in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = f
            if let d = local.date(from: s) { return d }
        }
        return nil
    }

    /// (known, free, minutes until the next busy block that starts today)
    static func calendar(at now: Date) -> (Bool, Bool, Double?) {
        guard let json = load(), let busy = json["busy"] as? [[String: Any]] else { return (false, true, nil) }
        var free = true
        var next: Date?
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        for b in busy {
            guard let start = date(b["start"] as? String), let end = date(b["end"] as? String) else { continue }
            if start <= now && now < end { free = false }
            if start > now && start < endOfDay && (next == nil || start < next!) { next = start }
        }
        return (true, free, next.map { $0.timeIntervalSince(now) / 60 })
    }

    /// Things due in the next 7 days, soonest first.
    static func due(at now: Date) -> [DueItem] {
        guard let json = load(), let focus = json["focus"] as? [[String: Any]] else { return [] }
        let horizon = now.addingTimeInterval(7 * 86_400)
        return focus.compactMap { f -> DueItem? in
            if (f["optional"] as? Bool) == true { return nil }
            guard let due = date(f["due"] as? String), due > now, due < horizon else { return nil }
            let hours = (f["hours"] as? Double) ?? 0
            let logged = (f["logged"] as? Double) ?? 0
            return DueItem(course: (f["course"] as? String) ?? "",
                           title: (f["title"] as? String) ?? "something",
                           due: due, hoursLeft: max(0, hours - logged))
        }
        .sorted { $0.due < $1.due }
    }
}

enum Activity {
    /// Seconds since the last key press, click or mouse move. Needs no permission.
    static func idleSeconds() -> Double {
        let any = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    static func frontApp() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    /// The site in the front browser tab (domain only). macOS asks once to let
    /// Study Timer read it; if you say no, this just stays empty.
    static func browserDomain(for app: NSRunningApplication?) -> String? {
        let script: String
        switch app?.bundleIdentifier {
        case "com.google.Chrome": script = "tell application \"Google Chrome\" to get URL of active tab of front window"
        case "com.apple.Safari": script = "tell application \"Safari\" to get URL of front document"
        default: return nil
        }
        var error: NSDictionary?
        guard let url = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              let host = URL(string: url)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// ----- The log -----

enum LockinLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyTimerBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lockin-log.jsonl")
    }()

    struct Entry: Codable {
        let ts: Double
        let event: String     // snapshot, offer, accept, dismiss, ignored, start
        let via: String?      // click, hotkey, panel, join
        let signals: OfferSignals
    }

    static func write(_ event: String, via: String? = nil, _ signals: OfferSignals) {
        let entry = Entry(ts: Date().timeIntervalSince1970.rounded(), event: event, via: via, signals: signals)
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

// ----- ⌃⌥L from anywhere (no permission needed) -----

@MainActor
final class HotKey {
    static var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(keyCode: UInt32 = UInt32(kVK_ANSI_L), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.onPress?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4C4B_494E), id: 1) // "LKIN"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

// ----- The offer pill -----

struct OfferView: View {
    let line1: String
    let line2: String
    let startLabel: String
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line1).font(Aura.body(13)).foregroundStyle(Color.white)
                Text(line2).font(Aura.body(11)).foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button(action: onStart) {
                VStack(spacing: 1) {
                    Text(startLabel).font(Aura.body(13)).foregroundStyle(Color.black)
                    Text("⌃⌥L").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.black.opacity(0.55))
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(Color(red: 0.62, green: 0.83, blue: 1.0)))
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Not now (quiet for 30 minutes)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.07, green: 0.08, blue: 0.16).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

// ----- Deciding when to offer -----

@MainActor
final class OfferEngine {
    static let activeNeeded: Double = 120          // seconds of use before an offer
    static let quietAfterNo: Double = 30 * 60      // after "not now" or no answer
    static let quietAfterSession: Double = 5 * 60  // a short break after a session ends
    static let offerShownFor: Double = 120         // then it slips away on its own

    private let model: TimerModel
    private let anchor: () -> NSRect?              // the menu bar icon, on screen
    private var hotKey: HotKey?
    private var timer: Timer?
    private var panel: NSPanel?
    private var shownAt: Date?
    private var quietUntil = Date.distantPast
    private var activeSince: Date?
    private var lastSnapshot = Date.distantPast
    private var lastSessionEnd: Date?
    private var wasRunning = false
    private var pendingVia: String?

    init(model: TimerModel, anchor: @escaping () -> NSRect?) {
        self.model = model
        self.anchor = anchor
        hotKey = HotKey()
        HotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        model.onStart = { [weak self] via in self?.didStart(via: via) }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var sessionRunning: Bool {
        guard let p = model.phase else { return false }
        return p.state != .finished
    }

    private var lastSetup: Preset {
        let d = UserDefaults.standard
        let f = d.integer(forKey: "offerFocus"), b = d.integer(forKey: "offerBreak"), r = d.integer(forKey: "offerRounds")
        return f > 0 ? Preset(focus: f, brk: max(1, b), rounds: max(1, r)) : (model.presets.first ?? defaultPresets[0])
    }

    func signals(now: Date = Date(), withBrowser: Bool = false) -> OfferSignals {
        let (known, free, freeMin) = StudyCache.calendar(at: now)
        let due = StudyCache.due(at: now)
        let idle = Activity.idleSeconds()
        let app = Activity.frontApp()
        let cal = Calendar.current
        return OfferSignals(
            calendarKnown: known, calendarFree: free, freeMinutes: freeMin.map { ($0 * 10).rounded() / 10 },
            idleSeconds: idle.rounded(),
            activeMinutes: activeSince.map { (now.timeIntervalSince($0) / 6).rounded() / 10 } ?? 0,
            frontApp: app?.bundleIdentifier,
            browserDomain: withBrowser ? Activity.browserDomain(for: app) : nil,
            dueCourse: due.first?.course, dueTitle: due.first?.title,
            dueInHours: due.first.map { ($0.due.timeIntervalSince(now) / 360).rounded() / 10 },
            dueHoursLeft: due.first?.hoursLeft, dueCount7d: due.count,
            minutesSinceSession: lastSessionEnd.map { (now.timeIntervalSince($0) / 6).rounded() / 10 },
            sessionRunning: sessionRunning,
            hour: cal.component(.hour, from: now), weekday: cal.component(.weekday, from: now))
    }

    private func check() {
        let now = Date()
        let idle = Activity.idleSeconds()

        // An unbroken stretch of use: a pause over a minute starts it again.
        if idle > 60 { activeSince = nil } else if activeSince == nil { activeSince = now.addingTimeInterval(-idle) }

        let running = sessionRunning
        if wasRunning && !running { lastSessionEnd = now }
        wasRunning = running

        // One snapshot a minute while you're at the laptop: the training data.
        if idle < 120 && now.timeIntervalSince(lastSnapshot) >= 60 {
            lastSnapshot = now
            LockinLog.write("snapshot", signals(now: now, withBrowser: true))
        }

        if let shown = shownAt {
            if running { hide() }
            else if now.timeIntervalSince(shown) > Self.offerShownFor {
                LockinLog.write("ignored", signals(now: now))
                quietUntil = now.addingTimeInterval(Self.quietAfterNo)
                hide()
            }
            return
        }

        guard model.offersOn, !running, now >= quietUntil else { return }
        if let end = lastSessionEnd, now.timeIntervalSince(end) < Self.quietAfterSession { return }
        guard let since = activeSince, now.timeIntervalSince(since) >= Self.activeNeeded else { return }
        let (_, free, freeMin) = StudyCache.calendar(at: now)
        guard free, let item = StudyCache.due(at: now).first else { return }
        show(item: item, freeMinutes: freeMin, now: now)
    }

    // ----- showing and answering -----

    private func show(item: DueItem, freeMinutes: Double?, now: Date) {
        let setup = lastSetup
        let line1: String
        if let m = freeMinutes {
            let f = DateFormatter(); f.dateFormat = "h:mm"
            line1 = "free till \(f.string(from: now.addingTimeInterval(m * 60))) · lock in?"
        } else {
            line1 = "you're free · lock in?"
        }
        // Due date first: the title is often long and gets cut off.
        let line2 = "due \(Self.dueWords(item.due, now: now)) · \(item.course.isEmpty ? "" : item.course + " · ")\(item.title)"

        let view = OfferView(line1: line1, line2: line2, startLabel: "start \(setup.focus)",
                             onStart: { [weak self] in self?.accept(via: "click") },
                             onDismiss: { [weak self] in self?.dismiss() })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host

        let size = host.fittingSize
        if let icon = anchor() {
            var x = icon.midX - size.width / 2
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(icon.origin) }) ?? NSScreen.main {
                x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            }
            p.setFrameOrigin(NSPoint(x: x, y: icon.minY - size.height - 8))
        } else if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 12,
                                     y: screen.visibleFrame.maxY - size.height - 8))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }

        panel = p
        shownAt = now
        LockinLog.write("offer", signals(now: now, withBrowser: true))
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        shownAt = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }

    private func accept(via: String) {
        guard shownAt != nil else { return }
        LockinLog.write("accept", via: via, signals())
        hide()
        let s = lastSetup
        pendingVia = via
        model.start(focus: s.focus, brk: s.brk, rounds: s.rounds)
    }

    private func dismiss() {
        LockinLog.write("dismiss", signals())
        quietUntil = Date().addingTimeInterval(Self.quietAfterNo)
        hide()
    }

    /// ⌃⌥L: takes the offer if one is showing, otherwise starts anyway.
    /// A start with no offer showing is the model's "you missed one" label.
    private func hotKeyPressed() {
        if shownAt != nil { accept(via: "hotkey"); return }
        guard !sessionRunning else { return }
        let s = lastSetup
        pendingVia = "hotkey"
        model.start(focus: s.focus, brk: s.brk, rounds: s.rounds)
    }

    private func didStart(via: String) {
        let how = pendingVia ?? via
        pendingVia = nil
        if let s = model.session {
            let d = UserDefaults.standard
            d.set(s.focus, forKey: "offerFocus"); d.set(s.brk, forKey: "offerBreak"); d.set(s.rounds, forKey: "offerRounds")
        }
        if panel != nil { hide() }
        LockinLog.write("start", via: how, signals(withBrowser: true))
    }

    nonisolated static func dueWords(_ due: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(due, inSameDayAs: now) {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return "today \(f.string(from: due).lowercased())"
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(due, inSameDayAs: tomorrow) { return "tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: due)
    }
}

/// `StudyTimerBar --offer-check`: what the offer sees right now, without showing anything.
enum OfferCheck {
    static func report() -> String {
        let now = Date()
        let (known, free, freeMin) = StudyCache.calendar(at: now)
        let due = StudyCache.due(at: now)
        let idle = Activity.idleSeconds()
        var lines = [
            "calendar: \(known ? (free ? "free" : "BUSY") : "no cache (treated as free)")\(freeMin.map { String(format: ", next busy in %.0f min", $0) } ?? ", nothing else today")",
            String(format: "idle: %.0f s", idle),
            "due in 7 days: \(due.count)",
        ]
        for d in due.prefix(3) {
            lines.append("  · \(d.course) · \(d.title.prefix(50)) · due \(OfferEngine.dueWords(d.due, now: now)) · \(d.hoursLeft) h left")
        }
        lines.append("would offer (after ~2 min active): \(free && !due.isEmpty ? "yes" : "no")")
        lines.append("log: \(LockinLog.url.path)")
        return lines.joined(separator: "\n")
    }
}
