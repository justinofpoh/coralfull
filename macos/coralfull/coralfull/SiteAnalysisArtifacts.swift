//
//  SiteAnalysisArtifacts.swift
//  coralfull
//
//  Loads a site's analysis package: the synchronized frame sequence
//  (RGB / semantic / dense depth per camera), the textured Metashape mesh,
//  and the 3D per-vertex health labels. The manifest format is documented in
//  tools/process_site.py.
//
//  Two kinds of sites use this loader:
//   - Bundled Livingseas references (Main Reef Structure / Site B), seeded
//     from app resources into Application Support on first launch.
//   - Uploaded sites, whose packages are produced by tools/process_site.py
//     inside their site directory.
//

import AppKit
import Combine
import Foundation
import ImageIO

// MARK: - Manifest model

/// One synchronized capture: the RGB survey frame, its CoralScapes semantic
/// segmentation, and the Metashape dense depth map for the same camera.
struct AnalysisFrame: Identifiable, Equatable, Decodable {
    let label: String
    let cameraId: Int
    let capturedAt: String?
    let rgb: String
    let semantic: String
    let depth: String
    let healthyPercent: Double
    let unhealthyPercent: Double
    let depthValidPercent: Double
    let depthRelativeMin: Double
    let depthRelativeMax: Double

    var id: String { label }

    /// Short frame number, e.g. "0144" for TIMELAPSE_0144.
    var shortNumber: String {
        label.split(separator: "_").last.map(String.init) ?? label
    }

    var capturedDate: Date? {
        capturedAt.flatMap(Self.captureParser.date(from:))
    }

    private static let captureParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}

struct AnalysisSequence: Decodable, Equatable {
    struct Scale: Decodable, Equatable {
        let calibrated: Bool
        let note: String
    }

    struct Mesh: Decodable, Equatable {
        let ply: String?
        let texture: String?
        let vertexLabels: String?
        let vertices: Int?
        let faces: Int?
        let textureSize: Int?
    }

    struct Metashape: Decodable, Equatable {
        let version: String?
        let createdAt: String?
        let finishedAt: String?
        let photoCount: Int?
        let alignedCameras: Int?
        let imageResolution: [Int]?
        let project: String?
    }

    struct Labels3D: Decodable, Equatable {
        let counts: [String: Int]
        let minVotes: Int?
        let labeledVertexPercent: Double?
    }

    let site: String
    let generatedAt: String?
    let semanticModel: String
    let depthProducer: String
    let scale: Scale
    let frames: [AnalysisFrame]
    let mesh: Mesh?
    let metashape: Metashape?
    let labels3d: Labels3D?
}

// MARK: - Analysis source

/// Where a site's analysis package lives and how its mesh assets resolve.
struct SiteAnalysisSource: Equatable {
    struct BundledMesh: Equatable {
        let plyName: String
        let textureName: String?
        let labelsName: String?
    }

    let siteName: String
    let directory: URL
    let manifestFilename: String
    /// Site B ships inside the app bundle and is seeded on first launch.
    let seedsSiteBFromBundle: Bool
    /// Fixed shared reference models ship with the app and are read directly
    /// from its signed bundle. They are identical for every App Store install.
    let bundledMesh: BundledMesh?

    /// The bundled demo/reference site.
    static let siteB = SiteAnalysisSource(
        siteName: "Site B",
        directory: {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            return applicationSupport
                .appendingPathComponent("coralfull", isDirectory: true)
                .appendingPathComponent("SiteB", isDirectory: true)
                .appendingPathComponent("live-analysis", isDirectory: true)
        }(),
        manifestFilename: "site_b_sequence.json",
        seedsSiteBFromBundle: true,
        bundledMesh: BundledMesh(
            plyName: "site_b_metashape_mesh",
            textureName: "site_b_metashape_mesh",
            labelsName: "site_b_semantic_vertex_labels"
        )
    )

    /// An uploaded site processed by tools/process_site.py.
    static func uploaded(siteID: String, name: String) -> SiteAnalysisSource {
        SiteAnalysisSource(
            siteName: name,
            directory: SiteStore.directory(for: siteID)
                .appendingPathComponent("analysis", isDirectory: true),
            manifestFilename: "site_sequence.json",
            seedsSiteBFromBundle: false,
            bundledMesh: nil
        )
    }

    static func sharedReference(for siteID: String) -> SiteAnalysisSource? {
        switch siteID {
        case "site-a", "site-b":
            // Bundled Livingseas reference: textured Metashape mesh, capture
            // timeline, and 3D health labels. site-a previously used the
            // retired Gaussian-splat viewer.
            siteB
        default:
            nil
        }
    }

