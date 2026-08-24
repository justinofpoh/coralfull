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
    @State private var hasSemanticLabels = false
    @State private var showHealthyLabels = false
    @State private var showUnhealthyLabels = false
    @State private var activeViewerPanel: ReefViewerPanel?

    var body: some View {
        ZStack {
            Color(red: 0.024, green: 0.067, blue: 0.059)
                .ignoresSafeArea()

            ReefSplatWebView(
                showHealthy: showHealthyLabels,
                showUnhealthy: showUnhealthyLabels,
                onEvent: handleEvent
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            if !isReady {
                statusOverlay
            }

            VStack {
                scanChrome
                Spacer()
            }

            VStack {
                HStack {
                    Spacer()
                    viewerControlRail
                }
                Spacer()
            }
            .padding(.top, 92)
            .padding(.trailing, 26)
        }
        .onExitCommand(perform: onClose)
    }

    private var scanChrome: some View {
        HStack(spacing: 12) {

            Button(action: onClose) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
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

    private var viewerControlRail: some View {
        VStack(spacing: 4) {
            viewerControlButton(
                panel: .metadata,
                systemImage: "info.circle",
                help: "Open scan metadata"
            )
            .popover(isPresented: panelBinding(for: .metadata), arrowEdge: .trailing) {
                metadataPanel
            }

            viewerControlButton(
                panel: .filters,
                systemImage: "line.3.horizontal.decrease.circle",
                help: "Filter semantic labels on the 3D map",
                showsActiveState: showHealthyLabels || showUnhealthyLabels
            )
            .popover(isPresented: panelBinding(for: .filters), arrowEdge: .trailing) {
                semanticFilterPanel
            }
        }
        .padding(5)
        .background(.black.opacity(0.54), in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }

    private func viewerControlButton(
        panel: ReefViewerPanel,
        systemImage: String,
        help: String,
        showsActiveState: Bool = false
    ) -> some View {
        Button {
            activeViewerPanel = activeViewerPanel == panel ? nil : panel
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.white.opacity(0.9))

                if showsActiveState {
                    Circle()
                        .fill(Color(red: 0.34, green: 0.91, blue: 0.64))
                        .frame(width: 7, height: 7)
                        .overlay { Circle().stroke(.black.opacity(0.55), lineWidth: 1) }
                        .offset(x: -3, y: 3)
                }
            }
            .background(
                activeViewerPanel == panel ? .white.opacity(0.16) : .clear,
                in: Circle()
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func panelBinding(for panel: ReefViewerPanel) -> Binding<Bool> {
        Binding(
            get: { activeViewerPanel == panel },
            set: { isPresented in activeViewerPanel = isPresented ? panel : nil }
        )
    }

    private var metadataPanel: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Label("Scan metadata", systemImage: "info.circle")
                    .font(.headline)
                    .gridCellColumns(2)
            }
            GridRow {
                Text("Site").foregroundStyle(.secondary)
                Text(site.name).frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Photos").foregroundStyle(.secondary)
                Text(site.photoCount.formatted()).frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Representation").foregroundStyle(.secondary)
                Text("Gaussian splat").frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Renderer").foregroundStyle(.secondary)
                Text("Spark").frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Semantic labels").foregroundStyle(.secondary)
                Text(hasSemanticLabels ? "Available" : "Loading or unavailable")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.caption)
        .padding(16)
        .frame(width: 310)
    }

    private var semanticFilterPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Semantic filter", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                Text("Highlight semantic labels directly on the Gaussian-splat map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $showHealthyLabels) {
                Label("Healthy coral", systemImage: "circle.fill")
                    .foregroundStyle(Color(red: 0.0, green: 0.78, blue: 0.0))
            }
            .disabled(!hasSemanticLabels)

            Toggle(isOn: $showUnhealthyLabels) {
                Label("Unhealthy coral", systemImage: "circle.fill")
                    .foregroundStyle(Color(red: 0.86, green: 0.12, blue: 0.12))
            }
            .disabled(!hasSemanticLabels)

            if !hasSemanticLabels {
                Text("Semantic labels are loading. Controls will become available when the viewer finishes preparing them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
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
        case "semantic-ready":
            hasSemanticLabels = true
        case "semantic-unavailable":
            hasSemanticLabels = false
            showHealthyLabels = false
            showUnhealthyLabels = false
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

private enum ReefViewerPanel: String {
    case metadata
    case filters
}

private struct ReefSplatWebView: NSViewRepresentable {
    let showHealthy: Bool
    let showUnhealthy: Bool
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
        context.coordinator.setSemanticFilter(
            healthy: showHealthy,
            unhealthy: showUnhealthy
        )
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
        private var didFinishLoading = false
        private var showHealthy = false
        private var showUnhealthy = false

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

        func setSemanticFilter(healthy: Bool, unhealthy: Bool) {
            showHealthy = healthy
            showUnhealthy = unhealthy
            applySemanticFilterIfPossible()
        }

        private func applySemanticFilterIfPossible() {
            guard didFinishLoading, let webView else { return }
            let script = "window.setSemanticFilter?.({ healthy: \(showHealthy), unhealthy: \(showUnhealthy) });"
            webView.evaluateJavaScript(script)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishLoading = true
            applySemanticFilterIfPossible()
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
