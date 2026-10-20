import Foundation
import WebKit

/// 豆包引擎：隐藏 WKWebView 内以真实登录态执行 fetch（a_bogus/msToken 由豆包页面 JS 自动注入）
final class DoubaoEngine: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, loading, pageReady, error(String) }
    enum LoginHint: Equatable { case unknown, likelyLoggedIn, likelyLoggedOut }

    static let shared = DoubaoEngine()

    @Published var phase: Phase = .idle
    @Published var loginHint: LoginHint = .unknown
    @Published var busy = false

    private var webView: WKWebView?
    private var pageLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var seq = 0
    private var draining = false
    private var queue: [() -> Void] = []
    private var pending: [String: Pending] = [:]

    private final class Pending {
        let parser = DoubaoSSEParser()
        let localId: String
        let onDelta: (String) -> Void
        let onImage: (String) -> Void
        let finish: (StreamOutcome, String, String, Int?, String) -> Void
        var emittedLen = 0
        var emittedImages = 0
        var resumed = false
        init(localId: String,
             onDelta: @escaping (String) -> Void,
             onImage: @escaping (String) -> Void,
             finish: @escaping (StreamOutcome, String, String, Int?, String) -> Void) {
            self.localId = localId
            self.onDelta = onDelta
            self.onImage = onImage
            self.finish = finish
        }
    }

    var phaseText: String {
        switch phase {
        case .idle: return "未启动"
        case .loading: return "豆包页面加载中"
        case .pageReady: return "页面就绪"
        case .error(let e): return "错误：\(e.prefix(80))"
        }
    }

    // MARK: - 页面承载（EngineHost 调用；页面常驻，登录态共享 WKWebsiteDataStore.default）
    func attach(into container: UIView) {
        if webView != nil { return }   // 保持 390x844 固定尺寸，不随 1pt 宿主缩放
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        wv.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        wv.alpha = 0.02
        wv.isUserInteractionEnabled = false
        wv.navigationDelegate = self
        wv.userContentController.add(self, name: "doubaoCtl")
        wv.userContentController.add(self, name: "doubaoEvent")
        container.addSubview(wv)
        webView = wv
        phase = .loading
        HarnessLog.shared.add("[豆包] 引擎启动，加载 www.doubao.com")
        wv.load(URLRequest(url: URL(string: "https://www.doubao.com")!))
    }

    func reloadPage() {
        guard let wv = webView else { return }
        pageLoaded = false
        phase = .loading
        wv.load(URLRequest(url: URL(string: "https://www.doubao.com")!))
    }

    /// 手动注入 sessionid 四件套（.doubao.com 域 · 规格 §2.1）
    func setSessionCookie(_ sessionid: String) {
        guard !sessionid.isEmpty, let wv = webView else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for n in ["sessionid", "sessionid_ss", "sid_tt", "sid_guard"] {
            if let c = HTTPCookie(properties: [
                .domain: ".doubao.com", .path: "/", .name: n, .value: sessionid,
                .secure: "TRUE", .expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 30)
            ]) {
                store.setCookie(c, completionHandler: nil)
            }
        }
        HarnessLog.shared.add("[豆包] 已写入 sessionid 四件套")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.reloadPage() }
    }

    private func ensurePage() async {
        if pageLoaded, webView?.url?.host == "www.doubao.com" { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loadWaiters.append(c)
        }
    }

    private func checkHooked() async -> Bool {
        guard let wv = webView else { return false }
        let r = try? await wv.evaluateJavaScript("window.fetch ? (String(window.fetch).indexOf('native code') >= 0 ? 'no' : 'yes') : 'none'")
        return (r as? String) == "yes"
    }

    // MARK: - 对外流式接口（串行队列；返回最终 outcome 与多轮新状态）
    func streamChat(text: String, model: String, ability: DoubaoAbility, state: ConvState,
                    onDelta: @escaping (String) -> Void,
                    onImage: @escaping (String) -> Void) async -> (StreamOutcome, ConvState) {
        await withCheckedContinuation { outer in
            DispatchQueue.main.async {
                self.queue.append {
                    Task {
                        let r = await self.performStream(text: text, model: model, ability: ability,
                                                         state: state, onDelta: onDelta, onImage: onImage)
                        outer.resume(returning: r)
                        self.drainNext()
                    }
                }
                self.drainNext()
            }
        }
    }

    private func drainNext() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        let job = queue.removeFirst()
        job()
    }

    private func performStream(text: String, model: String, ability: DoubaoAbility, state: ConvState,
                               onDelta: @escaping (String) -> Void, onImage: @escaping (String) -> Void
    ) async -> (StreamOutcome, ConvState) {
        await ensurePage()
        var hooked = false
        for _ in 0..<6 {
            hooked = await checkHooked()
            if hooked { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard hooked else {
            DispatchQueue.main.async { self.loginHint = .likelyLoggedOut }
            var o = StreamOutcome()
            o.error = "未登录或页面拦截器未就绪：请到 设置 → 豆包账号 登录 doubao.com 后重试"
            HarnessLog.shared.add("[豆包] fetch 未被接管（未登录/页面未就绪）")
            return (o, state)
        }
        DispatchQueue.main.async { self.loginHint = .likelyLoggedIn }
        var st = state
        if st.localConversationId.isEmpty { st.localConversationId = DoubaoPayload.newLocalConvId(Int64(Date().timeIntervalSince1970 * 1000)) }
        st.needCreate = st.conversationId.isEmpty
        let localId = st.localConversationId
        let payload = DoubaoPayload.build(text: text, state: st, model: model, ability: ability)
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8),
              let b64 = jsonStr.data(using: .utf8)?.base64EncodedString() else {
            var o = StreamOutcome(); o.error = "payload 构建失败"
            return (o, st)
        }
        seq += 1
        let rid = "r\(seq)"
        let trace = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        return await withCheckedContinuation { cont in
            let p = Pending(onDelta: onDelta, onImage: onImage) { [weak self] outcome, ackConv, ackSect, metaIdx, usedLocalId in
                Task { @MainActor in
                    guard let self else { return }
                    var out = outcome
                    var newState = st
                    newState.localConversationId = usedLocalId
                    if !ackConv.isEmpty, ackConv != "0" {
                        newState.conversationId = ackConv
                        newState.sectionId = ackSect
                        newState.needCreate = false
                        if let mi = metaIdx { newState.lastMessageIndex = mi }
                    }
                    // 视频产物换无水印直链（规格 §5）
                    if !out.vids.isEmpty {
                        for v in out.vids.prefix(2) {
                            if let u = await self.resolveVideo(vid: v), !out.videoURLs.contains(u) {
                                out.videoURLs.append(u)
                            }
                        }
                    }
                    HarnessLog.shared.add("[豆包] 流完成 text=\(out.text.count)字 图=\(out.images.count) vid=\(out.vids.count) err=\(out.error ?? "无")")
                    cont.resume(returning: (out, newState))
                }
            }
            pending[rid] = p
            busy = true
            let js = streamJS(b64: b64, rid: rid, trace: trace)
            webView?.evaluateJavaScript(js, completionHandler: { _, err in
                if let err = err {
                    HarnessLog.shared.add("[豆包] JS 注入失败 \(err.localizedDescription.prefix(120))")
                    self.failPending(rid, message: "JS 注入失败: \(err.localizedDescription)")
                }
            })
        }
    }

    // MARK: - 视频直链（POST /samantha/media/get_play_info + lr 改写 · 规格 §5）
    func resolveVideo(vid: String) async -> String? {
        guard let wv = webView else { return nil }
        let js = videoJS(vid: vid)
        let r = try? await wv.evaluateJavaScript(js)
        if let s = r as? String {
            if s.hasPrefix("ERR:") {
                HarnessLog.shared.add("[豆包] 视频直链解析失败 \(s.prefix(120))")
                return nil
            }
            return s.isEmpty ? nil : s
        }
        return nil
    }
}

