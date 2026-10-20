import SwiftUI
import AVKit

struct ChatView: View {
    @EnvironmentObject var theme: HarnessTheme
    @EnvironmentObject var engine: DoubaoEngine
    @EnvironmentObject var vm: ChatVM
    @State private var input = ""
    @State private var ability: DoubaoAbility = .chat
    @State private var showSessions = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.hairline).frame(height: 0.5)
            if vm.current.messages.isEmpty {
                hero
            } else {
                messageList
            }
            composer
        }
        .background(theme.bgBase)
        .preferredColorScheme(nil)
        .sheet(isPresented: $showSessions) { sessionsSheet }
    }

    // MARK: - 头部（规格 §8.1：76px 头部 + 发丝线 + 蓝指示条意象）
    private var header: some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.blue).frame(width: 22, height: 2).cornerRadius(2)
            Image("running_whale").resizable().scaledToFit().frame(width: 26, height: 26)
            Text(vm.current.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            Button { vm.newConversation() } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.labelSecondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.001), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Button { showSessions = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 16))
                    .foregroundStyle(theme.labelSecondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - 新会话 Hero（规格 §10：鲸鱼 + 探索未至之境 + 预览版徽标）
    private var hero: some View {
        ScrollView {
            VStack(spacing: 8) {
                Spacer(minLength: 54)
                Image("running_whale")
                    .resizable().scaledToFit().frame(width: 56, height: 56)
                HStack(spacing: 10) {
                    Text("探索未至之境")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Text("预览版")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.labelTertiary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(theme.navActive, in: Capsule())
                }
                Text(engine.phaseText)
                    .font(.system(size: 12))
                    .foregroundStyle(engine.phase == .pageReady ? theme.success : theme.labelTertiary)
                    .padding(.top, 4)
                Spacer(minLength: 90)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 聊天流（内容列 ≤920 居中 · 用户气泡 R20 · 助手无气泡）
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(vm.current.messages) { m in
                        MessageRow(m: m) { s in
                            Task { await vm.send(s, ability: .chat) }
                        }
                        .id(m.id)
                    }
                    Color.clear.frame(height: 4).id("h_bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: vm.current.messages.last?.text) { _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("h_bottom", anchor: .bottom) }
            }
            .onChange(of: vm.current.messages.count) { _ in
                proxy.scrollTo("h_bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Composer 输入卡（规格 §9：R28 面板 + 模型 chip + 34pt 蓝色发送圆钮）
    private var composer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
            HStack(alignment: .bottom, spacing: 10) {
                abilityChip
                TextField(composerPlaceholder, text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink)
                    .tint(theme.blue)
                    .padding(.vertical, 7)
                    .focused($focused)
                    .onSubmit { sendNow() }
                sendButton
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(theme.composerFill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(theme.bgBase)
    }

    private var composerPlaceholder: String {
        vm.current.messages.isEmpty
            ? "描述你想要构建的内容, / 调用指令"
            : "发消息或创建任务"
    }

    private var abilityChip: some View {
        Menu {
            Button("对话") { ability = .chat }
            Button("生成图片") { ability = .image }
            Button("生成视频 · 5 秒") { ability = .video(seconds: 5) }
            Button("生成视频 · 10 秒") { ability = .video(seconds: 10) }
            Button("生成视频 · 15 秒") { ability = .video(seconds: 15) }
        } label: {
            HStack(spacing: 4) {
                Text(abilityLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.labelSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.labelTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var abilityLabel: String {
        switch ability {
        case .chat: return "对话"
        case .image: return "生图"
        case .video(let s): return "视频 \(s)s"
        }
    }

    private var sendButton: some View {
        Button(action: sendNow) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(canSend ? theme.blue : theme.blue.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.sending
    }

    private func sendNow() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !vm.sending else { return }
        input = ""
        focused = false
        Task { await vm.send(t, ability: ability) }
    }

    // MARK: - 会话抽屉（左侧栏 280px 的 iOS 形态）
    private var sessionsSheet: some View {
        NavigationStack {
            List {
                ForEach(vm.conversations) { c in
                    Button {
                        vm.select(c.id)
                        showSessions = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.title)
                                .font(.system(size: 14, weight: c.id == vm.currentId ? .medium : .regular))
                                .foregroundStyle(c.id == vm.currentId ? theme.ink : theme.labelSecondary)
                                .lineLimit(1)
                            Text(Self.fmt.string(from: c.updatedAt))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.labelCaption)
                        }
                    }
                }
                .onDelete { vm.delete(at: $0) }
            }
            .listStyle(.plain)
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSessions = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
