//
//  ReefScanView.swift
//  coralfull
//

import AppKit
import SwiftUI
import WebKit

struct ReefScanView: View {
    let site: CoralSite
    let onClose: () -> Void

    @State private var loadMessage = "Loading the 3D reef"
    @State private var loadDetail = "Starting Spark…"
    @State private var errorMessage: String?
    @State private var isReady = false
    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            Color(red: 0.024, green: 0.067, blue: 0.059)
                .ignoresSafeArea()

            ReefSplatWebView(onEvent: handleEvent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            if !isReady {
                statusOverlay
            }

            VStack {
                scanChrome
                Spacer()
            }
        }
        .onExitCommand(perform: onClose)
    }

    private var scanChrome: some View {
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.left", action: onClose)
                .buttonStyle(.bordered)
            .help("Back to dashboard")
            .keyboardShortcut(.escape, modifiers: [])

            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Gaussian splat · Spark")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.18),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorMessage {
                Text("We couldn’t load the reef.")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(loadMessage)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                Text(loadDetail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                if progress > 0 {
                    ProgressView(value: progress)
                        .tint(Color(red: 0.27, green: 0.74, blue: 0.58))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .allowsHitTesting(errorMessage != nil)
    }

    private func handleEvent(_ event: ReefLoadEvent) {
        switch event.phase {
        case "ready":
            isReady = true
            errorMessage = nil
        case "error":
            isReady = false
            errorMessage = event.message.isEmpty ? "Spark could not load the gaussian splat." : event.message
        case "loading":
            isReady = false
            errorMessage = nil
            progress = Double(event.progress) / 100
            loadMessage = "Loading the 3D reef"
            loadDetail = event.progress > 0
                ? "\(event.progress)% loaded"
                : "Reading the gaussian splat…"
        default:
            if !event.message.isEmpty {
                loadDetail = event.message
            }
        }
    }
}

private struct ReefLoadEvent {
    var phase: String
    var progress: Int
    var message: String
}

private struct ReefSplatWebView: NSViewRepresentable {
    let onEvent: (ReefLoadEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeNSView(context: Context) -> NSView {
        let container = ReefWebContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.024, green: 0.067, blue: 0.059, alpha: 1).cgColor

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "reef")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        context.coordinator.webView = webView
        context.coordinator.loadWhenReady(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEvent = onEvent
        if let webView = context.coordinator.webView {
            webView.frame = nsView.bounds
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reef")
        coordinator.webView?.stopLoading()
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onEvent: (ReefLoadEvent) -> Void
        weak var webView: WKWebView?
        private var server: ReefAssetServer?
        private var didStartLoad = false

        init(onEvent: @escaping (ReefLoadEvent) -> Void) {
            self.onEvent = onEvent
        }

        func loadWhenReady(in container: ReefWebContainerView) {
            container.onHasSize = { [weak self, weak container] in
                guard let self, let container else { return }
                self.start(in: container)
            }
            if container.bounds.width > 8, container.bounds.height > 8 {
                start(in: container)
            }
        }

        private func start(in container: NSView) {
            guard !didStartLoad else { return }
            didStartLoad = true

            guard let webView else { return }
            webView.frame = container.bounds

            Task { @MainActor in
                do {
                    guard let root = ReefAssetServer.bundledRoot() else {
                        throw ReefAssetServerError.missingViewerRoot
                    }
                    let server = ReefAssetServer(root: root)
                    self.server = server
                    let pageURL = try await server.start()
                    webView.load(URLRequest(url: pageURL))
                    onEvent(ReefLoadEvent(phase: "loading", progress: 0, message: "Spark is starting…"))
                } catch {
                    onEvent(ReefLoadEvent(phase: "error", progress: 0, message: error.localizedDescription))
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let event = ReefLoadEvent(
                phase: body["phase"] as? String ?? "log",
                progress: body["progress"] as? Int ?? 0,
                message: body["message"] as? String ?? ""
            )
            onEvent(event)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onEvent(ReefLoadEvent(phase: "error", progress: 0, message: error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onEvent(ReefLoadEvent(phase: "error", progress: 0, message: error.localizedDescription))
        }
    }
}

final class ReefWebContainerView: NSView {
    var onHasSize: (() -> Void)?
    private var didNotify = false

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
        notifyIfReady()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        subviews.forEach { $0.frame = bounds }
        notifyIfReady()
    }

    private func notifyIfReady() {
        guard !didNotify, bounds.width > 8, bounds.height > 8 else { return }
        didNotify = true
        onHasSize?()
    }
}
