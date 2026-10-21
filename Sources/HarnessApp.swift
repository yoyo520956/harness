import SwiftUI
import WebKit

@main
struct HarnessApp: App {
    @StateObject private var theme = HarnessTheme.shared
    @StateObject private var engine = DoubaoEngine.shared
    @StateObject private var vm = ChatVM()
    @StateObject private var gateway = GatewayServer.shared
    @StateObject private var ish = IshEngine.shared
    @StateObject private var bridge = DSHBridge()
    @State private var gatewayBooted = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView {
                    WebUIHostView(bridge: bridge)
                        .tabItem { Label("Harness", systemImage: "uiwindow.split.2x1") }
                    ChatView()
                        .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
                    TerminalView()
                        .tabItem { Label("Terminal", systemImage: "terminal") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                // 隐藏豆包引擎 WebView 宿主（1pt、不可交互，页面常驻维持登录态）
                EngineHost(engine: engine)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            }
            .environmentObject(theme)
            .environmentObject(engine)
            .environmentObject(vm)
            .environmentObject(gateway)
            .environmentObject(ish)
            .tint(theme.blue)
            .task {
                if gatewayBooted { return }
                gatewayBooted = true
                if UserDefaults.standard.bool(forKey: "harness.gateway.enabled") {
                    gateway.savePort()
                    gateway.start()
                }
            }
        }
    }
}

/// 豆包引擎 WebView 宿主（attach 后自动加载 doubao.com 并保持常驻）
struct EngineHost: UIViewRepresentable {
    let engine: DoubaoEngine
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        DispatchQueue.main.async { engine.attach(into: v) }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 占位屏（v0.3+ 逐屏实装）
struct CanvasView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.on.square.dashed").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Canvas · 无限画布（v0.6 实装）").foregroundStyle(.secondary)
            Spacer()
        }
    }
}


struct AgentsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cpu").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Agents · OpenClaw 功能面（v0.4 实装）").foregroundStyle(.secondary)
            Spacer()
        }
    }
}
