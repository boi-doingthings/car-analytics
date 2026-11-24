import Combine
import SwiftUI
import WebKit

/// The web dashboard (web/*.html) in a WKWebView, served by `SchemeHandler` at `i20://app/`.
struct DashboardView: View {
    @EnvironmentObject var sync: SyncCoordinator
    @Environment(\.scenePhase) private var phase

    var body: some View {
        DashboardWebView(sync: sync)
            .background(Color(red: 0x0f / 255, green: 0x1a / 255, blue: 0x2a / 255))
            .onAppear { sync.syncIfStale() }
            .onChange(of: phase) { _, p in if p == .active { sync.syncIfStale() } }
    }
}

struct DashboardWebView: UIViewRepresentable {
    static let start = URL(string: "\(SchemeHandler.scheme)://app/index.html")!
    let sync: SyncCoordinator

    func makeCoordinator() -> Coordinator { Coordinator(sync: sync) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.handler, forURLScheme: SchemeHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.navigationDelegate = context.coordinator
        #if DEBUG
        web.isInspectable = true
        #endif
        context.coordinator.web = web
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pulled), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.refresh = refresh
        var start = Self.start
        #if DEBUG
        // Manual checks: I20_DEBUG_PAGE=fuel.html or index.html#car opens that page first.
        if let page = ProcessInfo.processInfo.environment["I20_DEBUG_PAGE"],
           let u = URL(string: "\(SchemeHandler.scheme)://app/\(page)") { start = u }
        #endif
        web.load(URLRequest(url: start))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler: SchemeHandler
        weak var web: WKWebView?
        weak var refresh: UIRefreshControl?
        private let sync: SyncCoordinator
        private var bag: AnyCancellable?
        private var runningBag: AnyCancellable?

        init(sync: SyncCoordinator) {
            self.sync = sync
            handler = SchemeHandler(sync: sync)
            super.init()
            // The spinner ends when the sync state stops running, however the run was started.
            runningBag = sync.$state.map(\.running).removeDuplicates().receive(on: RunLoop.main).sink { [weak self] running in
                if !running { self?.refresh?.endRefreshing() }
            }
            // A newly published generation is the only automatic web reload trigger.
            // A recent status GET is not evidence that the page is actively polling.
            bag = sync.$finishedRuns.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, let web = self.web else { return }
                web.reload()
            }
        }

        /// Pull-to-refresh: a full sync. If one is already running the spinner just waits for it to end.
        @objc func pulled() {
            if sync.state.running { return }
            sync.syncNow()
            // syncNow was a no-op (e.g. no run started): don't leave the spinner up.
            if !sync.state.running { refresh?.endRefreshing() }
        }

        #if DEBUG
        /// Manual checks: I20_DEBUG_SCROLL=<css selector> scrolls there once the page has drawn.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let sel = ProcessInfo.processInfo.environment["I20_DEBUG_SCROLL"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                webView.evaluateJavaScript("document.querySelector('\(sel)')?.scrollIntoView()")
            }
        }
        #endif

        /// Dashboard pages stay in the view; outside links (map attribution) open in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == SchemeHandler.scheme || action.targetFrame?.isMainFrame == false { return .allow }
            await UIApplication.shared.open(url)
            return .cancel
        }
    }
}
