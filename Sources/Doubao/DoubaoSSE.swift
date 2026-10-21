import Foundation

// MARK: - 会话状态（豆包服务端持有上下文，客户端只发最后一条 user 消息 · 规格 §3.4）
struct ConvState: Codable, Equatable {
    var localConversationId: String = ""
    var conversationId: String = ""
    var sectionId: String = ""
    var lastMessageIndex: Int? = nil
    var needCreate: Bool = true
}

struct StreamOutcome {
    var text: String = ""
    var images: [String] = []
    var vids: [String] = []
    var videoURLs: [String] = []
    var suggestions: [String] = []
    var brief: String = ""
    var error: String? = nil
}

enum DoubaoAbility: Equatable {
    case chat
    case image
    case video(seconds: Int)
}

enum DoubaoModels {
    static let defaultBotId = "7338286299411103781"
    static let list = ["doubao-chat", "doubao-pro", "doubao-image", "doubao-video"]
    static func botId(for model: String) -> String {
        let t = model.trimmingCharacters(in: .whitespaces)
        if t.count >= 18, Int(t) != nil { return t }   // 纯数字长串直接当 bot_id
        return defaultBotId
    }
}

// MARK: - Payload 构建（规格 §3.3 四大块逐字段照抄）
enum DoubaoPayload {
    static func build(text: String, state: ConvState, model: String, ability: DoubaoAbility) -> [String: Any] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let localId = state.localConversationId.isEmpty ? newLocalConvId(nowMs) : state.localConversationId
        var payload: [String: Any] = [
            "client_meta": [
                "local_conversation_id": localId,
                "conversation_id": state.conversationId,
                "bot_id": DoubaoModels.botId(for: model),
                "last_section_id": state.sectionId,
                "last_message_index": state.lastMessageIndex.map { $0 as Any } ?? NSNull()
            ],
            "messages": [[
                "local_message_id": UUID().uuidString,
                "content_block": [[
                    "block_type": 10000,
                    "content": [
                        "text_block": ["text": text, "icon_url": "", "icon_url_dark": "", "summary": ""],
                        "pc_event_block": ""
                    ],
                    "block_id": UUID().uuidString,
                    "parent_id": "",
                    "meta_info": [Any](),
                    "append_fields": [Any]()
                ] as [String: Any]],
                "message_status": 0
            ] as [String: Any]],
            "option": option(nowMs: nowMs, needCreate: state.needCreate),
            "ext": [
                "use_deep_think": "0",
                "fp": "doubao2api_default_fp",
                "commerce_credit_config_enable": "0",
                "sub_conv_firstmet_type": "0"
            ]
        ]
        if case .video(let secs) = ability {
            let d = max(5, min(15, secs))
            payload["chat_ability"] = ["ability_type": 17,
                                       "ability_param": "{\"model\":\"seedance_v2.0\",\"duration\":\(d)}"]
        }
        return payload
    }

    private static func option(nowMs: Int64, needCreate: Bool) -> [String: Any] {
        [
            "send_message_scene": "",
            "create_time_ms": nowMs,
            "collect_id": "",
            "is_audio": false,
            "answer_with_suggest": false,
            "tts_switch": false,
            "need_deep_think": 0,
            "click_clear_context": false,
            "from_suggest": false,
            "is_regen": false,
            "is_replace": false,
            "disable_sse_cache": false,
            "select_text_action": "",
            "resend_for_regen": false,
            "scene_type": 0,
            "unique_key": UUID().uuidString,
            "start_seq": 0,
            "need_create_conversation": needCreate,
            "regen_query_id": [Any](),
            "edit_query_id": [Any](),
            "regen_instruction": "",
            "no_replace_for_regen": false,
            "message_from": 0,
            "shared_app_name": "",
            "sse_recv_event_options": ["support_chunk_delta": true],
            "is_ai_playground": false,
            "recovery_option": ["is_recovery": false, "req_create_time_sec": nowMs / 1000]
        ]
    }

    static func newLocalConvId(_ nowMs: Int64) -> String {
        "local_\(nowMs)\(String(format: "%06x", arc4random() & 0xFFFFFF))"
    }
}

// MARK: - SSE 解析（规格 §3.5 八事件 + §3.7 双路文本来源锁 + §4 图 2074 + §5 vid 深搜）
final class DoubaoSSEParser {
    enum TextSource { case none, delta, patch }
    private(set) var outcome = StreamOutcome()
    private(set) var finished = false
    private(set) var ackConvId = ""
    private(set) var ackSectionId = ""
    private(set) var ackUserIndex: Int?
    private(set) var metaIndex: Int?
    private var textSource: TextSource = .none