// MARK: - WKNavigationDelegate + 消息桥
extension DoubaoEngine: WKNavigationDelegate, WKScriptMessageHandler {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        phase = .pageReady
        let cs = loadWaiters; loadWaiters.removeAll()
        for c in cs { c.resume() }
        HarnessLog.shared.add("[豆包] 页面加载完成")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failLoad(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failLoad(error.localizedDescription)
    }

    private func failLoad(_ msg: String) {
        phase = .error(msg)
        HarnessLog.shared.add("[豆包] 页面加载失败 \(msg.prefix(120))")
        let cs = loadWaiters; loadWaiters.removeAll()
        for c in cs { c.resume() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let rid = body["rid"] as? String else { return }
        if message.name == "doubaoCtl" {
            let type = body["type"] as? String ?? ""
            if type == "error" {
                let code = body["code"] as? String ?? "JS"
                let msg = body["msg"] as? String ?? ""
                let full = "\(code) \(msg.prefix(400))"
                HarnessLog.shared.add("[豆包] 错误 rid=\(rid) \(full)")
                failPending(rid, message: full)
            } else {
                HarnessLog.shared.add("[豆包] ctl rid=\(rid) type=\(type) code=\(body["code"] as? String ?? "-") ct=\(body["ct"] as? String ?? "-")")
                let code = body["code"] as? String ?? ""
                if code == "403" || code == "401" {
                    DispatchQueue.main.async { self.loginHint = .likelyLoggedOut }
                }
            }
            return
        }
        guard message.name == "doubaoEvent", let p = pending[rid] else { return }
        let type = body["type"] as? String ?? ""
        if type == "frames", let frames = body["frames"] as? [[String: Any]] {
            for f in frames {
                p.parser.feed(ev: f["ev"] as? String ?? "", data: f["data"] as? String ?? "")
            }
            emitDelta(p)
            if p.parser.finished { finishPending(rid) }
        } else if type == "done" {
            finishPending(rid)
        }
    }

    private func emitDelta(_ p: Pending) {
        let t = p.parser.outcome.text
        if t.count > p.emittedLen {
            let idx = t.index(t.startIndex, offsetBy: p.emittedLen)
            p.onDelta(String(t[idx...]))
            p.emittedLen = t.count
        }
        while p.emittedImages < p.parser.outcome.images.count {
            p.onImage(p.parser.outcome.images[p.emittedImages])
            p.emittedImages += 1
        }
    }

    private func finishPending(_ rid: String) {
        guard let p = pending[rid], !p.resumed else { return }
        p.resumed = true
        busy = false
        let out = p.parser.outcome
        let ackConv = p.parser.ackConvId
        let ackSect = p.parser.ackSectionId
        let metaIdx = p.parser.metaIndex
        pending.removeValue(forKey: rid)
        p.finish(out, ackConv, ackSect, metaIdx, p.localId)
    }

    private func failPending(_ rid: String, message: String) {
        guard let p = pending[rid], !p.resumed else { return }
        p.resumed = true
        busy = false
        var out = p.parser.outcome
        out.error = message
        let ackConv = p.parser.ackConvId
        let ackSect = p.parser.ackSectionId
        let metaIdx = p.parser.metaIndex
        pending.removeValue(forKey: rid)
        p.finish(out, ackConv, ackSect, metaIdx, p.localId)
    }
}

// MARK: - JS 模板（规格 §3.2 照抄；base64 传 payload 防转义问题；SSE 逐帧桥回 Swift）
extension DoubaoEngine {
    private func streamJS(b64: String, rid: String, trace: String) -> String {
        let q = "\"" + b64 + "\""
        return streamJSTemplate
            .replacingOccurrences(of: "__B64__", with: q)
            .replacingOccurrences(of: "__RID__", with: rid)
            .replacingOccurrences(of: "__TRACE__", with: trace)
    }

