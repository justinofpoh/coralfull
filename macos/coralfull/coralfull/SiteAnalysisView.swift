//
//  SiteAnalysisView.swift
//  coralfull
//
//  The 3D analysis screen shared by bundled Livingseas sites (Main Reef
//  Structure and Site B / Reef Star Patch) and uploaded sites: textured
//  Metashape PLY viewer, capture timeline with synchronized RGB / semantic /
//  dense-depth cards, camera vs 3D-view depth, 3D health-label filters, and a
//  reconstruction metadata panel.
//

import AppKit
import Combine
import Metal
import SceneKit
import SwiftUI

struct SiteAnalysisView: View {
    let siteName: String
    let onClose: () -> Void

    @StateObject private var artifacts: SiteAnalysisArtifacts
    @StateObject private var viewportDepth = ViewportDepthRenderer()
    @StateObject private var meshModel = SiteMeshModel()
    @State private var displayMode: MeshDisplayMode = .texture
    @State private var depthSource: DepthSource = .camera
    @State private var isAutoPlaying = false
    @State private var showHealthyLabels = false
    @State private var showUnhealthyLabels = false
    @State private var activeViewerPanel: ViewerPanel?

    private let autoAdvance = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    private static let accent = Color(red: 0.34, green: 0.91, blue: 0.64)
    private static let healthyColor = Color(red: 0.0, green: 0.78, blue: 0.0)
    private static let unhealthyColor = Color(red: 0.86, green: 0.12, blue: 0.12)

    init(siteName: String, source: SiteAnalysisSource, onClose: @escaping () -> Void) {
        self.siteName = siteName
        self.onClose = onClose
        _artifacts = StateObject(wrappedValue: SiteAnalysisArtifacts(source: source))
    }