    func feed(ev: String, data: String) {
        switch ev {
        case "SSE_ACK":
            if let d = json(data) {
                if let m = d["ack_client_meta"] as? [String: Any] {
                    ackConvId = m["conversation_id"] as? String ?? ""
                    ackSectionId = m["section_id"] as? String ?? ""
                }
                if let q = d["query_list"] as? [[String: Any]], !q.isEmpty {
                    ackUserIndex = Self.asInt(q[0]["message_index"])
                }
            }
        case "STREAM_MSG_NOTIFY":
            if let d = json(data) {
                if let m = d["meta"] as? [String: Any] { metaIndex = Self.asInt(m["index_in_conv"]) }
                if let c = d["content"] as? [String: Any] {
                    // HongYan789 兜底：首段文本可能在 content / model_content / tts_content
                    for k in ["content", "model_content", "tts_content"] {
                        if let t = c[k] as? String, !t.isEmpty { appendPatch(t); break }
                    }
                    if let blocks = c["content_block"] as? [[String: Any]] { patchBlocks(blocks) }
                }
            }
        case "CHUNK_DELTA":
            if textSource == .patch { return }   // 来源锁：patch 先出，delta 丢弃防重复
            if let d = json(data), let t = d["text"] as? String {
                textSource = .delta
                outcome.text += t
            }
        case "STREAM_CHUNK":
            if let d = json(data), let ops = d["patch_op"] as? [[String: Any]] {
                for op in ops { patchOp(op) }
            }
        case "SSE_REPLY_END":
            if let d = json(data) {
                let endType = Self.asInt(d["end_type"]) ?? 0
                if endType >= 1 {
                    finished = true
                    if let m = d["msg_finish_attr"] as? [String: Any], let b = m["brief"] as? String {
                        outcome.brief = b
                    }
                }
            }
        case "STREAM_ERROR":
            if let d = json(data) { outcome.error = d["error_msg"] as? String ?? "STREAM_ERROR" }
            finished = true
        default:
            break
        }
    }

    private func patchOp(_ op: [String: Any]) {
        let obj = Self.asInt(op["patch_object"]) ?? 0
        let v = op["patch_value"]
        switch obj {
        case 1:
            if let pv = v as? [String: Any], let blocks = pv["content_block"] as? [[String: Any]] {
                patchBlocks(blocks)
            }
        case 3:
            if let pv = v as? [String: Any], let m = pv["msg_finish_attr"] as? [String: Any],
               let b = m["brief"] as? String { outcome.brief = b }
        case 102:
            if let pv = v as? [String: Any], let s = pv["content"] as? String,
               let inner = json(s), let t = inner["text"] as? String { appendPatch(t) }
        case 50:
            if let pv = v as? [String: Any], let ext = pv["ext"] as? [String: Any], let sp = ext["sp_v2"] as? String {
                extractSuggestions(sp)
            }
        default:
            break
        }
        deepSearchVid(v)
    }

    private func patchBlocks(_ blocks: [[String: Any]]) {
        for b in blocks {
            let bt = Self.asInt(b["block_type"]) ?? 0
            if bt == 10000 {
                if textSource == .delta { continue }   // 来源锁
                if let c = b["content"] as? [String: Any], let tb = c["text_block"] as? [String: Any],
                   let t = tb["text"] as? String, !t.isEmpty { appendPatch(t) }
            } else if bt == 2074 {
                extractImages(b)
            }
        }
    }

    private func appendPatch(_ t: String) {
        if textSource == .none { textSource = .patch }
        if textSource == .patch { outcome.text += t }
    }

    private func extractImages(_ b: [String: Any]) {
        guard let c = b["content"] as? [String: Any], let cb = c["creation_block"] as? [String: Any],
              let crs = cb["creations"] as? [[String: Any]] else { return }
        for cr in crs {
            guard let img = cr["image"] as? [String: Any] else { continue }
            let raw = (img["image_ori_raw"] as? [String: Any])?["url"] as? String
            let ori = (img["image_ori"] as? [String: Any])?["url"] as? String
            let plain = img["image_url"] as? String
            if let u = raw ?? ori ?? plain, !u.isEmpty, !outcome.images.contains(u) {
                outcome.images.append(u)
            }
        }
    }

    private func extractSuggestions(_ sp: String) {
        guard let d = json(sp) else { return }
        func walk(_ o: Any) {
            if let a = o as? [Any] { for x in a { walk(x) } }
            else if let m = o as? [String: Any] {
                if let t = m["text"] as? String, !t.isEmpty,
                   !outcome.suggestions.contains(t), outcome.suggestions.count < 6 {
                    outcome.suggestions.append(t)
                }
                for (_, v) in m { walk(v) }
            }
        }
        walk(d)
    }

    private func deepSearchVid(_ o: Any?) {
        if let d = o as? [String: Any] {
            for (k, v) in d {
                if (k == "vid" || k == "video_id"), let s = v as? String,
                   s.hasPrefix("v0"), !outcome.vids.contains(s) {
                    outcome.vids.append(s)
                }
                deepSearchVid(v)
            }
        } else if let a = o as? [Any] {
            for v in a { deepSearchVid(v) }
        }
    }

    private func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func asInt(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
