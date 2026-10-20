import SwiftUI

@main
struct HarnessApp: App {
    @StateObject private var theme = HarnessTheme.shared
    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
                CanvasView()
                    .tabItem { Label("Canvas", systemImage: "square.on.square.dashed") }
                TerminalView()
                    .tabItem { Label("Terminal", systemImage: "terminal") }
                AgentsView()
                    .tabItem { Label("Agents", systemImage: "cpu") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(theme)
            .tint(theme.accent)
        }
    }
}

// MARK: - Theme（占位版；v0.6 按 deepseek-harness 规格逐像素替换）
final class HarnessTheme: ObservableObject {
    static let shared = HarnessTheme()
    let accent = Color.blue
    let bg = Color(UIColor.systemBackground)
    let bubbleUser = Color.blue
    let bubbleAI = Color(UIColor.secondarySystemBackground)
}

// MARK: - 占位屏（后续逐屏按 harness-ui.md 还原）
struct ChatView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Chat · 豆包网关对接中")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .navigationTitle("Chat")
        }
    }
}

struct CanvasView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Canvas · 无限画布")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .navigationTitle("Canvas")
        }
    }
}

struct TerminalView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "terminal")
                    .font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Terminal · iSH Alpine")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .navigationTitle("Terminal")
        }
    }
}

struct AgentsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "cpu")
                    .font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Agents · OpenClaw 功能面")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .navigationTitle("Agents")
        }
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("豆包账号") { Text("Cookie 配置（v0.2）") }
                Section("本地网关") { Text("OpenAI 兼容服务（v0.2）") }
                Section("关于") { Text("deepseek-harness · v0.1") }
            }
            .navigationTitle("Settings")
        }
    }
}