    var body: some View {
        ZStack {
            Color(red: 0.024, green: 0.067, blue: 0.059)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 14) {
                        reconstructionPanel
                        timelinePanel
                    }

                    analysisRail
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .onAppear {
            artifacts.startWatching()
        }
        .onDisappear {
            artifacts.stopWatching()
            viewportDepth.setActive(false)
            isAutoPlaying = false
        }
        .onChange(of: depthSource) { _, source in
            viewportDepth.setActive(source == .viewport)
        }
        .onReceive(autoAdvance) { _ in
            guard isAutoPlaying, !artifacts.frames.isEmpty else { return }
            let next = artifacts.selectedIndex + 1
            artifacts.select(index: next < artifacts.frames.count ? next : 0)
        }
        .onExitCommand(perform: onClose)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.left", action: onClose)
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back to dashboard")

            VStack(alignment: .leading, spacing: 2) {
                Text(siteName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Metashape reconstruction · CoralScapes segmentation")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.18))
    }

    // MARK: 3D reconstruction

    private var reconstructionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("3D reconstruction")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(meshSubtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                }

                Spacer()

                Picker("Render", selection: $displayMode) {
                    ForEach(MeshDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
            }

            ZStack(alignment: .bottomLeading) {
                MetashapeMeshView(
                    displayMode: displayMode,
                    meshAssets: artifacts.meshAssets,
                    showHealthy: showHealthyLabels,
                    showUnhealthy: showUnhealthyLabels,
                    meshModel: meshModel,
                    depthRenderer: viewportDepth
                )
                .clipShape(.rect(cornerRadius: 18))

                HStack(spacing: 8) {
                    Label("Drag to orbit", systemImage: "rotate.3d")
                    Label("Scroll to zoom", systemImage: "magnifyingglass")
                    if depthSource == .viewport {
                        Label("Orbit updates the 3D-view depth card", systemImage: "mountain.2.fill")
                            .foregroundStyle(Self.accent)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(14)
            }
            .overlay(alignment: .topTrailing) {
                viewerControlRail
                    .padding(14)
            }
            .frame(minHeight: 340)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }

        }
        .padding(18)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var meshSubtitle: String {
        var parts = [siteName]
        if let vertices = artifacts.sequence?.mesh?.vertices ?? meshModel.vertexCount,
           let faces = artifacts.sequence?.mesh?.faces ?? meshModel.faceCount {
            parts.append("\(vertices.formatted()) vertices")
            parts.append("\(faces.formatted()) faces")
        }
        parts.append("Agisoft Metashape")
        return parts.joined(separator: " · ")
    }

    /// Floating controls expose metadata and semantic filtering. Output views
    /// remain visible in the fixed analysis rail beside the reconstruction.
    private var viewerControlRail: some View {
        VStack(spacing: 4) {
            viewerControlButton(
                panel: .metadata,
                systemImage: "info.circle",
                help: "Open reconstruction metadata"
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
        panel: ViewerPanel,
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
                        .fill(Self.accent)
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

    private func panelBinding(for panel: ViewerPanel) -> Binding<Bool> {
        Binding(
            get: { activeViewerPanel == panel },
            set: { isPresented in
                activeViewerPanel = isPresented ? panel : nil
            }
        )
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Reconstruction metadata", systemImage: "info.circle")
                    .font(.headline)
                Text("Metashape and segmentation details for \(siteName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if metadataRows.isEmpty {
                Text("Metadata will appear after the reconstruction is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(metadataRows, id: \.0) { row in
                        GridRow {
                            Text(row.0)
                                .foregroundStyle(.secondary)
                            Text(row.1)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private var semanticFilterPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Semantic filter", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                Text("Highlight CoralScapes labels directly on the 3D mesh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if meshModel.hasLabels {
                semanticFilterToggle(
                    title: "Healthy coral",
                    count: labelCount("healthy"),
                    color: Self.healthyColor,
                    isOn: $showHealthyLabels
                )
                semanticFilterToggle(
                    title: "Unhealthy coral",
                    count: labelCount("unhealthy"),
                    color: Self.unhealthyColor,
                    isOn: $showUnhealthyLabels
                )
            } else {
                Label("3D semantic labels are not available for this site yet.", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 310)
    }

    private func semanticFilterToggle(
        title: String,
        count: Int?,
        color: Color,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 9) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title)
                Spacer()
                if let count {
                    Text(count.formatted(.number.notation(.compactName)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.45 : 1)
    }

    private func labelCount(_ key: String) -> Int? {
        artifacts.sequence?.labels3d?.counts[key] ?? meshModel.labelCounts[key]
    }

    private func healthFilterChip(
        title: String,
        count: Int?,
        color: Color,
        isOn: Binding<Bool>
    ) -> some View {
        let empty = count == 0
        return Button {
            guard !empty else { return }
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(empty ? "\(title) · none detected" : title)
                    .font(.caption.weight(.semibold))
                if let count, count > 0 {
                    Text(count.formatted(.number.notation(.compactName)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isOn.wrappedValue ? color.opacity(0.3) : .white.opacity(0.07),
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(
                    isOn.wrappedValue ? color : .white.opacity(0.16),
                    lineWidth: 1
                )
            }
            .foregroundStyle(.white.opacity(empty ? 0.45 : 0.92))
        }
        .buttonStyle(.plain)
        .help(
            empty
                ? "\(title) coral: zero detections in the lifted 3D labels"
                : "Highlight \(title.lowercased()) coral vertices on the mesh"
        )
    }

    // MARK: Capture timeline

    @ViewBuilder
    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture timeline")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    if let frame = artifacts.selectedFrame {
                        Text(timelineSubtitle(for: frame))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.58))
                            .contentTransition(.numericText())
                    } else {
                        Text("Waiting for analysis frames…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }

                Spacer()

                if artifacts.isFrameLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                HStack(spacing: 6) {
                    Button {
                        isAutoPlaying = false
                        artifacts.selectPrevious()
                    } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(artifacts.selectedIndex <= 0)
                    .help("Previous frame")

                    Button {
                        isAutoPlaying.toggle()
                    } label: {
                        Image(systemName: isAutoPlaying ? "pause.fill" : "play.fill")
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help(isAutoPlaying ? "Pause playback" : "Play through the capture sequence")

                    Button {
                        isAutoPlaying = false
                        artifacts.selectNext()
                    } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(artifacts.selectedIndex >= artifacts.frames.count - 1)
                    .help("Next frame")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.white)
                .disabled(artifacts.frames.isEmpty)
            }

            if artifacts.frames.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .frame(height: 54)
                    .overlay {
                        Text("The frame strip appears once analysis artifacts are available.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
            } else {
                thumbnailStrip

                Slider(
                    value: Binding(
                        get: { Double(artifacts.selectedIndex) },
                        set: { value in
                            isAutoPlaying = false
                            artifacts.select(index: Int(value.rounded()))
                        }
                    ),
                    in: 0...Double(max(artifacts.frames.count - 1, 1)),
                    step: 1
                )
                .tint(Self.accent)

                HStack {
                    Text(artifacts.frames.first?.label ?? "")
                    Spacer()
                    Text("\(artifacts.selectedIndex + 1) of \(artifacts.frames.count) frames")
                        .contentTransition(.numericText())
                    Spacer()
                    Text(artifacts.frames.last?.label ?? "")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.42))
                .monospacedDigit()
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(artifacts.frames.enumerated()), id: \.element.id) { index, frame in
                        Button {
                            isAutoPlaying = false
                            artifacts.select(index: index)
                        } label: {
                            frameThumbnail(frame: frame, isSelected: index == artifacts.selectedIndex)
                        }
                        .buttonStyle(.plain)
                        .id(frame.id)
                        .help("\(frame.label) · camera \(frame.cameraId)")
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: artifacts.selectedIndex) { _, index in
                guard artifacts.frames.indices.contains(index) else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(artifacts.frames[index].id, anchor: .center)
                }
            }
        }
    }

    private func frameThumbnail(frame: AnalysisFrame, isSelected: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = artifacts.thumbnails[frame.label] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [.teal.opacity(0.28), .black.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(width: 86, height: 50)
            .clipped()

            Text(frame.shortNumber)
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                .padding(3)
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected ? Self.accent : .white.opacity(0.12),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .opacity(isSelected ? 1 : 0.82)
    }

    private func timelineSubtitle(for frame: AnalysisFrame) -> String {
        var parts = [frame.label]
        if let captured = frame.capturedDate {
            parts.append(captured.formatted(date: .abbreviated, time: .standard))
        }
        parts.append("camera \(frame.cameraId)")
        return parts.joined(separator: " · ")
    }

    private var analysisRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analysis")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(railSubtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .contentTransition(.numericText())
            }

            switch artifacts.state {
            case .loading:
                loadingCard
            case .unavailable(let message):
                unavailableCard(message: message)
            case .ready:
                if let frame = artifacts.selectedFrame {
                    frameCards(for: frame)
                } else {
                    Text("No processed frames are available yet.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
            }

        }
        .padding(16)
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func frameCards(for frame: AnalysisFrame) -> some View {
        AnalysisPreviewCard(
            title: "RGB input",
            subtitle: rgbSubtitle(for: frame),
            systemImage: "camera.fill",
            image: artifacts.inputImage,
            isLoading: artifacts.isFrameLoading
        )
        .frame(maxHeight: .infinity)
        AnalysisPreviewCard(
            title: "Semantic segmentation",
            subtitle: semanticSubtitle(for: frame),
            systemImage: "square.3.layers.3d.down.right",
            image: artifacts.semanticImage,
            isLoading: artifacts.isFrameLoading
        )
        .frame(maxHeight: .infinity)
        depthCard(for: frame)
            .frame(maxHeight: .infinity)
    }

    private var railSubtitle: String {
        guard let frame = artifacts.selectedFrame else {
            return "Processed survey outputs"
        }
        return "Frame \(frame.shortNumber) · processed outputs"
    }

    private func rgbSubtitle(for frame: AnalysisFrame) -> String {
        if let captured = frame.capturedDate {
            return "\(frame.label) · \(captured.formatted(date: .omitted, time: .standard))"
        }
        return frame.label
    }

    private func semanticSubtitle(for frame: AnalysisFrame) -> String {
        var text = "CoralScapes · \(frame.healthyPercent.formatted(.number.precision(.fractionLength(1))))% healthy"
        if frame.unhealthyPercent >= 0.1 {
            text += " · \(frame.unhealthyPercent.formatted(.number.precision(.fractionLength(1))))% unhealthy"
        }
        return text
    }

    private var depthScaleCalibrated: Bool {
        artifacts.sequence?.scale.calibrated ?? false
    }

    private func depthCard(for frame: AnalysisFrame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if depthSource == .camera {
                        AnalysisPreviewImage(image: artifacts.depthImage, isLoading: artifacts.isFrameLoading)
                    } else {
                        AnalysisPreviewImage(
                            image: viewportDepth.image,
                            isLoading: !viewportDepth.isMeshReady,
                            emptyMessage: viewportDepth.isMeshReady ? nil : "Loading 3D mesh…"
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: 12))

                Text(depthScaleCalibrated ? "CALIBRATED" : "RELATIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Self.accent.opacity(0.9), in: Capsule())
                    .padding(8)
                    .help(
                        depthScaleCalibrated
                            ? "This reconstruction has a scale constraint applied."
                            : "Depth values are relative — the reconstruction has not been scale-calibrated yet."
                    )
            }

            HStack {
                Text("Depth")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Picker("Depth source", selection: $depthSource) {
                    ForEach(DepthSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 150)
                .labelsHidden()
            }
        }
        .padding(10)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    // MARK: Metadata

    private var metadataRows: [(String, String)] {
        var rows = [(String, String)]()
        let sequence = artifacts.sequence
        if let version = sequence?.metashape?.version {
            rows.append(("Metashape", version))
        }
        if let created = sequence?.metashape?.createdAt {
            rows.append(("Reconstructed", Self.displayDate(created)))
        }
        if let photos = sequence?.metashape?.photoCount {
            let aligned = sequence?.metashape?.alignedCameras
            rows.append(("Photos", aligned.map { "\(photos) (\($0) aligned)" } ?? "\(photos)"))
        }
        if let resolution = sequence?.metashape?.imageResolution, resolution.count == 2 {
            rows.append(("Source resolution", "\(resolution[0])×\(resolution[1])"))
        }
        if let vertices = sequence?.mesh?.vertices ?? meshModel.vertexCount {
            rows.append(("Mesh vertices", vertices.formatted()))
        }
        if let faces = sequence?.mesh?.faces ?? meshModel.faceCount {
            rows.append(("Mesh faces", faces.formatted()))
        }
        if let texture = sequence?.mesh?.textureSize {
            rows.append(("Texture", "\(texture)×\(texture)"))
        }
        if let model = sequence?.semanticModel {
            rows.append(("Semantic model", model))
        }
        rows.append(("Scale", (sequence?.scale.calibrated ?? false) ? "Calibrated" : "Not calibrated"))
        if let generated = sequence?.generatedAt {
            rows.append(("Analysis generated", Self.displayDate(generated)))
        }
        return rows
    }

    private static func displayDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var loadingCard: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(.white)
            Text("Loading analysis artifacts…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func unavailableCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Artifacts unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.35))
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            Text(artifacts.source.directory.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.4))
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

}

// MARK: - Supporting types

private enum ViewerPanel: String, Identifiable {
    case metadata
    case filters

    var id: String { rawValue }
}

private enum MeshDisplayMode: String, CaseIterable, Identifiable {
    case texture
    case contrast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .texture: "Colour"
        case .contrast: "Wireframe"
        }
    }
}

private enum DepthSource: String, CaseIterable, Identifiable {
    case camera
    case viewport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "Camera"
        case .viewport: "3D view"
        }
    }
}

private struct AnalysisPreviewCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let image: NSImage?
    var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AnalysisPreviewImage(image: image, isLoading: isLoading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(.rect(cornerRadius: 12))

                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(8)
            }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(10)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct AnalysisPreviewImage: View {
    let image: NSImage?
    var isLoading = false
    var emptyMessage: String? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [.cyan.opacity(0.28), .teal.opacity(0.08)], startPoint: .top, endPoint: .bottom)
                if let emptyMessage {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// MARK: - Mesh state shared with SwiftUI

/// Published facts about the loaded mesh (counts, label availability) so the
/// SwiftUI chrome can react to what the SceneKit coordinator loaded.
@MainActor
final class SiteMeshModel: ObservableObject {
    @Published var vertexCount: Int?
    @Published var faceCount: Int?
    @Published var hasLabels = false
    @Published var labelCounts: [String: Int] = [:]
}

// MARK: - Viewport depth renderer

/// Renders a relative-depth image of the reconstruction from the *current*
/// SceneKit viewpoint, so the depth card can mirror whatever angle the user
/// has orbited to. Uses an offscreen SCNRenderer with a clone of the mesh whose
/// material shades view-space distance through the shared depth colour ramp.
@MainActor
final class ViewportDepthRenderer: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isMeshReady = false

    private weak var sceneView: SCNView?
    private var renderer: SCNRenderer?
    private var depthCameraNode = SCNNode()
    private var depthMaterial: SCNMaterial?
    private var boundingRadius: CGFloat = 0.9
    private var timer: Timer?
    private var lastTransform = SCNMatrix4Identity
    private var hasRendered = false
    private var isActive = false

    func attach(view: SCNView) {
        sceneView = view
    }

    func installMesh(_ meshNode: SCNNode) {
        let depthNode = meshNode.clone()
        if let geometry = meshNode.geometry?.copy() as? SCNGeometry {
            let material = Self.makeDepthMaterial()
            geometry.materials = [material]
            depthNode.geometry = geometry
            depthMaterial = material
        }

        let scene = SCNScene()
        scene.background.contents = NSColor(red: 7 / 255, green: 23 / 255, blue: 38 / 255, alpha: 1)
        scene.rootNode.addChildNode(depthNode)

        depthCameraNode = SCNNode()
        depthCameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(depthCameraNode)

        // The mesh node is normalised to unit size and centred via its pivot,
        // so its world-space bounding radius is the local radius times scale.
        boundingRadius = max(CGFloat(depthNode.boundingSphere.radius) * depthNode.scale.x, 0.05)

        let offscreen = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        offscreen.scene = scene
        offscreen.pointOfView = depthCameraNode
        offscreen.autoenablesDefaultLighting = false
        renderer = offscreen

        isMeshReady = true
        hasRendered = false
        if isActive { renderNow(force: true) }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            renderNow(force: true)
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.renderNow(force: false)
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func renderNow(force: Bool) {
        guard let view = sceneView,
              let renderer,
              let pointOfView = view.pointOfView else { return }

        let presentation = pointOfView.presentation
        let transform = presentation.worldTransform
        if !force, hasRendered, SCNMatrix4EqualToMatrix4(transform, lastTransform) { return }
        lastTransform = transform

        depthCameraNode.transform = transform
        if let camera = pointOfView.camera?.copy() as? SCNCamera {
            camera.wantsHDR = false
            depthCameraNode.camera = camera
        }

        // Coarse bounds from the model's bounding sphere, then a low-resolution
        // analysis pass measures the depth span actually visible from this
        // angle so the final image uses the full colour ramp at any zoom.
        let position = presentation.worldPosition
        let distance = CGFloat(
            (position.x * position.x + position.y * position.y + position.z * position.z)
                .squareRoot()
        )
        var near = max(distance - boundingRadius, 0.01)
        var far = max(distance + boundingRadius, near + 0.01)

        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let aspect = bounds.height / bounds.width

        if let visible = measureVisibleDepthRange(coarseNear: near, coarseFar: far, aspect: aspect) {
            let padding = max((visible.far - visible.near) * 0.03, 0.001)
            near = visible.near - padding
            far = visible.far + padding
        }
        depthMaterial?.setValue(NSNumber(value: 0), forKey: "uAnalysis")
        depthMaterial?.setValue(NSNumber(value: Double(near)), forKey: "uNear")
        depthMaterial?.setValue(NSNumber(value: Double(far)), forKey: "uFar")

        let width: CGFloat = 720
        let size = CGSize(width: width, height: max(1, (width * aspect).rounded()))
        image = renderer.snapshot(atTime: CACurrentMediaTime(), with: size, antialiasingMode: .multisampling2X)
        hasRendered = true
    }

    /// Renders a small grayscale-depth pass and reads back the min/max visible
    /// distance. Returns nil when no geometry is in view.
    private func measureVisibleDepthRange(
        coarseNear: CGFloat,
        coarseFar: CGFloat,
        aspect: CGFloat
    ) -> (near: CGFloat, far: CGFloat)? {
        guard let renderer, let depthMaterial else { return nil }

        depthMaterial.setValue(NSNumber(value: 1), forKey: "uAnalysis")
        depthMaterial.setValue(NSNumber(value: Double(coarseNear)), forKey: "uNear")
        depthMaterial.setValue(NSNumber(value: Double(coarseFar)), forKey: "uFar")

        let width: CGFloat = 96
        let size = CGSize(width: width, height: max(1, (width * aspect).rounded()))
        let snapshot = renderer.snapshot(atTime: CACurrentMediaTime(), with: size, antialiasingMode: .none)

        guard let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // The shader encodes normalised depth into linear 0.06...1.0 grey; the
        // snapshot is sRGB-encoded, so linearise before decoding. Anything
        // darker than the encoding floor is background.
        var minimumT = CGFloat.greatestFiniteMagnitude
        var maximumT = -CGFloat.greatestFiniteMagnitude
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let srgb = CGFloat(pixels[index]) / 255
            let linear = srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
            guard linear > 0.045 else { continue }
            let t = (linear - 0.06) / 0.94
            minimumT = min(minimumT, t)
            maximumT = max(maximumT, t)
        }
        guard maximumT >= minimumT else { return nil }

        let span = coarseFar - coarseNear
        let near = coarseNear + max(minimumT, 0) * span
        let far = coarseNear + min(maximumT, 1) * span
        guard far > near else { return nil }
        return (near, far)
    }

    private static func makeDepthMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = NSColor.white
        // Matches DEPTH_STOPS in tools/site_b_live_analysis.py: near is warm,
        // far is cool, identical to the per-camera Metashape depth maps.
        material.shaderModifiers = [
            .fragment: """
            #pragma arguments
            float uNear;
            float uFar;
            float uAnalysis;
            #pragma body
            float dist = length(_surface.position.xyz);
            float t = clamp((dist - uNear) / max(uFar - uNear, 0.0001), 0.0, 1.0);
            if (uAnalysis > 0.5) {
                float grey = mix(0.06, 1.0, t);
                _output.color = float4(grey, grey, grey, 1.0);
            } else {
                float n = 1.0 - t;
                float3 stops[8];
                stops[0] = float3(0.122, 0.153, 0.471);
                stops[1] = float3(0.188, 0.318, 0.808);
                stops[2] = float3(0.114, 0.600, 0.902);
                stops[3] = float3(0.200, 0.804, 0.600);
                stops[4] = float3(0.608, 0.882, 0.275);
                stops[5] = float3(0.961, 0.867, 0.216);
                stops[6] = float3(0.969, 0.525, 0.149);
                stops[7] = float3(0.776, 0.173, 0.145);
                float rampPosition = n * 7.0;
                int lowerStop = int(floor(rampPosition));
                int upperStop = min(lowerStop + 1, 7);
                float3 rampColor = mix(
                    stops[lowerStop],
                    stops[upperStop],
                    rampPosition - float(lowerStop)
                );
                _output.color = float4(rampColor, 1.0);
            }
            """
        ]
        return material
    }
}

// MARK: - SceneKit mesh view

private struct MetashapeMeshView: NSViewRepresentable {
    let displayMode: MeshDisplayMode
    let meshAssets: (ply: URL, texture: URL?, labels: URL?)?
    let showHealthy: Bool
    let showUnhealthy: Bool
    let meshModel: SiteMeshModel
    let depthRenderer: ViewportDepthRenderer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(red: 0.018, green: 0.045, blue: 0.041, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 30
        view.scene = ReefMeshScene.makePlaceholder()
        depthRenderer.attach(view: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if let meshAssets {
            context.coordinator.loadMeshIfNeeded(
                assets: meshAssets,
                into: view,
                meshModel: meshModel,
                depthRenderer: depthRenderer
            )
        }
        context.coordinator.update(
            displayMode: displayMode,
            showHealthy: showHealthy,
            showUnhealthy: showUnhealthy,
            in: view
        )
    }

    @MainActor
    final class Coordinator {
        private var loadedMesh: MetashapePLYLoader.LoadedMesh?
        private var loadedURL: URL?
        private var isLoading = false
        private var currentMode: MeshDisplayMode = .texture
        private var textureImage: NSImage?

        func loadMeshIfNeeded(
            assets: (ply: URL, texture: URL?, labels: URL?),
            into view: SCNView,
            meshModel: SiteMeshModel,
            depthRenderer: ViewportDepthRenderer
        ) {
            guard loadedURL != assets.ply, !isLoading else { return }
            isLoading = true
            loadedURL = assets.ply

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let mesh = try MetashapePLYLoader.loadMesh(
                        from: assets.ply,
                        textureURL: assets.texture,
                        labelsURL: assets.labels
                    )
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.isLoading = false
                        self.loadedMesh = mesh
                        self.textureImage = mesh.texture
                        let scene = ReefMeshScene.scene(with: mesh.rootNode)
                        view.scene = scene
                        view.pointOfView = scene.rootNode.childNode(
                            withName: "initialReefCamera",
                            recursively: false
                        )
                        self.update(
                            displayMode: self.currentMode,
                            showHealthy: false,
                            showUnhealthy: false,
                            in: view
                        )
                        meshModel.vertexCount = mesh.vertexCount
                        meshModel.faceCount = mesh.faceCount
                        meshModel.hasLabels = mesh.healthyNode != nil || mesh.unhealthyNode != nil
                        meshModel.labelCounts = mesh.labelCounts
                        depthRenderer.installMesh(mesh.depthProxyNode)
                    }
                } catch {
                    DispatchQueue.main.async { [weak self, weak view] in
                        self?.isLoading = false
                        view?.scene = ReefMeshScene.errorScene(message: error.localizedDescription)
                    }
                }
            }
        }

        func update(
            displayMode: MeshDisplayMode,
            showHealthy: Bool,
            showUnhealthy: Bool,
            in view: SCNView
        ) {
            currentMode = displayMode
            guard let mesh = loadedMesh else { return }
            let material = mesh.baseNode.geometry?.firstMaterial
            material?.fillMode = displayMode == .contrast ? .lines : .fill
            material?.diffuse.contents = displayMode == .texture
                ? textureImage ?? NSColor.white
                : NSColor(red: 0.32, green: 0.76, blue: 0.70, alpha: 1)
            mesh.healthyNode?.isHidden = !showHealthy
            mesh.unhealthyNode?.isHidden = !showUnhealthy
        }
    }
}

private enum ReefMeshScene {
    static func makePlaceholder() -> SCNScene {
        let scene = SCNScene()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = false
        camera.zFar = 100
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 0, 2.4)
        scene.rootNode.addChildNode(node)
        return scene
    }

    static func scene(with mesh: SCNNode) -> SCNScene {
        let scene = SCNScene()
        scene.rootNode.addChildNode(mesh)

        let camera = SCNCamera()
        camera.fieldOfView = 48
        camera.zNear = 0.01
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        // The mesh is normalised to a unit-sized bounding box. Start close
        // enough to make the textured reconstruction the focus on open.
        cameraNode.name = "initialReefCamera"
        cameraNode.position = SCNVector3(0, 0, 0.95)
        scene.rootNode.addChildNode(cameraNode)

        let light = SCNLight()
        light.type = .directional
        light.intensity = 1_200
        light.castsShadow = false
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.eulerAngles = SCNVector3(-0.55, 0.35, 0)
        scene.rootNode.addChildNode(lightNode)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = NSColor(white: 0.72, alpha: 1)
        ambientLight.intensity = 700
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    static func errorScene(message: String) -> SCNScene {
        let scene = makePlaceholder()
        let text = SCNText(string: "3D mesh unavailable\n\(message)", extrusionDepth: 0)
        text.font = NSFont.systemFont(ofSize: 0.08, weight: .medium)
        text.firstMaterial?.diffuse.contents = NSColor.white
        text.alignmentMode = CATextLayerAlignmentMode.center.rawValue
        let node = SCNNode(geometry: text)
        node.position = SCNVector3(-0.75, 0, 0)
        scene.rootNode.addChildNode(node)
        return scene
    }
}

// MARK: - Metashape PLY loader

enum MetashapePLYLoader {
    /// A loaded Metashape mesh: the normalised parent node containing the
    /// textured base geometry plus optional healthy/unhealthy overlay nodes
    /// built from the lifted per-vertex semantic labels.
    struct LoadedMesh {
        let rootNode: SCNNode
        let baseNode: SCNNode
        let healthyNode: SCNNode?
        let unhealthyNode: SCNNode?
        /// Geometry-only node with matching pivot/scale for the depth renderer.
        let depthProxyNode: SCNNode
        let texture: NSImage?
        let vertexCount: Int
        let faceCount: Int
        let labelCounts: [String: Int]
    }

    static func loadMesh(from url: URL, textureURL: URL?, labelsURL: URL?) throws -> LoadedMesh {
        let data = try Data(contentsOf: url)
        guard let headerEnd = data.range(of: Data("end_header\n".utf8)) else {
            throw PLYError.invalidHeader
        }
        let header = String(decoding: data[..<headerEnd.upperBound], as: UTF8.self)
        guard header.contains("format binary_little_endian 1.0") else {
            throw PLYError.unsupportedFormat
        }

        let vertexCount = value(named: "vertex", in: header)
        let faceCount = value(named: "face", in: header)
        guard vertexCount > 0, faceCount > 0 else { throw PLYError.invalidHeader }
        let layout = try VertexLayout(header: header)

        var reader = BinaryReader(data: data, offset: headerEnd.upperBound)
        var vertices = [SCNVector3]()
        var normals = [SCNVector3]()
        vertices.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)

        for _ in 0 ..< vertexCount {
            let start = reader.offset
            vertices.append(
                SCNVector3(
                    reader.float32(at: start + layout.positionOffset),
                    reader.float32(at: start + layout.positionOffset + 4),
                    reader.float32(at: start + layout.positionOffset + 8)
                )
            )
            if let normalOffset = layout.normalOffset {
                normals.append(
                    SCNVector3(
                        reader.float32(at: start + normalOffset),
                        reader.float32(at: start + normalOffset + 4),
                        reader.float32(at: start + normalOffset + 8)
                    )
                )
            } else {
                normals.append(SCNVector3(0, 0, 1))
            }
            reader.offset = start + layout.stride
        }

        // Per-vertex semantic labels (0 other, 1 healthy, 2 unhealthy) written
        // by the analysis pipeline, one byte per PLY vertex.
        var labels: [UInt8]? = nil
        if let labelsURL,
           let labelData = try? Data(contentsOf: labelsURL),
           labelData.count == vertexCount {
            labels = [UInt8](labelData)
        }

        // Metashape stores UVs per face corner, rather than per source vertex.
        // Duplicate each triangle's corners so SceneKit can retain that mapping.
        var renderVertices = [SCNVector3]()
        var renderNormals = [SCNVector3]()
        var textureCoordinates = [CGPoint]()
        var indices = [UInt32]()
        var cornerSources = [Int]()
        renderVertices.reserveCapacity(faceCount * 3)
        renderNormals.reserveCapacity(faceCount * 3)
        textureCoordinates.reserveCapacity(faceCount * 3)
        indices.reserveCapacity(faceCount * 3)
        cornerSources.reserveCapacity(faceCount * 3)

        for _ in 0 ..< faceCount {
            let count = Int(reader.uint8())
            let face = (0 ..< count).map { _ in reader.uint32() }
            var faceTextureCoordinates = [Float]()
            if layout.faceHasTextureCoordinates {
                let textureCoordinateCount = Int(reader.uint8())
                faceTextureCoordinates = (0 ..< textureCoordinateCount).map { _ in reader.float32() }
            }

            guard count == 3 else { continue }
            for corner in 0 ..< 3 {
                let sourceIndex = Int(face[corner])
                guard vertices.indices.contains(sourceIndex) else { continue }

                renderVertices.append(vertices[sourceIndex])
                renderNormals.append(normals[sourceIndex])
                cornerSources.append(sourceIndex)
                let uvOffset = corner * 2
                if faceTextureCoordinates.indices.contains(uvOffset + 1) {
                    textureCoordinates.append(
                        CGPoint(
                            x: CGFloat(faceTextureCoordinates[uvOffset]),
                            // Metashape UVs use an origin opposite SceneKit's texture space.
                            y: 1 - CGFloat(faceTextureCoordinates[uvOffset + 1])
                        )
                    )
                } else {
                    textureCoordinates.append(.zero)
                }
                indices.append(UInt32(indices.count))
            }
        }

        let sources = [
            SCNGeometrySource(vertices: renderVertices),
            SCNGeometrySource(normals: renderNormals),
            SCNGeometrySource(textureCoordinates: textureCoordinates)
        ]
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        // The Metashape export's normal direction is not guaranteed. Keep the
        // survey texture legible regardless of winding; the Wireframe control
        // still offers a geometry-first inspection mode.
        material.lightingModel = .constant
        let fallbackTextureURL = url.deletingPathExtension().appendingPathExtension("jpg")
        let texture = textureURL.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(contentsOf: fallbackTextureURL)
        material.diffuse.contents = texture ?? NSColor.white
        material.isDoubleSided = true
        geometry.materials = [material]

        let baseNode = SCNNode(geometry: geometry)

        // Normalise on a parent so overlays inherit the same fit.
        let root = SCNNode()
        root.addChildNode(baseNode)
        let (minimum, maximum) = baseNode.boundingBox
        let center = SCNVector3((minimum.x + maximum.x) / 2, (minimum.y + maximum.y) / 2, (minimum.z + maximum.z) / 2)
        let largest = max(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z)
        let scale = largest > 0 ? 1 / largest : 1
        root.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        root.scale = SCNVector3(scale, scale, scale)

        var labelCounts = [String: Int]()
        var healthyNode: SCNNode?
        var unhealthyNode: SCNNode?
        if let labels {
            labelCounts = [
                "healthy": labels.lazy.filter { $0 == 1 }.count,
                "unhealthy": labels.lazy.filter { $0 == 2 }.count,
            ]
            let offset = CGFloat(largest) * 0.0015
            healthyNode = overlayNode(
                classID: 1,
                color: NSColor(red: 0, green: 0.78, blue: 0, alpha: 0.92),
                labels: labels,
                cornerSources: cornerSources,
                positions: renderVertices,
                normals: renderNormals,
                offset: offset
            )
            unhealthyNode = overlayNode(
                classID: 2,
                color: NSColor(red: 0.86, green: 0.12, blue: 0.12, alpha: 0.92),
                labels: labels,
                cornerSources: cornerSources,
                positions: renderVertices,
                normals: renderNormals,
                offset: offset
            )
            if let healthyNode { root.addChildNode(healthyNode) }
            if let unhealthyNode { root.addChildNode(unhealthyNode) }
        }

        let depthProxy = SCNNode(geometry: geometry)
        let proxyParent = SCNNode()
        proxyParent.addChildNode(depthProxy)
        proxyParent.pivot = root.pivot
        proxyParent.scale = root.scale

        return LoadedMesh(
            rootNode: root,
            baseNode: baseNode,
            healthyNode: healthyNode,
            unhealthyNode: unhealthyNode,
            depthProxyNode: proxyParentGeometryNode(proxyParent),
            texture: texture,
            vertexCount: vertexCount,
            faceCount: faceCount,
            labelCounts: labelCounts
        )
    }

    /// The depth renderer expects a single node whose `geometry` is set and
    /// whose scale/pivot normalise the mesh; collapse the proxy hierarchy.
    private static func proxyParentGeometryNode(_ parent: SCNNode) -> SCNNode {
        guard let child = parent.childNodes.first, let geometry = child.geometry else { return parent }
        let node = SCNNode(geometry: geometry)
        node.pivot = parent.pivot
        node.scale = parent.scale
        return node
    }

    /// Builds a highlight mesh for one semantic class: all triangles whose
    /// corner majority carries the class, pushed slightly along the vertex
    /// normals so the highlight renders above the textured surface.
    private static func overlayNode(
        classID: UInt8,
        color: NSColor,
        labels: [UInt8],
        cornerSources: [Int],
        positions: [SCNVector3],
        normals: [SCNVector3],
        offset: CGFloat
    ) -> SCNNode? {
        var overlayVertices = [SCNVector3]()
        var overlayIndices = [UInt32]()

        let triangleCount = cornerSources.count / 3
        for triangle in 0 ..< triangleCount {
            let base = triangle * 3
            var matches = 0
            for corner in 0 ..< 3 where labels[cornerSources[base + corner]] == classID {
                matches += 1
            }
            guard matches >= 2 else { continue }
            for corner in 0 ..< 3 {
                let index = base + corner
                let position = positions[index]
                let normal = normals[index]
                overlayVertices.append(
                    SCNVector3(
                        position.x + normal.x * offset,
                        position.y + normal.y * offset,
                        position.z + normal.z * offset
                    )
                )
                overlayIndices.append(UInt32(overlayVertices.count - 1))
            }
        }
        guard !overlayVertices.isEmpty else { return nil }

        let indexData = overlayIndices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: overlayIndices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: overlayVertices)],
            elements: [element]
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        material.transparency = 1
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.isHidden = true
        node.renderingOrder = 10
        return node
    }

