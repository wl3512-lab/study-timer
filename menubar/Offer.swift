// "lock in, hands-free": the timer offers itself instead of waiting to be opened.
//
// It offers only when all three are true:
//   1. your calendar is free right now (busy blocks from the planner's ~/.study-cache.json)
//   2. you've been active on the laptop for about 2 minutes
//   3. homework you haven't finished is due soon (default 4 days; Settings changes it)
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
    let courseKey: String?          // Today's course key, for logging study time back
    let deadlineId: String?         // Today's id for this assignment
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
    var night: Bool = false
    var pressure: Double? = nil     // hours left on what's due in 2 days ÷ free hours before it
    var offDay: Bool? = nil         // a held-out day: offers rest, "would have offered" is still logged
}

// ----- Off-days: some days the offer rests on purpose -----
// So you keep deciding for yourself when to start, and so there are clean
// days to test the rules (or a learned model) against. Rolled once per day.
enum OffDays {
    static func isOff(_ date: Date, every: Int) -> Bool {
        guard every > 0 else { return false }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let key = "offDay-" + f.string(from: date)
        let d = UserDefaults.standard
        if let v = d.object(forKey: key) as? Bool { return v }
        let off = Int.random(in: 0..<every) == 0
        d.set(off, forKey: key)
        return off
    }
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

    /// (known, free, minutes until the next busy block in the next 24 hours)
    static func calendar(at now: Date) -> (Bool, Bool, Double?) {
        guard let json = load(), let busy = json["busy"] as? [[String: Any]] else { return (false, true, nil) }
        var free = true
        var next: Date?
        let horizon = now.addingTimeInterval(86_400)
        for b in busy {
            guard let start = date(b["start"] as? String), let end = date(b["end"] as? String) else { continue }
            if start <= now && now < end { free = false }
            if start > now && start < horizon && (next == nil || start < next!) { next = start }
        }
        return (true, free, next.map { $0.timeIntervalSince(now) / 60 })
    }

    /// Busy blocks as dates (parsed once per cache change).
    private static var busyCache: (stamp: Date, blocks: [(Date, Date)])?
    static func busyBlocks() -> [(Date, Date)] {
        guard let json = load(), let busy = json["busy"] as? [[String: Any]] else { return [] }
        let stamp = cached?.stamp ?? .distantPast
        if let b = busyCache, b.stamp == stamp { return b.blocks }
        let blocks = busy.compactMap { b -> (Date, Date)? in
            guard let s = date(b["start"] as? String), let e = date(b["end"] as? String) else { return nil }
            return (s, e)
        }
        busyCache = (stamp, blocks)
        return blocks
    }

    /// Free, awake hours (9 am to midnight, not in a busy block) between two times.
    static func freeHours(from start: Date, to end: Date) -> Double {
        let blocks = busyBlocks()
        let cal = Calendar.current
        var t = start, slots = 0
        while t < end {
            let h = cal.component(.hour, from: t)
            if h >= 9 && !blocks.contains(where: { $0.0 <= t && t < $0.1 }) { slots += 1 }
            t = t.addingTimeInterval(900)
        }
        return Double(slots) / 4
    }

    /// Am I behind? For homework due in the next 2 days, soonest first: hours still
    /// needed (adding up) ÷ free hours before each is due. Returns the worst ratio
    /// and the assignments that are tight (ratio 0.6 or more).
    static func pressure(at now: Date) -> (Double, [DueItem]) {
        let items = due(at: now, days: 2)
        var needed = 0.0, worst = 0.0
        var tight: [DueItem] = []
        for item in items {
            needed += item.hoursLeft
            let ratio = needed / max(0.5, freeHours(from: now, to: item.due))
            worst = max(worst, ratio)
            if ratio >= 0.6 { tight.append(item) }
        }
        return ((worst * 100).rounded() / 100, tight)
    }

    /// How many days ahead counts as "due soon" (Settings → offer when due within).
    static var dueDays: Int {
        let d = UserDefaults.standard.integer(forKey: "offerDueDays")
        return d > 0 ? d : 4
    }

