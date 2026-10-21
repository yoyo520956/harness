import Foundation
import WebKit

/// DSH Web UI ↔ 原生桥。
/// JS 侧 shim 把 Typert RPC 的 call/open 全部代理到这里；
/// Swift 侧按 endpoint 分发：静态契约直接回答，引擎类动作转给编排器。
final class DSHBridge: NSObject, WKScriptMessageHandler, ObservableObject {
    static let bootstrap = """
    (function(){
      'use strict';
      if (window.__DSH_TRANSPORT__) return;
      var seq = 0;
      var pending = new Map();      // id -> {resolve, reject}
      var streams = new Map();      // streamId -> {pull, buffer, done, error}
      function post(msg){ try { window.webkit.messageHandlers.dsh.postMessage(JSON.stringify(msg)); } catch(e){ console.error('[shim] post fail', e); } }
      window.__DSH_BRIDGE__ = {
        onResult: function(json){ var m = JSON.parse(json); var p = pending.get(m.id); if(p){ pending.delete(m.id); p(m); } },
        onStream: function(json){ var m = JSON.parse(json); var s = streams.get(m.streamId); if(s) s.push(m); },
        log: function(){ /* debug tap */ }
      };
      function call(id, method, payload){
        return new Promise(function(resolve){ pending.set(id, resolve); post({kind:'rpc-call', id:id, method:method, payload:payload}); });
      }
      var mock = {
        call: function(channel, endpoint, payload, signal){
          var id = 'c' + (++seq);
          return call(id, endpoint, payload).then(function(m){
            if (m.ok) return { ok:true, value: m.value };
            return { ok:false, error: { code: (m.error && m.error.code) || 'gateway/internal', message: (m.error && m.error.message) || 'bridge error', details: (m.error && m.error.details) || {} } };
          });
        },
        open: function(channel, endpoint, payload, signal, uplink){
          var streamId = 's' + (++seq);
          var s = { buffer: [], done: false, error: null, resolvers: [], closed: false };
          streams.set(streamId, s);
          s.push = function(m){
            if (m.type === 'data') { var rs = s.resolvers.splice(0); s.buffer.push(m.value); rs.forEach(function(r){ r(); }); }
            else if (m.type === 'end') { s.done = true; var rs2 = s.resolvers.splice(0); rs2.forEach(function(r){ r(); }); }
            else if (m.type === 'error') { s.done = true; s.error = (m.error && m.error.message) || 'stream error'; var rs3 = s.resolvers.splice(0); rs3.forEach(function(r){ r(); }); }
          };
          post({kind:'rpc-open', streamId:streamId, method:endpoint, payload:payload});
          async function* gen(){
            try {
              while (true) {
                while (s.buffer.length) yield s.buffer.shift();
                if (s.error) throw new Error(s.error);
                if (s.done) return;
                await new Promise(function(res){ s.resolvers.push(res); });
              }
            } finally { if(!s.closed){ s.closed = true; streams.delete(streamId); post({kind:'rpc-close', streamId:streamId}); } }
          }
          return gen();
        }
      };
      window.__DSH_TRANSPORT__ = { rpc: mock, ownsHost: true };
      console.log('[shim] __DSH_TRANSPORT__ installed');
    })();
    """
    /// Swift 回 JS 的统一入口（主线程 evaluateJavaScript）。
    func post(_ message: [String: Any]) {
        guard let wv = webView else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            wv.evaluateJavaScript("window.__DSH_BRIDGE__.onResult(\(json))", completionHandler: nil)
        }
    }
    func postStream(_ message: [String: Any]) {
        guard let wv = webView else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            wv.evaluateJavaScript("window.__DSH_BRIDGE__.onStream(\(json))", completionHandler: nil)
        }
    }

    private weak var webView: WKWebView?
    func attach(_ wv: WKWebView) {
        webView = wv
        DSHOrchestrator.shared.register(bridge: self)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dsh",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch msg["kind"] as? String {
        case "rpc-call":
            let id = msg["id"] as? String ?? ""
            let method = msg["method"] as? String ?? ""
            DSHOrchestrator.shared.handleCall(id: id, method: method, payload: msg["payload"], bridge: self)
        case "rpc-open":
            let streamId = msg["streamId"] as? String ?? ""
            let method = msg["method"] as? String ?? ""
            DSHOrchestrator.shared.handleOpen(streamId: streamId, method: method, payload: msg["payload"], bridge: self)
        case "rpc-close":
            let streamId = msg["streamId"] as? String ?? ""
            DSHOrchestrator.shared.handleClose(streamId: streamId)
        default:
            HarnessLog.shared.add("[DSH] 未知消息 \(msg["kind"] ?? "?")")
        }
    }
}

extension DSHBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        HarnessLog.shared.add("[WebUI] 页面加载完成")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        HarnessLog.shared.add("[WebUI] 导航失败 \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        HarnessLog.shared.add("[WebUI] 加载失败 \(error.localizedDescription)")
    }
}
