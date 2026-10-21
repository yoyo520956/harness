import SwiftUI
import WebKit

/// 1:1 承载 DeepSeek Harness 真实 Web UI 的 WKWebView 宿主。
/// 在 documentStart 注入 __DSH_TRANSPORT__（rpc.call/open 全接口替换为进程内 mock），
/// 于是 Web UI 的整个 Cordis 插件树无需任何网络即可启动。
struct WebUIHostView: UIViewRepresentable {
    @ObservedObject var bridge: DSHBridge

    func makeCoordinator() -> DSHBridge { bridge }

    func makeUIView(context: Context) -> WKWebView {
        let content = WKUserContentController()
        content.add(bridge, name: "dsh")
        // 注入点必须先于主包：__DSH_TRANSPORT__ 在 connection 插件激活时读取
        let inject = WKUserScript(source: DSHBridge.bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        content.addUserScript(inject)
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = content
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = context.coordinator
        bridge.attach(wv)
        WebUIServer.shared.start(port: 8799)
        let url = URL(string: WebUIServer.shared.localURL)!
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantle() { WebUIServer.shared.stop() }
}

final class WebUINavDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        HarnessLog.shared.add("[WebUI] 导航失败 \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        HarnessLog.shared.add("[WebUI] 页面加载完成")
    }
}
