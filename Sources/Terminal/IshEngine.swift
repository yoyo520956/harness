import Foundation

/// iSH 引擎 Swift 封装：专用内核线程（iSH 的 current 是线程本地的，GCD 串行队列不保证同一线程）
final class IshEngine: ObservableObject {
    static let shared = IshEngine()

    enum Phase: Equatable { case idle, installing, booting, ready, failed(String) }

    @Published var phase: Phase = .idle

    private let thread: Thread
    private var bootStarted = false

    private init() {
        thread = Thread(block: {
            let rl = RunLoop.current
            while true {
                rl.run(mode: .default, before: Date().addingTimeInterval(3600))
            }
        })
        thread.name = "ish-kernel"
        thread.stackSize = 32 << 20
        thread.start()
    }

    private final class Box: NSObject {
        let items: [Any]
        init(_ items: [Any]) { self.items = items }
    }

    // MARK: - 启动（rootfs 导入 + 内核 boot，只做一次；失败可重试）
    func ensureBoot(force: Bool = false) {
        if force { bootStarted = false }
        guard !bootStarted else { return }
        bootStarted = true
        DispatchQueue.main.async { self.phase = .installing }
        perform(#selector(_bootThread), on: thread, with: nil, waitUntilDone: false)
    }

    @objc private func _bootThread() {
        let rootDir = IshGlue.defaultRootDir()
        do {
            _ = try IshGlue.shared().installRootIfMissingTarResource("rootfs", rootDir: rootDir)
        } catch {
            HarnessLog.shared.add("[iSH] rootfs 导入失败 \(error.localizedDescription)")
            DispatchQueue.main.async { self.phase = .failed("rootfs 导入失败: \(error.localizedDescription)") }
            return
        }
        HarnessLog.shared.add("[iSH] rootfs 就绪，启动内核")
        DispatchQueue.main.async { self.phase = .booting }
        let rc = IshGlue.shared().boot(withRootDir: rootDir)
        HarnessLog.shared.add("[iSH] boot rc=\(rc)")
        DispatchQueue.main.async {
            self.phase = rc == 0 ? .ready : .failed("boot 错误码 \(rc)")
        }
    }

    // MARK: - 会话
    func startSession(command: [String],
                      onOutput: @escaping (Data) -> Void,
                      onExit: @escaping (Int) -> Void,
                      done: @escaping (Int) -> Void) {
        let box = Box([command, onOutput, onExit, done])
        perform(#selector(_startSessionBox(_:)), on: thread, with: box, waitUntilDone: true)
    }

    @objc private func _startSessionBox(_ box: Box) {
        guard let cmd = box.items[0] as? [String],
              let onOutput = box.items[1] as? (Data) -> Void,
              let onExitC = box.items[2] as? (Int32) -> Void,
              let done = box.items[3] as? (Int) -> Void else { return }
        let rc = IshGlue.shared().startSessionCommand(cmd,
            onOutput: { data in onOutput(data) },
            onExit: { code in onExitC(code) })
        done(Int(rc))
    }

    func send(_ text: String) {
        IshGlue.shared().sendInputData(Data(text.utf8))
    }

    func sendRaw(_ data: Data) {
        IshGlue.shared().sendInputData(data)
    }

    func resize(row: Int, col: Int) {
        IshGlue.shared().setWinSizeRow(Int32(row), col: Int32(col))
    }

    var sessionActive: Bool { IshGlue.shared().sessionActive }
}
