import SwiftUI

struct TerminalView: View {
    @EnvironmentObject var theme: HarnessTheme
    @EnvironmentObject var ish: IshEngine
    @State private var input = ""
    @State private var output = ""
    @State private var pendingData = Data()
    @State private var sessionRunning = false
    @State private var showManual = false
    @State private var manualQuery = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if ish.phase == .ready {
                terminalPane
            } else {
                bootPane
            }
            inputBar
        }
        .background(Color(hex: 0x151517))
        .onAppear {
            if ish.phase == .idle { ish.ensureBoot() }
        }
        .onChange(of: ish.phase) { p in
            if p == .ready && !sessionRunning && output.isEmpty { newSession() }
        }
        .sheet(isPresented: $showManual) { manualSheet }
    }

    // MARK: 头部
    private var header: some View {
        HStack(spacing: 8) {
            Rectangle().fill(theme.blue).frame(width: 22, height: 2).cornerRadius(2)
            Image(systemName: "terminal").font(.system(size: 14)).foregroundStyle(theme.labelSecondary)
            Text("Alpine Linux · iSH")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.ink)
            Text(phaseText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(sessionRunning ? theme.success : theme.labelCaption)
            Spacer()
            Button { showManual = true } label: {
                Image(systemName: "book").font(.system(size: 15)).foregroundStyle(theme.labelSecondary)
            }
            .buttonStyle(.plain)
            Button { newSession() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14)).foregroundStyle(theme.labelSecondary)
            }
            .buttonStyle(.plain)
            .disabled(sessionRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var phaseText: String {
        switch ish.phase {
        case .idle: return "未启动"
        case .installing: return "导入 rootfs"
        case .booting: return "内核启动中"
        case .ready: return sessionRunning ? "会话运行中" : "就绪"
        case .failed(let e): return "失败"
        }
    }

    // MARK: 启动过程
    private var bootPane: some View {
        VStack(spacing: 14) {
            Spacer()
            if case .failed(let e) = ish.phase {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(theme.error)
                Text(e).font(.system(size: 13)).foregroundStyle(theme.labelSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
                Button("重试") { ish.ensureBoot(force: true) }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(theme.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .buttonStyle(.plain)
            } else {
                ProgressView().tint(theme.blue)
                Text("首次启动：导入 Alpine rootfs（约 3MB → SQLite）+ 内核引导")
                    .font(.system(size: 13)).foregroundStyle(theme.labelSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 终端输出
    private var terminalPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(output.isEmpty ? "Alpine Linux 已就绪。\r\n试试下面的快捷按钮，或直接输入命令。\r\n手册按钮可查 621 条中文命令文档。"
                     : output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xE1E5EE))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                Color.clear.frame(height: 2).id("t_bottom")
            }
            .onChange(of: output) { _ in
                proxy.scrollTo("t_bottom", anchor: .bottom)
            }
        }
        .background(Color(hex: 0x151517))
    }

    // MARK: 输入栏
    private var inputBar: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickChip("apk update", icon: "arrow.triangle.2.circlepath")
                    quickChip("apk add python3", icon: "chevron.left.forwardslash.chevron.right")
                    quickChip("python3 --version", icon: "c")
                    quickChip("ls -la", icon: "list.bullet")
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField(sessionRunning ? "输入命令…" : "会话未运行", text: $input, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xE1E5EE))
                    .tint(theme.blue)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { sendInput() }
                Button(action: sendInput) {
                    Image(systemName: "arrow.return.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? theme.blue : theme.blue.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: 0x1B1B1C), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(Color(hex: 0x151517))
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func quickChip(_ cmd: String, icon: String) -> some View {
        Button {
            input = cmd
            sendInput()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(cmd).font(.system(size: 12, design: .monospaced))
            }
            .foregroundStyle(theme.labelSecondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(hex: 0x1B1B1C), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 手册
    private var manualSheet: some View {
        NavigationStack {
            ManualListView(initialQuery: input.hasPrefix("help ") ? String(input.dropFirst(5)) : manualQuery)
                .navigationTitle("Linux 命令手册")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showManual = false } } }
        }
    }

    // MARK: 动作
    private func sendInput() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // help <cmd> 走本地手册，不进 guest
        if t.hasPrefix("help ") || t == "help" {
            manualQuery = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            showManual = true
            input = ""
            return
        }
        guard sessionRunning else {
            append("\r\n[会话未运行：点右上角 ↻ 新开会话]\r\n")
            return
        }
        ish.send(t + "\n")
        input = ""
        focused = false
    }

    private func newSession() {
        guard ish.phase == .ready else { return }
        if ish.sessionActive {
            append("\r\n[已有会话运行中，先输入 exit 退出]\r\n")
            return
        }
        output = ""
        pendingData = Data()
        ish.startSession(command: ["/bin/login", "-f", "root"],
            onOutput: { data in
                DispatchQueue.main.async { self.consume(data) }
            },
            onExit: { code in
                DispatchQueue.main.async {
                    self.sessionRunning = false
                    self.append("\r\n[会话退出 code=\(code)]\r\n")
                }
            },
            done: { rc in
                DispatchQueue.main.async {
                    if rc < 0 {
                        self.append("[会话启动失败 rc=\(rc)]\r\n")
                    } else {
                        self.sessionRunning = true
                    }
                }
            })
    }

    // MARK: 输出消费（ANSI 剥离 + UTF-8 边界缓冲）
    private func consume(_ data: Data) {
        pendingData.append(data)
        if let s = String(data: pendingData, encoding: .utf8) {
            append(Self.sanitize(s))
            pendingData.removeAll()
        } else {
            // 尝试剥掉尾部不完整序列（最多 3 字节）
            for cut in 1...min(3, pendingData.count) {
                let head = pendingData.prefix(pendingData.count - cut)
                if let s = String(data: head, encoding: .utf8) {
                    append(Self.sanitize(s))
                    pendingData = pendingData.suffix(cut)
                    return
                }
            }
        }
        if output.count > 400_000 {
            output = String(output.suffix(300_000))
        }
    }

    private func append(_ s: String) {
        output += s
    }

    static let ansiRegex = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[=>]")
    static func sanitize(_ s: String) -> String {
        let r = NSMutableString(string: s)
        ansiRegex.replaceMatches(in: r, range: NSRange(location: 0, length: r.length), withTemplate: "")
        return r as String
    }
}

// MARK: - 手册列表
struct ManualListView: View {
    @EnvironmentObject var theme: HarnessTheme
    @State var query: String
    let initialQuery: String

    init(initialQuery: String) {
        self.initialQuery = initialQuery
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.labelCaption)
                TextField("搜命令（如 ls / docker / grep）", text: $query)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            let hits = LinuxManual.shared.search(query)
            List {
                if query.isEmpty {
                    Text("共 \(LinuxManual.shared.count) 条命令。终端里输入 `help <命令>` 也能直达。")
                        .font(.system(size: 12)).foregroundStyle(theme.labelCaption)
                }
                ForEach(hits, id: \.name) { hit in
                    NavigationLink {
                        ScrollView {
                            Text(LinuxManual.shared.content(of: hit.name) ?? "（无内容）")
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(12)
                        }
                        .background(theme.bgBase)
                        .navigationTitle(hit.name)
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.name).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.ink)
                            Text(hit.desc).font(.system(size: 12)).foregroundStyle(theme.labelCaption).lineLimit(2)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
