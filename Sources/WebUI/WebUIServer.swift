import Foundation
import Network

/// 本地静态服务器：把 Resources/webui 里的 DeepSeek Harness 真·Web UI 原样
/// 服务给 WKWebView（http://127.0.0.1:<port>/）。只服务 GET/HEAD，单连接单请求。
final class WebUIServer: ObservableObject {
    static let shared = WebUIServer()

    @Published var running = false
    @Published var portText = "8799"

    private var listener: NWListener?
    private let root: URL
    private let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "webp": "image/webp",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "map": "application/json",
        "webmanifest": "application/manifest+json",
    ]

    private init() {
        root = Bundle.main.resourceURL?.appendingPathComponent("webui", isDirectory: true)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var localURL: String { "http://127.0.0.1:\(portText)/index.html" }

    func start(port: UInt16 = 8799) {
        guard listener == nil else { return }
        portText = String(port)
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    self.running = true
                    HarnessLog.shared.add("[WebUI] 服务中 \(self.localURL)")
                case .failed(let e):
                    self.running = false
                    HarnessLog.shared.add("[WebUI] 失败 \(e)")
                default: break
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            HarnessLog.shared.add("[WebUI] 启动失败 \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        HarnessLog.shared.add("[WebUI] 已停止")
    }

    // MARK: - 连接处理
    private final class Buf { var data = Data(); var responded = false }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        let buf = Buf()
        readMore(conn, buf: buf)
    }

    private func readMore(_ conn: NWConnection, buf: Buf) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, _ in
            guard let self else { return }
            if let data, !data.isEmpty { buf.data.append(data) }
            guard !buf.responded, let raw = String(data: buf.data, encoding: .utf8) else { return }
            let lines = raw.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? ""
            let parts = requestLine.split(separator: " ")
            if parts.count < 2 { return }
            guard raw.contains("\r\n\r\n") || isDone else { self.readMore(conn, buf: buf); return }
            buf.responded = true
            let method = String(parts[0])
            var path = String(parts[1])
            if let q = path.firstIndex(of: "?") {
                path.removeSubrange(q...)
            }
            self.respond(conn: conn, method: method, path: path)
        }
    }

    private func respond(conn: NWConnection, method: String, path: String) {
        var rel = path
        if rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = "index.html" }
        // 模块路径在打包时已把 ?? 净化成 __，WS 端若仍发原始 %3F 也要能命中
        let fileURL = root.appendingPathComponent(rel.replacingOccurrences(of: "__", with: "__"))
        var isDir: ObjCBool = false
        var target = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) {
            if isDir.boolValue { target = fileURL.appendingPathComponent("index.html") }
        } else if rel == "index.html" {
            target = root.appendingPathComponent("index.html")
        }
        guard FileManager.default.fileExists(atPath: target.path),
              let data = try? Data(contentsOf: target) else {
            send(conn: conn, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8), method: method)
            return
        }
        let ext = target.pathExtension.lowercased()
        let type = mimeTypes[ext] ?? "application/octet-stream"
        send(conn: conn, status: "200 OK", type: type, body: data, method: method)
    }

    private func send(conn: NWConnection, status: String, type: String, body: Data, method: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        if method == "HEAD" {
            conn.send(content: Data(head.utf8), contentContext: .defaultMessage, isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, contentContext: .defaultMessage, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }
}
