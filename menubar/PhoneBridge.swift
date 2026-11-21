// Phone bridge: the webcam sketch ("lock in, hands-free") tells the menu bar
// when it has seen your phone for 20 seconds in a row, so you notice even when
// the timer tab isn't on screen. Local only: 127.0.0.1:8779, nothing leaves the Mac.
//
//   POST /phone {"phone": true}   phone up (sent again every few seconds while it lasts)
//   POST /phone {"phone": false}  phone down
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
            if first.hasPrefix("POST /phone") {
                let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
                if let phone = obj?["phone"] as? Bool {
                    DispatchQueue.main.async { MainActor.assumeIsolated { PhoneBridge.shared.set(phone: phone) } }
                } else { status = "400 Bad Request" }
            } else if !first.hasPrefix("OPTIONS") {
                status = "404 Not Found"
            }
            let reply = "HTTP/1.1 \(status)\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
                + "Access-Control-Allow-Headers: Content-Type\r\n"
                + "Access-Control-Allow-Private-Network: true\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