    var manifestURL: URL { directory.appendingPathComponent(manifestFilename) }

    func resolve(_ relativePath: String) -> URL {
        URL(fileURLWithPath: relativePath, relativeTo: directory).standardizedFileURL
    }

    /// Mesh assets: prefer manifest-declared paths, fall back to the bundled
    /// Site B assets for the reference site.
    func meshAssets(from sequence: AnalysisSequence?) -> (ply: URL, texture: URL?, labels: URL?)? {
        if let mesh = sequence?.mesh, let ply = mesh.ply {
            let plyURL = resolve(ply)
            guard FileManager.default.fileExists(atPath: plyURL.path) else { return nil }
            return (
                plyURL,
                mesh.texture.map(resolve),
                mesh.vertexLabels.map(resolve)
            )
        }
        guard let bundledMesh,
              let ply = Self.bundledReefViewerURL(bundledMesh.plyName, "ply") else { return nil }
        return (
            ply,
            bundledMesh.textureName.flatMap { Self.bundledReefViewerURL($0, "jpg") },
            bundledMesh.labelsName.flatMap { Self.bundledReefViewerURL($0, "bin") }
        )
    }

    static func bundledReefViewerURL(_ name: String, _ fileExtension: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "ReefViewer")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }

}

// MARK: - Artifact store