    /// Homework you haven't finished that's due soon, soonest first.
    /// "Not finished" = the planner still has hours left on it.
    static func due(at now: Date, days: Int = dueDays) -> [DueItem] {
        guard let json = load(), let focus = json["focus"] as? [[String: Any]] else { return [] }
        let horizon = now.addingTimeInterval(Double(days) * 86_400)
        return focus.compactMap { f -> DueItem? in
            if (f["optional"] as? Bool) == true { return nil }
            guard let due = date(f["due"] as? String), due > now, due < horizon else { return nil }
            let hours = (f["hours"] as? Double) ?? 0
            let logged = (f["logged"] as? Double) ?? 0
            let left = (f["remaining"] as? Double) ?? max(0, hours - logged)
            guard left > 0 else { return nil }
            return DueItem(courseKey: f["key"] as? String, deadlineId: f["id"] as? String,
                           course: (f["course"] as? String) ?? "",
                           title: (f["title"] as? String) ?? "something",
                           due: due, hoursLeft: left)
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
        let event: String     // snapshot, offer, accept, dismiss, ignored, start, holdout, logged, undo
        let via: String?      // click, hotkey, panel, join, preview
        let task: String?     // which homework you picked from the offer
        let signals: OfferSignals
    }

    /// Starts in the last 7 days: on your own (panel, join, ⌃⌥L with no offer) vs from an offer.
    /// Previews don't count. Cached until the log grows.
    /// Starts in the last 7 days, three kinds:
    ///   from offers  = picked from the pill (click or ⌃⌥L while it showed)
    ///   reminded     = started yourself within an hour of an offer you said no to (the pill as a nudge)
    ///   on your own  = everything else (panel, join, ⌃⌥L with nothing showing)
    /// Previews don't count. Cached until the log grows.
    @MainActor private static var weekCache: (size: Int, day: Int, w: Week)?
    struct Week { var own = 0, offered = 0, reminded = 0 }
    @MainActor static func week() -> Week {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        if let c = weekCache, c.size == size, c.day == day { return c.w }
        struct Row: Decodable { let ts: Double; let event: String; let via: String?; let task: String? }
        var w = Week()
        var lastNo: Double = -.infinity
        let since = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard line.contains("\"event\":\"start\"") || line.contains("\"event\":\"dismiss\"")
                        || line.contains("\"event\":\"ignored\"") else { continue }
                guard let e = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)), e.ts >= since else { continue }
                if e.event != "start" { lastNo = e.ts; continue }
                if e.via == "preview" { continue }
                if e.task != nil { w.offered += 1 }
                else if e.ts - lastNo <= 3600 { w.reminded += 1 }
                else { w.own += 1 }
            }
        }
        weekCache = (size, day, w)
        return w
    }

    @MainActor static func weekLine() -> String {
        let w = week()
        var parts = ["\(w.offered) from offers", "\(w.reminded) after a reminder", "\(w.own) on your own"]
        if w.reminded == 0 { parts.remove(at: 1) }
        return "this week: " + parts.joined(separator: " · ")
    }

    static func write(_ event: String, via: String? = nil, task: String? = nil, _ signals: OfferSignals) {
        let entry = Entry(ts: Date().timeIntervalSince1970.rounded(), event: event, via: via, task: task, signals: signals)
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

struct OfferTask: Identifiable {
    let id: Int
    let title: String
    let detail: String
}

struct OfferView: View {
    let header: String
    let tasks: [OfferTask]
    let startLabel: String
    let onStart: (Int) -> Void
    let onDismiss: () -> Void

    private let blue = Color(red: 0.62, green: 0.83, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(header).font(Aura.body(14)).foregroundStyle(Color.white)
                Spacer(minLength: 8)
                Text("⌃⌥L = first").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.white.opacity(0.45))
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Not now (quiet for 30 minutes)")
            }
            ForEach(tasks) { t in
                Button { onStart(t.id) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(Aura.body(12)).foregroundStyle(Color.white)
                                .lineLimit(1).truncationMode(.tail)
                            Text(t.detail).font(Aura.body(10.5)).foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(startLabel).font(Aura.body(12)).foregroundStyle(Color.black)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(blue))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(t.id == 0 ? 0.10 : 0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.07, green: 0.08, blue: 0.16).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

// ----- The receipt: what just went to Today, with undo -----

struct ReceiptView: View {
    let line: String
    let title: String
    let week: String
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line).font(Aura.body(13)).foregroundStyle(Color.white)
                Text(title).font(Aura.body(10.5)).foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1).truncationMode(.tail)
                Text(week).font(Aura.body(10.5)).foregroundStyle(Color.white.opacity(0.4))
            }
            Spacer(minLength: 6)
            Button(action: onUndo) {
                Text("undo").font(Aura.body(12)).foregroundStyle(Color.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Wrong task or wrong minutes: don't send this to Today")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.07, green: 0.08, blue: 0.16).opacity(0.97)))
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
    static let maxTasks = 3
    static let receiptHold: Double = 90            // seconds to undo before minutes go to Today

    private let model: TimerModel
    private let anchor: () -> NSRect?              // the menu bar icon, on screen
    private var hotKey: HotKey?
    private var timer: Timer?
    private var panel: NSPanel?
    private var shownAt: Date?
    private var shownItems: [DueItem] = []
    private var isPreview = false
    private var quietUntil = Date.distantPast
    private var activeSince: Date?
    private var lastSnapshot = Date.distantPast
    private var lastSessionEnd: Date?
    private var wasRunning = false
    private var pendingVia: String?
    private var pendingTask: String?
    private var pendingItem: DueItem?
    private var currentItem: DueItem?          // the homework this session is for
    private var focusRound: (start: Double, round: Int, minutes: Int)?   // the focus round being watched
    private var lastFocusLeft: Double = 0
    private var lastTodayRetry = Date.distantPast
    private var receiptPanel: NSPanel?
    private var receiptId: String?

    init(model: TimerModel, anchor: @escaping () -> NSRect?) {
        self.model = model
        self.anchor = anchor
        hotKey = HotKey()
        HotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        model.onStart = { [weak self] via in self?.didStart(via: via) }
        model.previewOffer = { [weak self] in self?.preview() }
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

    /// Night = from the Settings hour (10 pm by default) until 6 am. -1 = never.
    func isNight(_ now: Date) -> Bool {
        let start = model.offerNightStart
        guard start >= 0 else { return false }
        let h = Calendar.current.component(.hour, from: now)
        return start == 0 ? h < 6 : (h >= start || h < 6)
    }

    static func nextMorning(after now: Date) -> Date {
        let cal = Calendar.current
        let six = cal.date(bySettingHour: 6, minute: 0, second: 0, of: now)!
        return six > now ? six : cal.date(byAdding: .day, value: 1, to: six)!
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
            hour: cal.component(.hour, from: now), weekday: cal.component(.weekday, from: now),
            night: isNight(now), pressure: StudyCache.pressure(at: now).0,
            offDay: OffDays.isOff(now, every: model.offerOffDayEvery))
    }

    private func check() {
        let now = Date()
        let idle = Activity.idleSeconds()

        // An unbroken stretch of use: a pause over a minute starts it again.
        if idle > 60 { activeSince = nil } else if activeSince == nil { activeSince = now.addingTimeInterval(-idle) }

        let running = sessionRunning
        if wasRunning && !running { lastSessionEnd = now }
        wasRunning = running
        watchFocus(now: now)

        // One snapshot a minute while you're at the laptop: the training data.
        if idle < 120 && now.timeIntervalSince(lastSnapshot) >= 60 {
            lastSnapshot = now
            LockinLog.write("snapshot", signals(now: now, withBrowser: true))
        }

        if let shown = shownAt {
            if running { hide() }
            else if now.timeIntervalSince(shown) > Self.offerShownFor {
                if !isPreview {
                    LockinLog.write("ignored", signals(now: now))
                    quietUntil = isNight(now) ? Self.nextMorning(after: now) : now.addingTimeInterval(Self.quietAfterNo)
                }
                hide()
            }
            return
        }

        guard model.offersOn, !running, now >= quietUntil else { return }
        guard now.timeIntervalSince1970 >= model.offersPausedUntil else { return }   // paused (e.g. winter break)
        if let end = lastSessionEnd, now.timeIntervalSince(end) < Self.quietAfterSession { return }
        guard let since = activeSince, now.timeIntervalSince(since) >= Self.activeNeeded else { return }
        let (_, free, freeMin) = StudyCache.calendar(at: now)
        guard free else { return }

        if isNight(now) {
            // Late: you're usually relaxing, so only speak up when you're behind,
            // and only once a night.
            let (worst, tight) = StudyCache.pressure(at: now)
            guard worst >= 0.6, !tight.isEmpty else { return }
            quietUntil = Self.nextMorning(after: now)
            if holdOut(now) { return }
            show(items: tight, freeMinutes: freeMin, now: now, preview: false, night: true)
            return
        }
        let items = StudyCache.due(at: now)
        guard !items.isEmpty else { return }
        if holdOut(now) { return }
        show(items: items, freeMinutes: freeMin, now: now, preview: false)
    }

    /// On an off-day the offer stays hidden, but the moment it would have
    /// appeared is logged: the held-out test set.
    private func holdOut(_ now: Date) -> Bool {
        guard OffDays.isOff(now, every: model.offerOffDayEvery) else { return false }
        LockinLog.write("holdout", signals(now: now, withBrowser: true))
        if !isNight(now) { quietUntil = now.addingTimeInterval(Self.quietAfterNo) }
        return true
    }

    // ----- study time back to Today -----

    /// When a focus round for a picked assignment ends, log its minutes in Today,
    /// so "hours left" goes down (and night mode knows how behind you really are).
    private func watchFocus(now: Date) {
        retryToday(now: now)
        let s = model.session, p = model.phase
        if let s, let p, p.state == .focus, !model.isPaused {
            if let f = focusRound, f.start == s.startUtc, f.round == p.round {
                lastFocusLeft = p.remaining
            } else {
                focusRound = (s.startUtc, p.round, s.focus)
                lastFocusLeft = p.remaining
            }
            return
        }
        guard let f = focusRound else { return }
        // The round we were watching is over: finished (break/done) or cut short.
        let planned = Double(f.minutes)
        let finished = s?.startUtc == f.start && (p?.state == .brk || p?.state == .finished)
        let minutes = finished ? planned : max(0, planned - lastFocusLeft / 60)
        if model.isPaused, s?.startUtc == f.start { return }   // paused mid-round: keep watching
        focusRound = nil
        if let item = currentItem, minutes >= 5 { sendToToday(minutes: Int(minutes.rounded()), item: item) }
        if s == nil || p?.state == .finished { currentItem = nil }
    }

    private func sendToToday(minutes: Int, item: DueItem) {
        let id = UUID().uuidString
        var row: [String: Any] = ["minutes": minutes, "kind": "study", "note": "lock in",
                                  "at": ISO8601DateFormatter().string(from: Date())]
        // Kept back for a moment so a wrong log can be undone before Today sees it.
        let hold: [String: Any] = ["id": id, "holdUntil": Date().addingTimeInterval(Self.receiptHold).timeIntervalSince1970]
        if let k = item.courseKey { row["courseKey"] = k }
        if let d = item.deadlineId { row["deadlineId"] = d }
        var pending = UserDefaults.standard.array(forKey: "todayPending") as? [[String: Any]] ?? []
        pending.append(["row": row, "hold": hold])
        UserDefaults.standard.set(pending, forKey: "todayPending")
        LockinLog.write("logged", via: "today", task: "\(item.course) · \(item.title) · \(minutes) min", signals())
        showReceipt(id: id, minutes: minutes, item: item)
    }

    private func showReceipt(id: String, minutes: Int, item: DueItem) {
        hideReceipt()
        let course = item.course.isEmpty ? "Today" : item.course
        let view = ReceiptView(line: "logged \(minutes) min → \(course)", title: item.title,
                               week: LockinLog.weekLine(),
                               onUndo: { [weak self] in self?.undoReceipt() },
                               onClose: { [weak self] in self?.hideReceipt() })
        let p = makePanel(NSHostingView(rootView: view))
        receiptPanel = p
        receiptId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.receiptHold) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.receiptId == id else { return }
                self.hideReceipt()
                self.retryToday(now: Date(), force: true)
            }
        }
    }

    private func undoReceipt() {
        guard let id = receiptId else { return }
        var pending = UserDefaults.standard.array(forKey: "todayPending") as? [[String: Any]] ?? []
        let before = pending.count
        pending.removeAll { (($0["hold"] as? [String: Any])?["id"] as? String) == id }
        UserDefaults.standard.set(pending, forKey: "todayPending")
        LockinLog.write("undo", via: pending.count < before ? "kept back" : "too late", signals())
        hideReceipt()
    }

    private func hideReceipt() {
        receiptId = nil
        guard let p = receiptPanel else { return }
        receiptPanel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }

    /// Today's local server (port 8765) takes the session. If Today isn't open,
    /// the minutes wait here and go through the next time it is.
    private func retryToday(now: Date, force: Bool = false) {
        guard force || now.timeIntervalSince(lastTodayRetry) > 60 else { return }
        lastTodayRetry = now
        let pending = UserDefaults.standard.array(forKey: "todayPending") as? [[String: Any]] ?? []
        // Wrapped rows wait out their undo window; plain rows (older versions) go now.
        guard let index = pending.firstIndex(where: {
                  (($0["hold"] as? [String: Any])?["holdUntil"] as? Double ?? 0) <= now.timeIntervalSince1970 }) else { return }
        let entry = pending[index]
        let row = entry["row"] as? [String: Any] ?? entry
        let id = (entry["hold"] as? [String: Any])?["id"] as? String
        guard let body = try? JSONSerialization.data(withJSONObject: ["addSession": row]) else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/ledger")!, timeoutInterval: 3)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var left = UserDefaults.standard.array(forKey: "todayPending") as? [[String: Any]] ?? []
                    if let id {
                        left.removeAll { (($0["hold"] as? [String: Any])?["id"] as? String) == id }
                    } else if let i = left.firstIndex(where: { $0["hold"] == nil && NSDictionary(dictionary: $0).isEqual(to: row) }) {
                        left.remove(at: i)
                    }
                    UserDefaults.standard.set(left, forKey: "todayPending")
                    if !left.isEmpty { self?.retryToday(now: Date(), force: true) }
                }
            }
        }.resume()
    }

    /// Settings → "show me": the real pill with your real homework, ignoring the rules.
    /// Logged as a preview, so it never counts as training data.
    func preview() {
        if shownAt != nil { hide() }
        let now = Date()
        var items = StudyCache.due(at: now)
        if items.isEmpty { items = StudyCache.due(at: now, days: 30) }
        if items.isEmpty {
            items = [DueItem(courseKey: nil, deadlineId: nil, course: "Example", title: "Nothing unfinished is due soon", due: now.addingTimeInterval(86_400), hoursLeft: 1)]
        }
        show(items: items, freeMinutes: StudyCache.calendar(at: now).2, now: now, preview: true)
    }

    // ----- showing and answering -----

    nonisolated static func freeWords(_ minutes: Double?, now: Date) -> String {
        guard let m = minutes else { return "free all day" }
        let until = now.addingTimeInterval(m * 60)
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        let time = f.string(from: until).lowercased()
        return Calendar.current.isDate(until, inSameDayAs: now) ? "free till \(time)" : "free till tomorrow \(time)"
    }

    private func show(items: [DueItem], freeMinutes: Double?, now: Date, preview: Bool, night: Bool = false) {
        let setup = lastSetup
        let picked = Array(items.prefix(Self.maxTasks))
        let tasks = picked.enumerated().map { i, item -> OfferTask in
            let hours = item.hoursLeft == item.hoursLeft.rounded() ? String(Int(item.hoursLeft)) : String(format: "%.1f", item.hoursLeft)
            return OfferTask(id: i,
                             title: item.course.isEmpty ? item.title : "\(item.course) · \(item.title)",
                             detail: "due \(Self.dueWords(item.due, now: now)) · \(hours) h left")
        }
        let header = night
            ? "behind on \(picked.first.map { $0.course.isEmpty ? "homework" : $0.course } ?? "homework") · \(setup.focus) min tonight?"
            : "\(Self.freeWords(freeMinutes, now: now)) · lock in?"
        let view = OfferView(header: header, tasks: tasks, startLabel: "start \(setup.focus)",
                             onStart: { [weak self] i in self?.accept(index: i, via: "click") },
                             onDismiss: { [weak self] in self?.dismiss() })
        let p = makePanel(NSHostingView(rootView: view))

        panel = p
        shownAt = now
        shownItems = picked
        isPreview = preview
        LockinLog.write(preview ? "preview" : "offer", signals(now: now, withBrowser: true))
    }

    /// A floating, non-activating pill just under the menu bar icon.
    private func makePanel(_ host: NSView) -> NSPanel {
        let size = host.fittingSize
        host.frame.size = size

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host

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

        return p
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        shownAt = nil
        shownItems = []
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }

    private func accept(index: Int, via: String) {
        guard shownAt != nil else { return }
        let item = index < shownItems.count ? shownItems[index] : nil
        let task = item.map { "\($0.course) · \($0.title)" }
        if !isPreview { LockinLog.write("accept", via: via, task: task, signals()) }
        let wasPreview = isPreview
        hide()
        let s = lastSetup
        pendingVia = wasPreview ? "preview" : via
        pendingTask = task
        pendingItem = item
        model.start(focus: s.focus, brk: s.brk, rounds: s.rounds)
    }

    private func dismiss() {
        if !isPreview {
            LockinLog.write("dismiss", signals())
            let now = Date()
            quietUntil = isNight(now) ? Self.nextMorning(after: now) : now.addingTimeInterval(Self.quietAfterNo)
        }
        hide()
    }

    /// ⌃⌥L: takes the first homework if an offer is showing, otherwise starts anyway.
    /// A start with no offer showing is the model's "you missed one" label.
    private func hotKeyPressed() {
        if shownAt != nil { accept(index: 0, via: "hotkey"); return }
        guard !sessionRunning else { return }
        let s = lastSetup
        pendingVia = "hotkey"
        model.start(focus: s.focus, brk: s.brk, rounds: s.rounds)
    }

    private func didStart(via: String) {
        let how = pendingVia ?? via
        let task = pendingTask
        currentItem = pendingItem
        pendingVia = nil
        pendingTask = nil
        pendingItem = nil
        if let s = model.session {
            let d = UserDefaults.standard
            d.set(s.focus, forKey: "offerFocus"); d.set(s.brk, forKey: "offerBreak"); d.set(s.rounds, forKey: "offerRounds")
        }
        if panel != nil { hide() }
        LockinLog.write("start", via: how, task: task, signals(withBrowser: true))
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
    @MainActor static func report() -> String {
        let now = Date()
        let (known, free, freeMin) = StudyCache.calendar(at: now)
        let due = StudyCache.due(at: now)
        let idle = Activity.idleSeconds()
        var lines = [
            "calendar: \(known ? (free ? "free" : "BUSY") : "no cache (treated as free)")\(freeMin.map { String(format: ", next busy in %.0f min", $0) } ?? ", nothing else today")",
            String(format: "idle: %.0f s", idle),
            "\(OfferEngine.freeWords(freeMin, now: now))",
            "unfinished + due within \(StudyCache.dueDays) days: \(due.count)",
        ]
        for d in due.prefix(3) {
            lines.append("  · \(d.course) · \(d.title.prefix(50)) · due \(OfferEngine.dueWords(d.due, now: now)) · \(d.hoursLeft) h left")
        }
        let (worst, tight) = StudyCache.pressure(at: now)
        lines.append(String(format: "behind-ness (due in 2 days): %.2f (night offers at 0.60+), tight: %d", worst, tight.count))
        lines.append("would offer by day (after ~2 min active): \(free && !due.isEmpty ? "yes" : "no")")
        let every = UserDefaults.standard.object(forKey: "offerOffDayEvery") as? Int ?? 5
        lines.append("off-day today: \(OffDays.isOff(now, every: every) ? "yes (offers rest, would-offers logged as holdout)" : "no") · 1 in \(every)")
        lines.append(LockinLog.weekLine())
        let pending = UserDefaults.standard.array(forKey: "todayPending") as? [[String: Any]] ?? []
        lines.append("waiting to go to Today: \(pending.count)")
        lines.append("log: \(LockinLog.url.path)")
        return lines.joined(separator: "\n")
    }
}