    /// Byte layout of the vertex element parsed from the PLY header.
    private struct VertexLayout {
        let stride: Int
        let positionOffset: Int
        let normalOffset: Int?
        let faceHasTextureCoordinates: Bool

        init(header: String) throws {
            let sizes: [String: Int] = [
                "char": 1, "uchar": 1, "int8": 1, "uint8": 1,
                "short": 2, "ushort": 2, "int16": 2, "uint16": 2,
                "int": 4, "uint": 4, "int32": 4, "uint32": 4, "float": 4, "float32": 4,
                "double": 8, "float64": 8,
            ]
            var inVertex = false
            var inFace = false
            var offset = 0
            var position: Int?
            var normal: Int?
            var faceTexture = false
            for line in header.split(separator: "\n") {
                let parts = line.split(separator: " ").map(String.init)
                guard !parts.isEmpty else { continue }
                if parts[0] == "element" {
                    inVertex = parts.count > 1 && parts[1] == "vertex"
                    inFace = parts.count > 1 && parts[1] == "face"
                } else if parts[0] == "property", inVertex, parts.count >= 3 {
                    guard parts[1] != "list", let size = sizes[parts[1]] else {
                        throw PLYError.unsupportedFormat
                    }
                    if parts[2] == "x" { position = offset }
                    if parts[2] == "nx" { normal = offset }
                    offset += size
                } else if parts[0] == "property", inFace, parts.count >= 5, parts[1] == "list" {
                    if parts[4] == "texcoord" { faceTexture = true }
                }
            }
            guard let position else { throw PLYError.invalidHeader }
            stride = offset
            positionOffset = position
            normalOffset = normal
            faceHasTextureCoordinates = faceTexture
        }
    }

    private static func value(named element: String, in header: String) -> Int {
        header
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("element \(element) ") })
            .flatMap { Int($0.split(separator: " ").last ?? "") } ?? 0
    }

    enum PLYError: LocalizedError {
        case invalidHeader
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .invalidHeader: "The exported PLY header is incomplete."
            case .unsupportedFormat: "Only binary little-endian Metashape PLY files are supported."
            }
        }
    }
}

private struct BinaryReader {
    let data: Data
    var offset: Int

    mutating func uint8() -> UInt8 {
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint32() -> UInt32 {
        let value = data.withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += MemoryLayout<UInt32>.size
        return UInt32(littleEndian: value)
    }

    mutating func float32() -> Float {
        Float(bitPattern: uint32())
    }

    func float32(at absoluteOffset: Int) -> Float {
        let value = data.withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: absoluteOffset, as: UInt32.self)
        }
        return Float(bitPattern: UInt32(littleEndian: value))
    }

    mutating func skip(_ count: Int) {
        offset += count
    }
}