/// The synchronized frame sequence for one site. Reads the completed
/// sequence when the screen is opened and quietly polls the manifest while
/// the screen is visible, so freshly generated frame sets appear without
/// rebuilding or relaunching the app.
@MainActor
final class SiteAnalysisArtifacts: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(AnalysisSequence)
        case unavailable(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var inputImage: NSImage?
    @Published private(set) var semanticImage: NSImage?
    @Published private(set) var depthImage: NSImage?
    @Published private(set) var isFrameLoading = false
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var lastUpdated: Date?

    let source: SiteAnalysisSource

    private var pollTimer: Timer?
    private var observedSignature = ""
    private var frameLoadTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var imageCache = [String: NSImage]()

    var sequence: AnalysisSequence? {
        if case .ready(let sequence) = state { return sequence }
        return nil
    }

    var frames: [AnalysisFrame] { sequence?.frames ?? [] }

    var selectedFrame: AnalysisFrame? {
        guard frames.indices.contains(selectedIndex) else { return nil }
        return frames[selectedIndex]
    }

    var meshAssets: (ply: URL, texture: URL?, labels: URL?)? {
        source.meshAssets(from: sequence)
    }

    init(source: SiteAnalysisSource) {
        self.source = source
        if source.seedsSiteBFromBundle {
            seedSiteBIfNeeded()
        }
        refresh()
    }

    // MARK: Polling

    /// Starts watching the manifest for externally produced frame sets.
    /// Called from the view's onAppear; stopped on disappear.
    func startWatching() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Frame selection

    func select(index: Int) {
        let clamped = max(0, min(index, frames.count - 1))
        guard clamped != selectedIndex || inputImage == nil else {
            selectedIndex = clamped
            return
        }
        selectedIndex = clamped
        loadSelectedFrameImages()
    }

    func selectNext() { select(index: selectedIndex + 1) }
    func selectPrevious() { select(index: selectedIndex - 1) }

    // MARK: Refresh

    func refresh() {
        let manifestURL = source.manifestURL
        guard let signature = signature(for: manifestURL) else {
            if sequence == nil {
                state = .unavailable(
                    "No analysis package found for \(source.siteName). "
                    + "Expected manifest: \(source.manifestFilename)."
                )
            }
            return
        }
        guard signature != observedSignature else { return }
        observedSignature = signature

        do {
            let data = try Data(contentsOf: manifestURL)
            let decoded = try JSONDecoder().decode(AnalysisSequence.self, from: data)
            guard !decoded.frames.isEmpty else {
                state = .unavailable("The analysis manifest contains no completed frames yet.")
                return
            }

            let previousLabel = selectedFrame?.label
            let hadSequence = sequence != nil
            state = .ready(decoded)
            lastUpdated = modificationDate(for: manifestURL)

            // Files may have been rewritten in place; drop stale decodes.
            imageCache.removeAll()

            if let previousLabel,
               let restored = decoded.frames.firstIndex(where: { $0.label == previousLabel }) {
                selectedIndex = restored
            } else if !hadSequence {
                selectedIndex = 0
            } else {
                selectedIndex = min(selectedIndex, decoded.frames.count - 1)
            }

            loadSelectedFrameImages()
            loadThumbnails(for: decoded.frames)
        } catch {
            if sequence == nil {
                state = .unavailable("Could not read the analysis manifest: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Image loading

    private func loadSelectedFrameImages() {
        guard let frame = selectedFrame else { return }

        let targets = [frame.rgb, frame.semantic, frame.depth]
        let cached = targets.map { imageCache[$0] }
        if cached.allSatisfy({ $0 != nil }) {
            (inputImage, semanticImage, depthImage) = (cached[0], cached[1], cached[2])
            isFrameLoading = false
            prefetchNeighbours()
            return
        }

        isFrameLoading = true
        frameLoadTask?.cancel()
        let directory = source.directory
        frameLoadTask = Task { [weak self] in
            let images = await Task.detached(priority: .userInitiated) {
                targets.map { Self.decodeImage(at: directory.appendingPathComponent($0)) }
            }.value

            guard let self, !Task.isCancelled else { return }
            for (path, image) in zip(targets, images) {
                if let image { self.imageCache[path] = image }
            }
            guard self.selectedFrame?.label == frame.label else { return }
            self.inputImage = images[0]
            self.semanticImage = images[1]
            self.depthImage = images[2]
            self.isFrameLoading = false
            self.prefetchNeighbours()
        }
    }

    private func prefetchNeighbours() {
        let neighbours = [selectedIndex - 1, selectedIndex + 1].filter(frames.indices.contains)
        let paths = neighbours
            .flatMap { [frames[$0].rgb, frames[$0].semantic, frames[$0].depth] }
            .filter { imageCache[$0] == nil }
        guard !paths.isEmpty else { return }

        let directory = source.directory
        Task { [weak self] in
            let images = await Task.detached(priority: .utility) {
                paths.map { Self.decodeImage(at: directory.appendingPathComponent($0)) }
            }.value
            guard let self else { return }
            for (path, image) in zip(paths, images) where image != nil {
                self.imageCache[path] = image
            }
        }
    }

    private func loadThumbnails(for frames: [AnalysisFrame]) {
        let missing = frames.filter { thumbnails[$0.label] == nil }
        guard !missing.isEmpty else { return }

        thumbnailTask?.cancel()
        let directory = source.directory
        thumbnailTask = Task { [weak self] in
            for frame in missing {
                if Task.isCancelled { return }
                let url = directory.appendingPathComponent(frame.rgb)
                let thumbnail = await Task.detached(priority: .utility) {
                    Self.decodeImage(at: url, maxPixelSize: 220)
                }.value
                guard let self, let thumbnail, !Task.isCancelled else { continue }
                self.thumbnails[frame.label] = thumbnail
            }
        }
    }

    nonisolated private static func decodeImage(at url: URL, maxPixelSize: Int? = nil) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        let cgImage: CGImage?
        if let maxPixelSize {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: Signatures

    private func signature(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate else { return nil }
        return "\(url.lastPathComponent):\(date.timeIntervalSinceReferenceDate):\(values.fileSize ?? 0)"
    }

    private func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Site B seeding

    /// Copies the bundled Site B artifact set into Application Support on
    /// first launch so the reference sequence is available for inspection.
    private func seedSiteBIfNeeded() {
        let manager = FileManager.default
        let manifestDestination = source.manifestURL
        guard !manager.fileExists(atPath: manifestDestination.path) else { return }

        guard let manifestSource = Self.bundleURL(forRelativePath: source.manifestFilename),
              let data = try? Data(contentsOf: manifestSource),
              let decoded = try? JSONDecoder().decode(AnalysisSequence.self, from: data) else { return }

        for frame in decoded.frames {
            for relative in [frame.rgb, frame.semantic, frame.depth] {
                let destination = source.directory.appendingPathComponent(relative)
                guard !manager.fileExists(atPath: destination.path),
                      let bundled = Self.bundleURL(forRelativePath: relative) else { continue }
                try? manager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? manager.copyItem(at: bundled, to: destination)
            }
        }
        try? manager.createDirectory(
            at: manifestDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? manager.copyItem(at: manifestSource, to: manifestDestination)
    }

    /// Resolves a manifest-relative path inside the app bundle, tolerating both
    /// preserved folder structure and flattened resource layouts.
    private static func bundleURL(forRelativePath relativePath: String) -> URL? {
        let filename = (relativePath as NSString).lastPathComponent
        let name = (filename as NSString).deletingPathExtension
        let fileExtension = (filename as NSString).pathExtension
        let parent = (relativePath as NSString).deletingLastPathComponent

        var subdirectories = [String?]()
        if parent.isEmpty {
            subdirectories = ["ReefViewer", nil]
        } else {
            subdirectories = ["ReefViewer/\(parent)", parent, "ReefViewer", nil]
        }
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }
}
