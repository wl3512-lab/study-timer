// Phone bridge: the webcam sketch ("lock in, hands-free") tells the menu bar
// when it has seen your phone for 20 seconds in a row, so you notice even when
// the timer tab isn't on screen. Local only: 127.0.0.1:8779, nothing leaves the Mac.
//
//   POST /phone {"phone": true}   phone up (sent again every few seconds while it lasts)
//   POST /phone {"phone": false}  phone down
//   GET  /session                 {"running", "focus", "remaining"}: the sketch's watch
//                                 mode keeps the camera on only during focus
//
// The menu bar ring turns yellow and pulses with "phone down?", and one
// notification goes out per phone stretch. With no news for 15 s it clears itself.

import AppKit
import Network
import UserNotifications

@MainActor
final class PhoneBridge {
    static let shared = PhoneBridge()
    static let port: UInt16 = 8779
    private(set) var alertUntil = Date.distantPast
    private var listener: NWListener?
    var onChange: (() -> Void)?
    /// What the timer is doing, for the sketch's watch mode (GET /session).
    var sessionInfo: (() -> [String: Any])?
    private(set) var lastWatcherPing = Date.distantPast
    /// A watch-mode sketch asked about the session in the last 10 s.
    var watcherAlive: Bool { Date().timeIntervalSince(lastWatcherPing) < 10 }

    var isAlert: Bool { Date() < alertUntil }

    func start() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let l = try? NWListener(using: params, on: port) else {
            NSLog("Study Timer: phone bridge could not open port \(Self.port)")
            return
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .main)
            PhoneBridge.read(conn, buffer: Data())
        }
        l.start(queue: .main)
        listener = l
    }

    func set(phone: Bool) {
        if phone {
            if !isAlert { notify() }          // a new phone stretch: one notification
            alertUntil = Date().addingTimeInterval(15)
        } else {
            alertUntil = .distantPast
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["phone-down"])
        }
        onChange?()
    }

    private func notify() {
        let content = UNMutableNotificationContent()
        content.title = "phone down?"
        content.body = "Your phone's been up for 20 seconds. Your focus timer is still going."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "phone-down", content: content, trigger: nil))
    }

    /// When a focus round starts and nothing is watching yet, open the sketch
    /// in watch mode (a small Chrome window). It turns the camera on only during focus.
    static let watchURL = "https://wl3512-lab.github.io/ml-arts-lock-in-handsfree/sketch/?watch=1"
    private var lastOpen = Date.distantPast
    func openWatcherIfNeeded() {
        guard !watcherAlive, Date().timeIntervalSince(lastOpen) > 60 else { return }
        lastOpen = Date()
        if FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", "Google Chrome", "--args", "--app=\(Self.watchURL)", "--window-size=420,520"]
            try? p.run()
        } else if let url = URL(string: Self.watchURL) {
            NSWorkspace.shared.open(url)
        }
    }

    static let traceURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyTimerBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sketch-trace.jsonl")
    }()

    nonisolated static func appendTrace(_ body: String) {
        guard !body.isEmpty, var data = body.data(using: .utf8) else { return }
        if data.last != 0x0A { data.append(0x0A) }
        if let h = try? FileHandle(forWritingTo: traceURL) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: traceURL) }
    }

    // ----- a very small HTTP server -----

    nonisolated private static func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            guard let text = String(data: buf, encoding: .utf8), let split = text.range(of: "\r\n\r\n") else {
                if done || error != nil || buf.count > 16_384 { conn.cancel() } else { read(conn, buffer: buf) }
                return
            }
            let head = String(text[..<split.lowerBound])
            let body = String(text[split.upperBound...])
            let length = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if body.utf8.count < length && !done && error == nil { read(conn, buffer: buf); return }

            let first = head.split(separator: "\r\n").first.map(String.init) ?? ""
            var status = "204 No Content"
            var json: String?
            if first.hasPrefix("GET /session") {
                status = "200 OK"
                let info: [String: Any] = MainActor.assumeIsolated {
                    PhoneBridge.shared.lastWatcherPing = Date()
                    return PhoneBridge.shared.sessionInfo?() ?? ["running": false, "focus": false]
                }
                json = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            } else if first.hasPrefix("POST /trace") {
                // the sketch's ?trace=1 test log: one JSON line per reading
                PhoneBridge.appendTrace(body)
            } else if first.hasPrefix("POST /phone") {
                let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
                if let phone = obj?["phone"] as? Bool {
                    DispatchQueue.main.async { MainActor.assumeIsolated { PhoneBridge.shared.set(phone: phone) } }
                } else { status = "400 Bad Request" }
            } else if !first.hasPrefix("OPTIONS") {
                status = "404 Not Found"
            }
            let reply = "HTTP/1.1 \(status)\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                + "Access-Control-Allow-Headers: Content-Type\r\n"
                + "Access-Control-Allow-Private-Network: true\r\n"
                + (json != nil ? "Content-Type: application/json\r\nCache-Control: no-store\r\n" : "")
                + "Content-Length: \(json?.utf8.count ?? 0)\r\nConnection: close\r\n\r\n" + (json ?? "")
            conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
