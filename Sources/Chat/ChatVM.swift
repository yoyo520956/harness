import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID().uuidString
    var role: Role
    var text: String = ""
    var images: [String] = []
    var videoURL: String? = nil
    var suggestions: [String] = []
    var time = Date()
    var streaming = false
}

struct ChatConversation: Identifiable, Codable {
    var id = UUID().uuidString
    var title = "新会话"
    var messages: [ChatMessage] = []
    var state = ConvState()
    var updatedAt = Date()
}

@MainActor
final class ChatVM: ObservableObject {
    @Published var conversations: [ChatConversation] = []
    @Published var currentId = ""
    @Published var sending = false

    private var saveURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("harness_chats.json")
    }

    init() {
        if let d = try? Data(contentsOf: saveURL),
           let cs = try? JSONDecoder().decode([ChatConversation].self, from: d), !cs.isEmpty {
            conversations = cs
            currentId = cs[0].id
        } else {
            newConversation(persistNow: false)
        }
    }

    var current: ChatConversation {
        conversations.first(where: { $0.id == currentId }) ?? conversations.first ?? ChatConversation()
    }

    func newConversation(persistNow: Bool = true) {
        let c = ChatConversation()
        conversations.insert(c, at: 0)
        currentId = c.id
        if persistNow { persist() }
    }

    func select(_ id: String) { currentId = id }

    func delete(at offsets: IndexSet) {
        for i in offsets where conversations[i].id == currentId { currentId = "" }
        conversations.remove(atOffsets: offsets)
        if conversations.isEmpty { newConversation(persistNow: false) }
        persist()
    }

    func model(for ability: DoubaoAbility) -> String {
        switch ability {
        case .chat: return "doubao-chat"
        case .image: return "doubao-image"
        case .video: return "doubao-video"
        }
    }

    func send(_ text: String, ability: DoubaoAbility) async {
        guard !sending, !text.isEmpty else { return }
        if conversations.isEmpty { newConversation(persistNow: false) }
        guard let ci = conversations.firstIndex(where: { $0.id == currentId }) else { return }
        sending = true
        var user = ChatMessage(role: .user)
        user.text = text
        var ai = ChatMessage(role: .assistant)
        ai.streaming = true
        if conversations[ci].title == "新会话" { conversations[ci].title = String(text.prefix(18)) }
        conversations[ci].messages.append(user)
        conversations[ci].messages.append(ai)
        let mi = conversations[ci].messages.count - 1
        let convId = currentId
        let state = conversations[ci].state
        let m = model(for: ability)

        func patch(_ body: @escaping (inout ChatMessage) -> Void) {
            Task { @MainActor in
                guard let c = self.conversations.firstIndex(where: { $0.id == convId }) else { return }
                guard self.conversations[c].messages.indices.contains(mi) else { return }
                body(&self.conversations[c].messages[mi])
            }
        }

        let out = await DoubaoEngine.shared.streamChat(
            text: text, model: m, ability: ability, state: state,
            onDelta: { d in patch { $0.text += d } },
            onImage: { url in patch { $0.images.append(url) } }
        )

        if let c = conversations.firstIndex(where: { $0.id == convId }),
           conversations[c].messages.indices.contains(mi) {
            conversations[c].state = out.1
            var msg = conversations[c].messages[mi]
            msg.streaming = false
            if msg.text.isEmpty, let e = out.0.error { msg.text = "⚠️ " + e }
            if msg.images.count < out.0.images.count { msg.images = out.0.images }
            if msg.videoURL == nil { msg.videoURL = out.0.videoURLs.first }
            if !out.0.suggestions.isEmpty { msg.suggestions = out.0.suggestions }
            conversations[c].messages[mi] = msg
            conversations[c].updatedAt = Date()
        }
        sending = false
        persist()
    }

    func stopAllStreaming() {
        for i in conversations.indices {
            for j in conversations[i].messages.indices where conversations[i].messages[j].streaming {
                conversations[i].messages[j].streaming = false
            }
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(conversations) {
            try? d.write(to: saveURL, options: .atomic)
        }
    }
}
