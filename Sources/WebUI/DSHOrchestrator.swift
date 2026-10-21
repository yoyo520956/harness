import Foundation

/// DSH RPC 编排器：把 Web UI 的全部 endpoint 请求翻译到本地状态与豆包引擎。
/// 静态契约直接作答；prompt 驱动 DoubaoEngine 并按 Session 事件日志协议回放。
final class DSHOrchestrator: ObservableObject {
    static let shared = DSHOrchestrator()

    // MARK: - 会话状态
    final class Session {
        let id: String
        var title: String
        let createdAt: Double
        var updatedAt: Double
        var records: [[String: Any]] = []
        var nextSeq = 1
        var running = false
        var conv = ConvState()
        var engineTask: Task<Void, Never>?
        var attemptId = ""
        var streamIndex = 0
        var streamRevision = 0
        var pendingChunks: [[String: Any]] = []
        init(id: String, title: String) {
            self.id = id
            self.title = title
            self.createdAt = Date().timeIntervalSince1970 * 1000
            self.updatedAt = self.createdAt
        }
    }

    private(set) var sessions: [String: Session] = [:]
    private var followStreams: [String: String] = [:]      // streamId -> sessionId
    private var controlStreams: Set<String> = []
    private var eventStreams: Set<String> = []
    private var eventClientId = "cli-" + UUID().uuidString.prefix(8)
    private var streams: [String: StreamHandle] = [:]