    private let streamJSTemplate = #"""
(async (__B64__) => {
  const RID = "__RID__", TRACE = "__TRACE__";
  const ctl = (h) => { try { webkit.messageHandlers.doubaoCtl.postMessage(Object.assign({rid: RID}, h)); } catch (e) {} };
  const emit = (h) => { try { webkit.messageHandlers.doubaoEvent.postMessage(Object.assign({rid: RID}, h)); } catch (e) {} };
  try {
    if (!window.fetch || String(window.fetch).indexOf('native code') >= 0) {
      ctl({type:'error', code:'NOT_HOOKED', msg:'window.fetch 未被豆包页面 JS 接管（未登录或页面未加载完）'});
      return;
    }
    const payload = new TextDecoder().decode(Uint8Array.from(atob(__B64__), c => c.charCodeAt(0)));
    const resp = await fetch('https://www.doubao.com/chat/completion', {
      method: 'POST',
      headers: {'Content-Type':'application/json','Agw-Js-Conv':'str','x-flow-trace':TRACE,'last-event-id':'undefined'},
      body: payload, credentials: 'include', signal: AbortSignal.timeout(1800000)
    });
    const ct = resp.headers.get('content-type') || '';
    ctl({type:'status', code: String(resp.status), ct: ct});
    if (!resp.ok || ct.indexOf('event-stream') < 0) {
      const txt = await resp.text();
      ctl({type:'error', code:'HTTP_' + resp.status, msg: txt.slice(0, 1200)});
      return;
    }
    const reader = resp.body.getReader();
    const dec = new TextDecoder('utf-8');
    let buf = '', timer = null;
    const pf = [];
    const flush = () => { timer = null; if (pf.length) { emit({type:'frames', frames: pf.slice()}); pf.length = 0; } };
    for (;;) {
      const r = await reader.read();
      if (r.done) break;
      buf += dec.decode(r.value, {stream:true});
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const frame = buf.slice(0, i); buf = buf.slice(i + 2);
        let ev = null, id = null; const ds = [];
        const lines = frame.split('\n');
        for (let k = 0; k < lines.length; k++) {
          const L = lines[k];
          if (L.indexOf('event:') === 0) ev = L.slice(6).trim();
          else if (L.indexOf('id:') === 0) id = L.slice(3).trim();
          else if (L.indexOf('data:') === 0) ds.push(L.slice(5).replace(/^ /, ''));
        }
        if (ev !== null || ds.length) pf.push({ev: ev, id: id, data: ds.join('\n')});
        if (pf.length >= 6 && timer === null) timer = setTimeout(flush, 25);
      }
    }
    if (timer !== null) clearTimeout(timer);
    flush();
    emit({type:'done'});
  } catch (e) {
    ctl({type:'error', code:'JSEXC', msg: String((e && e.message) || e)});
  }
})(__B64__);
"""#

    private func videoJS(vid: String) -> String {
        let v = vid.replacingOccurrences(of: "\"", with: "")
        return #"""
(async () => {
  try {
    const url = 'https://www.doubao.com/samantha/media/get_play_info?aid=497858&device_platform=web&samantha_web=1&use-olympus-account=1&version_code=20800&pkg_type=release_version&web_tab_id=' + crypto.randomUUID();
    const r = await fetch(url, {
      method: 'POST', credentials: 'include',
      headers: {'content-type': 'application/json', 'accept': 'application/json'},
      body: JSON.stringify({key: '__VID__', type: 'video'})
    });
    const j = await r.json();
    if (j.code === 0) {
      let u = '';
      if (j.data && j.data.original_media_info && j.data.original_media_info.main_url) u = j.data.original_media_info.main_url;
      else if (j.data && j.data.play_infos && j.data.play_infos[0] && j.data.play_infos[0].main) u = j.data.play_infos[0].main;
      if (u) u = u.replace(/([?&])lr=[^&]*/, '$1lr=video_gen_no_watermark');
      return u;
    }
    return 'ERR:code=' + j.code;
  } catch (e) { return 'ERR:' + String((e && e.message) || e); }
})()
"""#.replacingOccurrences(of: "__VID__", with: v)
    }
}

