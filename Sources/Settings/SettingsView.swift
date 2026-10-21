import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject var theme: HarnessTheme
    @EnvironmentObject var engine: DoubaoEngine
    @EnvironmentObject var gateway: GatewayServer
    @AppStorage("harness.gateway.enabled") private var gwEnabled = false
    @AppStorage("harness.video.seconds") private var videoSeconds = 10
    @State private var cookieText = ""
    @State private var showLogin = false
    @State private var testing = false
    @State private var testResult = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    accountCard
                    gatewayCard
                    videoCard
                    logCard
                    aboutCard
                }
                .padding(14)
            }
            .background(theme.bgBase)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLogin, onDismiss: {
                engine.reloadPage()
                // 给页面 2.5s 加载 + hook 注入，然后自动重测刷新登录状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.testConnection() }
            }) {
                DoubaoLoginSheet()
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.composerFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
    }

    private var dotColor: Color {
        switch engine.phase {
        case .pageReady: return theme.success
        case .error: return theme.error
        default: return Color(hex: 0xD4D4D4)
        }
    }

    // MARK: 豆包账号
    private var accountCard: some View {
        card("豆包账号") {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(engine.phaseText).font(.system(size: 13)).foregroundStyle(theme.labelSecondary)
                if engine.loginHint == .likelyLoggedOut {
                    Text("· 疑似未登录").font(.system(size: 13)).foregroundStyle(theme.warn)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    showLogin = true
                } label: {
                    Text("登录豆包")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .background(theme.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    testConnection()
                } label: {
                    Text(testing ? "测试中…" : "发送测试消息")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(testing)
            }
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.system(size: 12))
                    .foregroundStyle(testResult.hasPrefix("✅") ? theme.success : theme.error)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                TextField("或手动粘贴 sessionid", text: $cookieText)
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("应用") {
                    engine.setSessionCookie(cookieText.trimmingCharacters(in: .whitespacesAndNewlines))
                    cookieText = ""
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.blue)
                .disabled(cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func testConnection() {
        testing = true
        testResult = ""
        Task {
            let (out, _) = await engine.streamChat(text: "回复「pong」两个字即可", model: "doubao-chat",
                                                   ability: .chat, state: ConvState(),
                                                   onDelta: { _ in }, onImage: { _ in })
            if let e = out.error {
                testResult = "❌ " + e
            } else {
                testResult = "✅ 连通：" + out.text.prefix(60)
            }
            testing = false
        }
    }

    // MARK: 本地网关
    private var gatewayCard: some View {
        card("本地网关 · OpenAI 兼容") {
            Toggle("启用（第三方 App 可接入）", isOn: Binding(
                get: { gwEnabled },
                set: { on in
                    gwEnabled = on
                    if on { gateway.savePort(); gateway.start() } else { gateway.stop() }
                }))
            .tint(theme.blue)
            HStack(spacing: 8) {
                Text("端口").font(.system(size: 13)).foregroundStyle(theme.labelSecondary)
                TextField("8788", text: $gateway.portText)
                    .font(.system(size: 13))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .keyboardType(.numberPad)
                    .onSubmit { gateway.savePort() }
                Spacer()
            }
            if gateway.running {
                VStack(alignment: .leading, spacing: 4) {
                    row("本机地址", gateway.localURL)
                    if let lan = gateway.lanAddress {
                        row("局域网地址", "http://\(lan):\(gateway.portText)/v1")
                    }
                    HStack(spacing: 8) {
                        Text("API Key").font(.system(size: 13)).foregroundStyle(theme.labelSecondary)
                        Text(gateway.apiKey)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.labelTertiary)
                            .lineLimit(1)
                        Spacer()
                        Button(copied ? "已复制" : "复制") {
                            UIPasteboard.general.string = gateway.apiKey
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(theme.blue)
                        .buttonStyle(.plain)
                        Button("重置") { gateway.regenerateKey() }
                            .font(.system(size: 13))
                            .foregroundStyle(theme.error)
                            .buttonStyle(.plain)
                    }
                }
            }
            Text("模型：\(DoubaoModels.list.joined(separator: " · "))")
                .font(.system(size: 12))
                .foregroundStyle(theme.labelCaption)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 13)).foregroundStyle(theme.labelSecondary)
            Text(v)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: 视频时长
    private var videoCard: some View {
        card("视频生成") {
            Picker("默认时长", selection: $videoSeconds) {
                Text("5 秒").tag(5)
                Text("10 秒").tag(10)
                Text("15 秒").tag(15)
            }
            .pickerStyle(.segmented)
            Text("提示词里不要出现“15秒”等时长字样，否则会被语义层拒绝并降级 10 秒")
                .font(.system(size: 12))
                .foregroundStyle(theme.labelCaption)
        }
    }

    private var logCard: some View {
        NavigationLink {
            LogView()
        } label: {
            card("运行日志", content: {
                Text("最近 \(HarnessLog.shared.lines.count) 条 · 点击查看")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.labelSecondary)
            })
        }
        .buttonStyle(.plain)
    }

    private var aboutCard: some View {
        card("关于") {
            HStack(spacing: 10) {
                Image("whale").resizable().scaledToFit().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DeepSeek Harness").font(.system(size: 14, weight: .medium)).foregroundStyle(theme.ink)
                    Text("v0.2.0 · 豆包网页转 API 网关 · UI 复刻自 deepseek-ai/deepseek-harness")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.labelCaption)
                }
                Spacer()
            }
        }
    }
}

// MARK: - 登录页（真实浏览器上下文登录 → Cookie 自动进默认存储）
struct DoubaoLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            DoubaoWebView()
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("登录 doubao.com")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

struct DoubaoWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        wv.load(URLRequest(url: URL(string: "https://www.doubao.com")!))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 日志页
struct LogView: View {
    @EnvironmentObject var theme: HarnessTheme
    @ObservedObject var log = HarnessLog.shared
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .background(theme.bgBase)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
    }
}
