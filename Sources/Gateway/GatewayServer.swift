import Foundation
import Network
import Security
import CryptoKit

/// OpenAI 兼容本地网关（/v1/models · /v1/chat/completions 流式+非流式 · /healthz）
final class GatewayServer: ObservableObject {
    static let shared = GatewayServer()
    private let engine = DoubaoEngine.shared

    @Published var running = false
    @Published var portText: String
    @Published var apiKey: String

    private var listener: NWListener?
    private var convStates: [String: ConvState] = [:]
    private var statesURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("doubao_gateway_states.json")
    }

    init() {
        let d = UserDefaults.standard
        portText = d.string(forKey: "harness.gateway.port") ?? "8788"
        if let k = d.string(forKey: "harness.gateway.key"), !k.isEmpty {
            apiKey = k
        } else {
            apiKey = Self.randomHex(24)
            d.set(apiKey, forKey: "harness.gateway.key")
        }
        loadStates()
    }

    var lanAddress: String? { Self.lanIPv4() }

    var localURL: String { "http://127.0.0.1:\(portText)/v1" }

    func savePort() { UserDefaults.standard.set(portText, forKey: "harness.gateway.port") }

    func regenerateKey() {
        apiKey = Self.randomHex(24)
        UserDefaults.standard.set(apiKey, forKey: "harness.gateway.key")
    }

    func start() {
        guard !running else { return }
        let port = UInt16(portText) ?? 8788
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    self.running = true
                    HarnessLog.shared.add("[网关] 运行中 \(self.localURL)（局域网 \(self.lanAddress ?? "无")）")
                case .failed(let e):
                    self.running = false
                    HarnessLog.shared.add("[网关] 失败 \(e.localizedDescription)")
                default: break
                }
            }
            l.start(queue: .global(qos: .utility))
            listener = l
        } catch {
            HarnessLog.shared.add("[网关] 启动失败 \(error.localizedDescription)")
            running = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        HarnessLog.shared.add("[网关] 已停止")
    }

    // MARK: - 连接与请求解析
    private final class Buf { var data = Data() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        let buf = Buf()
        recv(conn, buf)
    }

    private func recv(_ conn: NWConnection, _ buf: Buf) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, err in
            guard let self else { return }
            if let d = data, !d.isEmpty {
                buf.data.append(d)
                if let req = Self.parseRequest(buf.data) {
                    self.route(req, conn)
                    return
                }
            }
            if complete || err != nil {
                if let req = Self.parseRequest(buf.data) { self.route(req, conn) } else { conn.cancel() }
                return
            }
            self.recv(conn, buf)
        }
    }

    struct Req {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
        var body: Data
    }

    static func parseRequest(_ data: Data) -> Req? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = data.subdata(in: data.startIndex..<headEnd.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let target = parts[1]
        var path = target, query = ""
        if let qi = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<qi])
            query = String(target[target.index(after: qi)...])
        }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let ci = l.firstIndex(of: ":") {
                let k = String(l[l.startIndex..<ci]).trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(l[l.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        let bodyData = data.subdata(in: headEnd.upperBound..<data.endIndex)
        let cl = Int(headers["content-length"] ?? "") ?? 0
        if cl > 0 && bodyData.count < cl { return nil }
        return Req(method: method, path: path, query: query, headers: headers, body: bodyData)
    }

    // MARK: - 路由
    private func route(_ req: Req, _ conn: NWConnection) {
        let p = req.path
        if req.method == "OPTIONS" {
            let head = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization, x-api-key\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        if p.hasSuffix("/models") {
            guard authOK(req) else { return respond(conn, "401 Unauthorized", errJSON("无效的 API Key")) }
            respond(conn, "200 OK", modelsJSON())
            return
        }
        if req.method == "GET" && (p == "/healthz" || p == "/readyz") {
            respond(conn, "200 OK", json(["status": "ok", "engine": engine.phaseText, "busy": engine.busy]))
            return
        }
        if p.hasSuffix("/chat/completions") || p.hasSuffix("/completions") {
            guard authOK(req) else { return respond(conn, "401 Unauthorized", errJSON("无效的 API Key")) }
            handleChat(req, conn)
            return
        }
        respond(conn, "404 Not Found", errJSON("未知路径 \(p)"))
    }

    private func authOK(_ req: Req) -> Bool {
        if apiKey.isEmpty { return true }
        if let a = req.headers["authorization"], a.lowercased().hasPrefix("bearer ") {
            return String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces) == apiKey
        }
        if let k = req.headers["x-api-key"] { return k == apiKey }
        if req.query.contains("api_key=") || req.query.contains("key=") {
            for kv in req.query.components(separatedBy: "&") {
                let pp = kv.components(separatedBy: "=")
                if pp.count == 2, (pp[0] == "api_key" || pp[0] == "key") { return pp[1] == apiKey }
            }
        }
        return false
    }

    private func modelsJSON() -> Data {
        let data: [[String: Any]] = DoubaoModels.list.map {
            ["id": $0, "object": "model", "created": 1700000000, "owned_by": "doubao-web"]
        }
        return json(["object": "list", "data": data])
    }

    // MARK: - 对话（只取最后一条 user 消息；多轮靠豆包服务端会话 + App 侧状态映射 · 规格 §3.4/§8）
    private func handleChat(_ req: Req, _ conn: NWConnection) {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return respond(conn, "400 Bad Request", errJSON("请求体不是合法 JSON"))
        }
        let model = body["model"] as? String ?? "doubao-chat"
        let stream = (body["stream"] as? Bool) ?? false
        let messages = body["messages"] as? [[String: Any]] ?? []
        var systemHead = ""
        var firstUser = ""
        var lastUser = ""
        for m in messages {
            let role = m["role"] as? String ?? ""
            let content = Self.msgText(m["content"])
            if role == "system", systemHead.isEmpty { systemHead = String(content.prefix(200)) }
            if role == "user" {
                if firstUser.isEmpty { firstUser = content }
                lastUser = content
            }
        }
        guard !lastUser.isEmpty else {
            return respond(conn, "400 Bad Request", errJSON("messages 中没有 user 消息"))
        }
        let key = Self.sessionKey(systemHead: systemHead, firstUser: firstUser, model: model)
        let state = convStates[key] ?? ConvState()
        let ability: DoubaoAbility = {
            let m = model.lowercased()
            if m.contains("video") || m.contains("seedance") {
                let s = UserDefaults.standard.integer(forKey: "harness.video.seconds")
                return .video(seconds: s == 0 ? 10 : s)
            }
            if m.contains("image") { return .image }
            return .chat
        }()
        let cmplId = "chatcmpl-" + Self.randomHex(10)
        let created = Int(Date().timeIntervalSince1970)
        let t0 = Date()

        var accText = ""
        var images: [String] = []
        let sseQueue = DispatchQueue(label: "gw.sse.\(cmplId)")

        func sseChunk(_ delta: [String: Any], finish: String? = nil) -> Data {
            var c: [String: Any] = ["index": 0, "delta": delta, "finish_reason": finish ?? NSNull()]
            let frame: [String: Any] = ["id": cmplId, "object": "chat.completion.chunk", "created": created,
                                        "model": model, "choices": [c]]
            if let d = try? JSONSerialization.data(withJSONObject: frame) {
                return Data("data: ".utf8) + d + Data("\n\n".utf8)
            }
            return Data()
        }

        if stream {
            sseQueue.async {
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                var first = Data(head.utf8)
                first += sseChunk(["role": "assistant"])
                conn.send(content: first, completion: .contentProcessed { _ in })
            }
        }

        Task {
            let (out, newState) = await self.engine.streamChat(text: lastUser, model: model, ability: ability,
                state: state,
                onDelta: { delta in
                    accText += delta
                    if stream {
                        sseQueue.async { conn.send(content: sseChunk(["content": delta]), completion: .contentProcessed { _ in }) }
                    }
                },
                onImage: { url in
                    images.append(url)
                    if stream {
                        let md = "\n\n![generated](\(url))\n\n"
                        sseQueue.async { conn.send(content: sseChunk(["content": md]), completion: .contentProcessed { _ in }) }
                    }
                })
            self.convStates[key] = newState
            self.saveStates()

            if let e = out.error {
                HarnessLog.shared.add("[网关] 上游错误 model=\(model) \(e.prefix(200))")
                if stream {
                    let errFrame = "{\"error\":{\"message\":\(Self.jstr(e)),\"type\":\"doubao_error\"}}"
                    let tail = Data("data: ".utf8) + Data(errFrame.utf8) + Data("\n\ndata: [DONE]\n\n".utf8)
                    sseQueue.async { conn.send(content: tail, completion: .contentProcessed { _ in conn.cancel() }) }
                } else {
                    self.respond(conn, "500 Internal Server Error", self.errJSON(e))
                }
                return
            }

            if stream {
                let tail = sseChunk([:], finish: "stop") + Data("data: [DONE]\n\n".utf8)
                sseQueue.async { conn.send(content: tail, completion: .contentProcessed { _ in conn.cancel() }) }
            } else {
                var content = accText
                for u in images { content += "\n\n![generated](\(u))" }
                var msg: [String: Any] = ["role": "assistant", "content": content]
                var extra: [String: Any] = [:]
                if !images.isEmpty { extra["images"] = images }
                if !out.videoURLs.isEmpty { extra["videos"] = out.videoURLs }
                let prompt = Self.msgText(lastUser as NSString) as String
                let usage: [String: Any] = [
                    "prompt_tokens": prompt.count,
                    "completion_tokens": content.count,
                    "total_tokens": prompt.count + content.count
                ]
                var resp: [String: Any] = ["id": cmplId, "object": "chat.completion", "created": created,
                                           "model": model,
                                           "choices": [["index": 0, "message": msg, "finish_reason": "stop"]],
                                           "usage": usage]
                for (k, v) in extra { resp[k] = v }
                self.respond(conn, "200 OK", self.json(resp))
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            HarnessLog.shared.add("[网关] 完成 model=\(model) stream=\(stream) text=\(accText.count)字 图=\(images.count) \(ms)ms")
        }
    }

    // MARK: - 工具
    private func respond(_ conn: NWConnection, _ status: String, _ body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        // 冲刷后关闭（防丢尾包，鲸聊 v1.0.17 教训）
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.send(content: Data(), completion: .contentProcessed { _ in conn.cancel() })
        })
    }

    private func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])) ?? Data("{}".utf8)
    }

    private func errJSON(_ msg: String) -> Data {
        json(["error": ["message": msg, "type": "gateway_error"]])
    }

    static func jstr(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }

    static func msgText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            var out = ""
            for p in arr {
                let t = (p["type"] as? String) ?? "text"
                if t == "text" || t == "input_text" {
                    out += (p["text"] as? String) ?? ""
                }
            }
            return out
        }
        if let d = content as? [String: Any] {
            if let t = d["text"] as? String { return t }
            if let s = (try? JSONSerialization.data(withJSONObject: d)).flatMap({ String(data: $0, encoding: .utf8) }) {
                return s
            }
        }
        return ""
    }

    static func sessionKey(systemHead: String, firstUser: String, model: String) -> String {
        let seed = systemHead + "\u{1}" + firstUser + "\u{1}" + model
        let d = SHA256.hash(data: Data(seed.utf8))
        return d.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func lanIPv4() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, (sa.pointee.sa_family == UInt8(AF_INET)) {
                let name = String(cString: ifa.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: host)
                        if s != "127.0.0.1" { addr = s; break }
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return addr
    }

    // MARK: - 状态持久化
    private func loadStates() {
        guard let d = try? Data(contentsOf: statesURL),
              let m = try? JSONDecoder().decode([String: ConvState].self, from: d) else { return }
        convStates = m
    }

    private func saveStates() {
        if let d = try? JSONEncoder().encode(convStates) {
            try? d.write(to: statesURL, options: .atomic)
        }
    }
}
