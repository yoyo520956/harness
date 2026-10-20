import Foundation

/// linux-command 中文命令手册（621 条，bundle 内 Manual.json + ManualIndex.json）
final class LinuxManual {
    static let shared = LinuxManual()

    private lazy var content: [String: String] = {
        load("Manual.json") ?? [:]
    }()

    private lazy var index: [String: String] = {
        load("ManualIndex.json") ?? [:]
    }()

    private func load(_ name: String) -> [String: String]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: String]
    }

    var count: Int { index.count }

    /// 精确取全文
    func content(of cmd: String) -> String? { content[cmd] }

    /// 模糊搜索（命令名/描述），最多 20 条
    func search(_ q: String) -> [(name: String, desc: String)] {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var hits: [(String, String)] = []
        for (name, desc) in index.sorted(by: { $0.key < $1.key }) {
            if name.lowercased().contains(query) || desc.lowercased().contains(query) {
                hits.append((name, desc))
                if hits.count >= 20 { break }
            }
        }
        return hits
    }
}
