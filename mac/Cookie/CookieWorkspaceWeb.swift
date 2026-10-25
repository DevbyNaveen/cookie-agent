import SwiftUI
import WebKit

/// Generated code runs in an opaque-origin sandboxed frame, with no network or native actions.
struct CookieWorkspaceWeb: NSViewRepresentable {
    let artifact: CookieArtifact
    let scrollY: Double
    let focus: String?
    var onSelection: (String) -> Void
    var onScroll: (Double) -> Void
    var onIssue: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "workspace")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        let rules = #"[{"trigger":{"url-filter":"^http"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ws"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "CookieWorkspaceOffline-v1", encodedContentRuleList: rules) { list, error in
            DispatchQueue.main.async {
                guard let list else { context.coordinator.parent.onIssue("Preview isolation could not start."); return }
                configuration.userContentController.add(list)
                context.coordinator.ready = true
                context.coordinator.render()
            }
        }
        return web
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render()
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            if let focus, let data = try? JSONEncoder().encode(focus) {
                view.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage({focus:\(String(decoding: data, as: UTF8.self))}, '*')")
            }
        }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "workspace")
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: CookieWorkspaceWeb
        weak var web: WKWebView?
        var ready = false
        var revision: String?
        var focus: String?
        init(_ parent: CookieWorkspaceWeb) { self.parent = parent }
        func render() {
            guard ready, revision != parent.artifact.current.id, let web else { return }
            revision = parent.artifact.current.id
            let instrument = """
            <script>
            (()=>{
              const send=(v)=>parent.postMessage(v,'*');
              addEventListener('error',e=>send({issue:String(e.message).slice(0,500)}));
              addEventListener('unhandledrejection',()=>send({issue:'Unhandled promise rejection'}));
              addEventListener('DOMContentLoaded',()=>{
                document.querySelectorAll('body *').forEach((e,i)=>{if(!e.id)e.dataset.cookieTarget='element-'+i;});
                scrollTo(0,\(max(0, min(10_000_000, parent.scrollY))));send({ready:true});
                if(document.documentElement.scrollWidth>innerWidth+2)send({issue:'Content overflows the preview width.'});
              });
              addEventListener('click',e=>{let n=e.target.closest('[id],[data-cookie-target]');if(n)send({selection:(n.id||n.dataset.cookieTarget)+' | '+n.textContent.slice(0,500)});},true);
              let timer;addEventListener('scroll',()=>{clearTimeout(timer);timer=setTimeout(()=>send({scroll:scrollY}),150);});
              addEventListener('message',e=>{if(e.source!==parent||typeof e.data.focus!=='string')return;
                const id=e.data.focus;const n=document.getElementById(id)||Array.from(document.querySelectorAll('[data-cookie-target]')).find(n=>n.dataset.cookieTarget===id);
                if(n){document.querySelectorAll('[data-cookie-focused]').forEach(x=>{x.style.outline='';delete x.dataset.cookieFocused;});n.dataset.cookieFocused='1';n.style.outline='3px solid #ffab52';n.scrollIntoView({block:'center'});requestAnimationFrame(()=>{const r=n.getBoundingClientRect();send({point:{x:r.left,y:r.top+r.height/2,target:id}})});}
              });
            })();
            </script>
            """
            let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\">"
            let document = csp + instrument + parent.artifact.current.content.body
            let encoded = String(decoding: try! JSONEncoder().encode(document), as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
            let wrapper = """
            <!doctype html><html><head><style>html,body,iframe{margin:0;width:100%;height:100%;border:0;background:white}iframe{display:block}</style></head><body>
            <iframe sandbox="allow-scripts" title="Interactive output"></iframe>
            <script>const frame=document.querySelector('iframe');addEventListener('message',e=>{if(e.source===frame.contentWindow)webkit.messageHandlers.workspace.postMessage({revision:'\(parent.artifact.current.id)',payload:e.data})});frame.srcdoc=\(encoded);</script></body></html>
            """
            web.loadHTMLString(wrapper, baseURL: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let envelope = message.body as? [String: Any], envelope["revision"] as? String == parent.artifact.current.id,
                  let body = envelope["payload"] as? [String: Any] else { return }
            if body["ready"] as? Bool == true, let focus = parent.focus, let data = try? JSONEncoder().encode(focus) {
                web?.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage({focus:\(String(decoding: data, as: UTF8.self))}, '*')")
            }
            if let value = body["selection"] as? String { parent.onSelection(String(value.prefix(1000))) }
            if let value = body["scroll"] as? Double, value.isFinite { parent.onScroll(max(0, min(value, 10_000_000))) }
            if let value = body["issue"] as? String { parent.onIssue(String(value.prefix(500))) }
            if let point = body["point"] as? [String: Any], let target = point["target"] as? String, target == parent.focus,
               let x = point["x"] as? Double, let y = point["y"] as? Double, x.isFinite, y.isFinite,
               let web, let window = web.window, x >= 0, y >= 0, x <= web.bounds.width, y <= web.bounds.height {
                let local = CGPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
                let screen = window.convertPoint(toScreen: web.convert(local, to: nil))
                CookieHand.shared.teach(owner: CookieWorkspaceStore.shared.pointerOwner, at: screen)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme
            decisionHandler(scheme == "about" && navigationAction.navigationType == .other ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.onIssue("Preview stopped. Reopen the output to reload it.") }
    }
}