    final class StreamHandle {
        let id: String
        let bridge: DSHBridge
        init(id: String, bridge: DSHBridge) { self.id = id; self.bridge = bridge }
        func push(_ value: Any) {
            bridge.postStream(["streamId": id, "type": "data", "value": value])
        }
        func end() {
            bridge.postStream(["streamId": id, "type": "end"])
        }
        func fail(_ message: String) {
            bridge.postStream(["streamId": id, "type": "error", "error": ["code": "gateway/internal", "message": message, "details": [:]]])
        }
    }

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dsh_sessions.json")
    }

    private init() {
        loadStore()
        if sessions.isEmpty {
            _ = createSessionLocked(title: "新会话")
        }
    }

    // MARK: - RPC 入口
    func handleCall(id: String, method: String, payload: Any?, bridge: DSHBridge) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let args = (payload as? [String: Any])?["args"] as? [Any] ?? []
            let value = dispatchUnary(method: method, args: args)
            bridge.post(["id": id, "ok": true, "value": value])
        }
    }

    func handleOpen(streamId: String, method: String, payload: Any?, bridge: DSHBridge) {
        let handle = StreamHandle(id: streamId, bridge: bridge)
        streams[streamId] = handle
        let args = (payload as? [String: Any])?["args"] as? [Any] ?? []
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            dispatchStream(method: method, args: args, handle: handle)
        }
    }

    func handleClose(streamId: String) {
        if let sid = followStreams.removeValue(forKey: streamId) {
            HarnessLog.shared.add("[DSH] follow 关闭 \(sid.prefix(8))")
        }
        controlStreams.remove(streamId)
        eventStreams.remove(streamId)
        streams.removeValue(forKey: streamId)
    }

    // MARK: - Unary 分发
    private func dispatchUnary(method: String, args: [Any]) -> Any {
        switch method {
        case "session/list":
            return ["items": sessionSummaries()]
        case "session/create":
            let s = createSession()
            return ["sessionId": s.id, "agentPreset": NSNull()]
        case "session/prompt":
            return prompt(args: args)
        case "session/cancel":
            if let a = args.first as? [String: Any], let sid = a["sessionId"] as? String {
                cancelRun(sessionId: sid)
            }
            return ["accepted": true]
        case "session/rename":
            if let a = args.first as? [String: Any], let sid = a["sessionId"] as? String,
               let title = a["title"] as? String, let s = sessions[sid] {
                s.title = title
                s.updatedAt = now()
                saveStore()
                emitEvent("api-session/added", [summary(s)])
            }
            return [:]
        case "session/page":
            return page(args: args)
        case "session/projections":
            let sid = (args.first as? [String: Any])?["sessionId"] as? String ?? ""
            return ["kind": "sequenced", "asOfSeq": sessions[sid]?.nextSeq ?? 0, "values": [:]]
        case "session/modelCatalog":
            return modelCatalog()
        case "session/search":
            return ["items": []]
        case "session/canOpenWorkspacePath":
            return false
        case "session/attachment", "session/updateQueue", "session/selectModel", "session/fork",
             "session/openWorkspacePath", "session/workspacePathApplications",
             "session/fileReferences/list", "session/skills/list":
            return [:]
        case "session/initializeDefaultModel":
            return [:]
        case "settings/describe":
            return ["writable": false, "hasDocument": false, "namespaces": []]
        case "$events/result":
            return [:]
        case "terminal/list", "terminal/profiles":
            return ["items": []]
        case "job/list":
            return ["items": []]
        case "account/describe", "deepseek-account/describe":
            return [:]
        default:
            HarnessLog.shared.add("[DSH] 未实现 endpoint: \(method)")
            return [:]
        }
    }

    // MARK: - Stream 分发
    private func dispatchStream(method: String, args: [Any], handle: StreamHandle) {
        switch method {
        case "$events":
            eventStreams.insert(handle.id)
            handle.push(["type": "ready", "clientId": eventClientId, "host": ["home": "/"]])
        case "session/control":
            controlStreams.insert(handle.id)
            var projections: [String: Any] = [:]
            for s in sessions.values {
                projections[s.id] = ["asOfSeq": s.nextSeq, "values": [:]]
            }
            handle.push(["type": "baseline", "value": ["projections": projections]])
        case "session/follow":
            followStream(args: args, handle: handle)
        case "job/attach", "terminal/attach", "workspace/follow", "remoteAccess/follow":
            // v1：立即结束，UI 侧对应面板留空
            handle.end()
        default:
            HarnessLog.shared.add("[DSH] 未实现 stream: \(method)")
            handle.end()
        }
    }

    private func followStream(args: [Any], handle: StreamHandle) {
        let req = args.first as? [String: Any] ?? [:]
        let address = req["address"] as? [String: Any] ?? [:]
        let sid = address["sessionId"] as? String ?? ""
        guard let s = sessions[sid] else {
            handle.fail("unknown session \(sid)")
            return
        }
        followStreams[handle.id] = sid
        let wantAssistant = (req["assistantStream"] as? Bool) == true
        let header: [String: Any] = [
            "version": 1, "id": s.id, "createdAt": s.createdAt, "isSeeded": false,
        ]
        var snap: [String: Any] = [
            "type": "snapshot",
            "header": header,
            "cursor": s.nextSeq - 1,
            "records": s.records,
            "hasMore": false,
            "projections": ["asOfSeq": s.nextSeq - 1, "values": [:]],
        ]
        if wantAssistant, s.running {
            snap["assistantStream"] = ["revision": s.streamRevision]
        }
        handle.push(snap)
        HarnessLog.shared.add("[DSH] follow 打开 \(sid.prefix(8)) records=\(s.records.count)")
    }

    // MARK: - Prompt 主流程
    private func prompt(args: [Any]) -> [String: Any] {
        let req = args.first as? [String: Any] ?? [:]
        let sid = req["sessionId"] as? String ?? ""
        guard let s = sessions[sid] else { return ["accepted": false] }
        guard !s.running else {
            HarnessLog.shared.add("[DSH] 会话忙，忽略 prompt")
            return ["accepted": true]
        }
        var text = ""
        if let content = req["content"] as? [[String: Any]] {
            for part in content where (part["type"] as? String) == "text" {
                text += part["text"] as? String ?? ""
            }
        }
        appendEvent(s, type: "turn/start", data: ["turn": s.nextSeq])
        appendEvent(s, type: "step/start", data: ["turn": s.records.count, "step": 1])
        let userMsg: [String: Any] = [
            "id": "m" + UUID().uuidString.prefix(12),
            "role": "user",
            "content": [["type": "text", "text": text]],
            "source": ["kind": "user"],
        ]
        appendEvent(s, type: "user/message", data: userMsg)
        s.running = true
        s.attemptId = "a" + UUID().uuidString.prefix(10)
        s.streamIndex = 0
        s.streamRevision += 1
        s.pendingChunks = []
        emitEvent("api-session/status", [s.id])
        broadcastAssistant(s, ["type": "start", "attemptId": s.attemptId, "revision": s.streamRevision,
                               "startedAfterSeq": s.nextSeq - 1, "turn": 1, "step": 1])
        let textCopy = text
        s.engineTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runEngine(sessionId: sid, text: textCopy)
        }
        saveStore()
        return ["accepted": true]
    }

    private func runEngine(sessionId: String, text: String) async {
        guard bridges.first != nil else { return }
        let model = UserDefaults.standard.string(forKey: "dsh.model") ?? "doubao-chat"
        let ability: DoubaoAbility
        switch model {
        case "doubao-image": ability = .image
        case "doubao-video": ability = .video(seconds: 5)
        default: ability = .chat
        }
        let state = sessions[sessionId]?.conv ?? ConvState()
        let (outcome, conv) = await DoubaoEngine.shared.streamChat(
            text: text, model: model, ability: ability, state: state,
            onDelta: { [weak self] delta in
                self?.engineDelta(sessionId: sessionId, delta: delta)
            },
            onImage: { [weak self] url in
                self?.engineDelta(sessionId: sessionId, delta: "\n\n![图片](\(url))")
            })
        Task { @MainActor in
            self.engineFinished(sessionId: sessionId, outcome: outcome, conv: conv)
        }
    }

    private var bridges: [DSHBridge] { bridgeRefs }

    private var bridgeRefs: [DSHBridge] {
        bridgeBox.allObjects.compactMap { $0 as? DSHBridge }
    }
    private let bridgeBox = NSHashTable<AnyObject>.weakObjects()

    func register(bridge: DSHBridge) { bridgeBox.add(bridge) }

    private func engineDelta(sessionId: String, delta: String) {
        guard let s = sessions[sessionId] else { return }
        let idx = s.streamIndex
        s.streamIndex += 1
        let rec: [String: Any] = [
            "type": "text-chunks", "time0": now(), "index": idx, "dt": [0], "texts": [delta],
        ]
        s.pendingChunks.append(rec)
        broadcastAssistant(s, ["type": "chunk", "attemptId": s.attemptId, "revision": s.streamRevision,
                               "index": idx, "time": now(), "chunk": ["type": "text-delta", "text": delta]])
    }

    private func engineFinished(sessionId: String, outcome: StreamOutcome, conv: ConvState) {
        guard let s = sessions[sessionId] else { return }
        s.conv = conv
        let full = outcome.text + outcome.images.map { "\n\n![图片](\($0))" }.joined()
        let finalText = full.isEmpty ? "（豆包没有返回内容，请检查账号登录状态）" : full
        var blocks: [[String: Any]] = []
        // 深度思考块：豆包 SSE 的 reasoning 已并入正文时跳过；v0.4 先按纯文本投递
        blocks.append(["type": "text", "text": finalText])
        let msg: [String: Any] = [
            "id": "m" + UUID().uuidString.prefix(12),
            "role": "assistant",
            "content": blocks,
            "source": ["kind": "model"],
        ]
        let turn = s.records.count
        appendEvent(s, type: "step/end", data: ["turn": turn, "step": 1])
        appendEvent(s, type: "assistant/message", data: [
            "turn": turn, "step": 1, "message": msg, "stream": s.pendingChunks,
        ])
        appendEvent(s, type: "turn/end", data: ["turn": turn, "reason": "stop"])
        broadcastAssistant(s, ["type": "end", "attemptId": s.attemptId, "revision": s.streamRevision,
                               "index": s.streamIndex,
                               "outcome": ["kind": "committed", "eventType": "assistant/message", "seq": s.nextSeq - 1]])
        s.running = false
        s.updatedAt = now()
        if s.title == "新会话", finalText.count > 3 {
            s.title = String(finalText.prefix(24))
        }
        emitEvent("api-session/added", [summary(s)])
        emitEvent("api-session/status", [s.id])
        saveStore()
    }

    private func cancelRun(sessionId: String) {
        guard let s = sessions[sessionId], s.running else { return }
        s.engineTask?.cancel()
        broadcastAssistant(s, ["type": "end", "attemptId": s.attemptId, "revision": s.streamRevision,
                               "index": s.streamIndex, "outcome": ["kind": "abandoned"]])
        appendEvent(s, type: "turn/end", data: ["turn": s.records.count, "reason": "cancelled"])
        s.running = false
        saveStore()
    }

    // MARK: - 事件工具
    @discardableResult
    private func appendEvent(_ s: Session, type: String, data: Any) -> Int {
        let seq = s.nextSeq
        s.nextSeq += 1
        let ev: [String: Any] = [
            "type": type, "seq": seq, "time": now(), "data": data,
        ]
        s.records.append(["type": "event", "event": ev])
        s.updatedAt = now()
        pushFollow(s, ["type": "event", "event": ev])
        pushControl(s)
        return seq
    }

    private func pushFollow(_ s: Session, _ frame: [String: Any]) {
        for (streamId, sid) in followStreams where sid == s.id {
            streams[streamId]?.push(frame)
        }
    }

    private func broadcastAssistant(_ s: Session, _ frame: [String: Any]) {
        pushFollow(s, ["type": "assistant-stream", "frame": frame])
    }

    private func pushControl(_ s: Session) {
        guard !controlStreams.isEmpty else { return }
        let frame: [String: Any] = [
            "type": "projection", "sessionId": s.id, "key": "surface",
            "value": [:], "seq": s.nextSeq - 1,
        ]
        for sid in controlStreams {
            streams[sid]?.push(frame)
        }
    }

    private func emitEvent(_ event: String, _ args: [Any]) {
        for sid in eventStreams {
            streams[sid]?.push(["type": "emit", "event": event, "args": args])
        }
    }

    // MARK: - 视图构造
    private func summary(_ s: Session) -> [String: Any] {
        [
            "agentAvailable": true,
            "sessionId": s.id,
            "updatedAt": s.updatedAt,
            "running": s.running,
            "blank": s.records.isEmpty,
            "formatStatus": "current",
        ]
    }

    private func sessionSummaries() -> [[String: Any]] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }.map(summary)
    }

    private func page(args: [Any]) -> [String: Any] {
        let req = args.first as? [String: Any] ?? [:]
        let address = req["address"] as? [String: Any] ?? [:]
        let sid = address["sessionId"] as? String ?? ""
        guard let s = sessions[sid] else { return ["records": [], "hasMore": false] }
        return ["records": s.records, "hasMore": false]
    }

    private func modelCatalog() -> [String: Any] {
        [
            "providers": [[
                "id": "deepseek-account",
                "label": "豆包引擎",
                "models": DoubaoModels.list.map { m in
                    ["id": m, "label": m, "contextWindow": 128000, "available": true]
                },
            ]],
            "defaultModel": ["provider": "deepseek-account", "id": "doubao-chat"],
        ]
    }

    private func createSession() -> Session {
        let s = createSessionLocked(title: "新会话")
        emitEvent("api-session/added", [summary(s)])
        saveStore()
        return s
    }

    private func createSessionLocked(title: String) -> Session {
        let id = "s-" + UUID().uuidString.prefix(12)
        let s = Session(id: String(id), title: title)
        sessions[s.id] = s
        return s
    }

    private func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: - 持久化（JSONSerialization：records 含 Any 结构，走 Codable 不便）
    private func loadStore() {
        guard let data = try? Data(contentsOf: storeURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for r in raw {
            guard let id = r["id"] as? String else { continue }
            let s = Session(id: id, title: r["title"] as? String ?? "会话")
            s.records = r["records"] as? [[String: Any]] ?? []
            s.nextSeq = r["nextSeq"] as? Int ?? 1
            s.updatedAt = r["updatedAt"] as? Double ?? now()
            if let obj = r["conv"] as? [String: Any],
               let cd = try? JSONSerialization.data(withJSONObject: obj),
               let c = try? JSONDecoder().decode(ConvState.self, from: cd) {
                s.conv = c
            }
            sessions[s.id] = s
        }
    }

    private func saveStore() {
        let raw: [[String: Any]] = sessions.values.map { s in
            var r: [String: Any] = [
                "id": s.id, "title": s.title, "updatedAt": s.updatedAt,
                "nextSeq": s.nextSeq, "records": s.records,
            ]
            if let cd = try? JSONEncoder().encode(s.conv),
               let obj = try? JSONSerialization.jsonObject(with: cd) {
                r["conv"] = obj
            }
            return r
        }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }
        try? data.write(to: storeURL)
    }
}
