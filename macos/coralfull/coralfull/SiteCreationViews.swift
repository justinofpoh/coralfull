//
//  SiteCreationViews.swift
//  coralfull
//
//  The "Create site from photos" flow: native file selection (folder or
//  multi-selected images), a setup/review screen with per-photo metadata and
//  validation, and an honest staged progress screen backed by the pipeline's
//  status.json (no synthetic percentages).
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import candidates

/// One photo considered for import, with the metadata shown on the review
/// screen. Metadata is read off the main thread via CGImageSource.
struct ImportCandidate: Identifiable, Equatable {
    let id: String
    let url: URL
    let fileName: String
    let fileSizeBytes: Int
    var pixelWidth: Int?
    var pixelHeight: Int?
    var capturedAt: Date?
    var cameraModel: String?
    var thumbnail: NSImage?

    var resolutionText: String {
        guard let pixelWidth, let pixelHeight else { return "—" }
        return "\(pixelWidth)×\(pixelHeight)"
    }
}

enum PhotoImportReader {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png"]

    /// Expands the user's selection (folders and/or image files) into a
    /// naturally sorted list of image URLs. Folder contents are walked two
    /// levels deep so stereo left/right layouts still import. Security-scope
    /// access is held on the original selection while enumerating.
    static func expandSelection(_ urls: [URL]) -> (images: [URL], skipped: Int) {
        var images = [URL]()
        var skipped = 0
        var seen = Set<String>()
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            collectImages(at: url, depth: 0, images: &images, skipped: &skipped, seen: &seen)
        }
        images.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return (images, skipped)
    }

    private static func collectImages(
        at url: URL,
        depth: Int,
        images: inout [URL],
        skipped: inout Int,
        seen: inout Set<String>
    ) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            guard depth < 3 else { return }
            let children = (try? manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                collectImages(at: child, depth: depth + 1, images: &images, skipped: &skipped, seen: &seen)
            }
            return
        }
        if supportedExtensions.contains(url.pathExtension.lowercased()) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                images.append(url)
            }
        } else {
            skipped += 1
        }
    }

    /// Reads dimensions, EXIF capture date, camera model, and a small
    /// thumbnail for one image.
    static func readCandidate(url: URL) -> ImportCandidate {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var candidate = ImportCandidate(
            id: url.path,
            url: url,
            fileName: url.lastPathComponent,
            fileSizeBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return candidate }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            candidate.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
            candidate.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                candidate.capturedAt = Self.exifParser.date(from: raw)
            }
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                candidate.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            }
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            candidate.thumbnail = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
        return candidate
    }

    private static let exifParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

// MARK: - Flow container

/// Drives the create-site flow as a sheet: reading selection metadata,
/// the setup/review screen, then the staged processing screen.
struct SiteCreationSheet: View {
    enum Phase {
        case reading
        case setup
        case processing(siteID: String)
    }

    let selection: [URL]
    @ObservedObject var store: SiteStore
    let onOpenAnalysis: (String) -> Void
    let onDismiss: () -> Void

    @State private var phase: Phase = .reading
    @State private var candidates: [ImportCandidate] = []
    @State private var skippedCount = 0
    @State private var siteName = ""
    @State private var creationError: String?
    @State private var isCreating = false

    var body: some View {
        Group {
            switch phase {
            case .reading:
                readingView
            case .setup:
                SiteSetupView(
                    siteName: $siteName,
                    candidates: $candidates,
                    skippedCount: skippedCount,
                    prerequisiteIssues: store.environment.issues(),
                    creationError: creationError,
                    isCreating: isCreating,
                    onCancel: onDismiss,
                    onStart: startProcessing
                )
            case .processing(let siteID):
                SiteProcessingView(
                    siteID: siteID,
                    store: store,
                    onOpenAnalysis: { onOpenAnalysis(siteID) },
                    onDismiss: onDismiss
                )
            }
        }
        .frame(width: 640, height: 620)
        .task { await readSelection() }
    }

    private var readingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Reading photo metadata…")
                .font(.headline)
            Text("Checking resolution, capture times, and camera details.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readSelection() async {
        let selection = selection
        let result = await Task.detached(priority: .userInitiated) { () -> ([ImportCandidate], Int) in
            let (images, skipped) = PhotoImportReader.expandSelection(selection)
            let candidates = images.map { PhotoImportReader.readCandidate(url: $0) }
            return (candidates, skipped)
        }.value
        candidates = result.0
        skippedCount = result.1
        if siteName.isEmpty {
            siteName = suggestedName()
        }
        phase = .setup
    }

    private func suggestedName() -> String {
        if selection.count == 1, selection[0].hasDirectoryPath {
            return selection[0].lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
        return "New Survey Site"
    }

    private func startProcessing() {
        guard !isCreating else { return }
        isCreating = true
        creationError = nil
        Task {
            defer { isCreating = false }
            do {
                let site = try await store.createSite(
                    named: siteName,
                    photoURLs: candidates.map(\.url),
                    scopedRoots: selection
                )
                phase = .processing(siteID: site.id)
            } catch {
                creationError = (error as? CoralfullAPIError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Setup / review screen

struct SiteSetupView: View {
    @Binding var siteName: String
    @Binding var candidates: [ImportCandidate]
    let skippedCount: Int
    let prerequisiteIssues: [String]
    /// Set when creating the backend record failed -- usually because the
    /// backend is not running.
    let creationError: String?
    let isCreating: Bool
    let onCancel: () -> Void
    let onStart: () -> Void

    private let gridColumns = [GridItem(.adaptive(minimum: 108), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create site from photos")
                    .font(.title2.weight(.semibold))
                Text("Photos are copied into app-managed storage; the original folder is not needed afterwards.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Site name")
                            .font(.headline)
                        TextField("e.g. North Bommie transect", text: $siteName)
                            .textFieldStyle(.roundedBorder)
                    }

                    summarySection

                    if !validationMessages.isEmpty || skippedCount > 0 {
                        validationSection
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Photos (\(candidates.count))")
                            .font(.headline)
                        Text("Remove blurred or off-transect photos before processing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: gridColumns, spacing: 10) {
                            ForEach(candidates) { candidate in
                                photoCell(candidate)
                            }
                        }
                    }
                }
                .padding(20)
            }

            if let creationError {
                Label(creationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 6)
                }

                Button("Start processing", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart || isCreating)
                    .help(
                        canStart
                            ? "Copy photos and start the reconstruction pipeline"
                            : (blockingMessage ?? "")
                    )
            }
            .padding(16)
        }
    }

    // MARK: Summary

    private var summarySection: some View {
        HStack(spacing: 10) {
            summaryTile(title: "Photos", value: "\(candidates.count)")
            summaryTile(title: "Resolution", value: dominantResolution ?? "—")
            summaryTile(title: "Capture range", value: captureRange ?? "No EXIF times")
            summaryTile(title: "Camera", value: cameraSummary ?? "Unknown")
        }
    }

    private func summaryTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var dominantResolution: String? {
        let resolutions = candidates.compactMap { candidate -> String? in
            guard candidate.pixelWidth != nil else { return nil }
            return candidate.resolutionText
        }
        guard !resolutions.isEmpty else { return nil }
        let counts = Dictionary(grouping: resolutions, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    private var captureRange: String? {
        let dates = candidates.compactMap(\.capturedAt).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return "\(first.formatted(date: .abbreviated, time: .shortened)) – \(last.formatted(date: .omitted, time: .shortened))"
        }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    private var cameraSummary: String? {
        let models = Set(candidates.compactMap(\.cameraModel))
        guard !models.isEmpty else { return nil }
        return models.count == 1 ? models.first : "\(models.count) camera models"
    }

    // MARK: Validation

    private var validationMessages: [(String, Bool)] {
        var messages = [(String, Bool)]() // (text, isBlocking)
        if candidates.count < 3 {
            messages.append((
                "At least 3 overlapping photos are required for reconstruction; \(candidates.count) selected.",
                true
            ))
        }
        if let dominant = dominantResolution {
            let odd = candidates.filter { $0.pixelWidth != nil && $0.resolutionText != dominant }.count
            if odd > 0 {
                messages.append((
                    "\(odd) photo\(odd == 1 ? "" : "s") differ from the dominant resolution (\(dominant)). Mixed sizes can weaken alignment.",
                    false
                ))
            }
        }
        let unreadable = candidates.filter { $0.pixelWidth == nil }.count
        if unreadable > 0 {
            messages.append((
                "\(unreadable) photo\(unreadable == 1 ? "" : "s") could not be read and will likely fail processing. Consider removing them.",
                false
            ))
        }
        if siteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(("Enter a site name.", true))
        }
        for issue in prerequisiteIssues {
            messages.append((issue, true))
        }
        return messages
    }

    private var canStart: Bool {
        !validationMessages.contains { $0.1 }
    }

    private var blockingMessage: String? {
        validationMessages.first { $0.1 }?.0
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if skippedCount > 0 {
                Label(
                    "\(skippedCount) unsupported file\(skippedCount == 1 ? "" : "s") were skipped (JPG, JPEG, and PNG are supported).",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(validationMessages, id: \.0) { message, blocking in
                Label(message, systemImage: blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(blocking ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Photo cell

    private func photoCell(_ candidate: ImportCandidate) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail = candidate.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.15)
                            Image(systemName: "questionmark.square.dashed")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 108, height: 64)
                .clipShape(.rect(cornerRadius: 7))

                Button {
                    candidates.removeAll { $0.id == candidate.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Remove \(candidate.fileName) from this import")
            }

            Text(candidate.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(candidate.resolutionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 108)
    }
}

// MARK: - Processing screen

struct SiteProcessingView: View {
    let siteID: String
    @ObservedObject var store: SiteStore
    let onOpenAnalysis: () -> Void
    let onDismiss: () -> Void

    private var site: UploadedSite? { store.site(id: siteID) }
    private var status: PipelineStatus? { store.statuses[siteID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(site?.name ?? "Processing site")
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let stages = status?.stages {
                        ForEach(stages) { stage in
                            stageRow(stage)
                        }
                    } else {
                        stageRow(PipelineStatus.Stage(
                            id: "import",
                            title: "Importing photos",
                            state: site?.state == .importing ? "running" : "pending",
                            detail: "Copying into app-managed storage",
                            percent: nil
                        ))
                    }

                    if case .failed(let message) = site?.state {
                        failureCard(message)
                            .padding(.top, 12)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                switch site?.state {
                case .importing, .processing:
                    Button("Cancel processing", role: .destructive) {
                        store.cancelProcessing(siteID: siteID)
                    }
                    Spacer()
                    Button("Continue in background", action: onDismiss)
                        .help("Processing keeps running; progress stays visible on the dashboard card")
                case .ready:
                    Button("Close", action: onDismiss)
                    Spacer()
                    Button("Open 3D analysis", action: onOpenAnalysis)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .failed, .cancelled, .interrupted:
                    Button("Delete site", role: .destructive) {
                        store.delete(siteID: siteID)
                        onDismiss()
                    }
                    Spacer()
                    Button("Close", action: onDismiss)
                    Button("Retry") {
                        store.retry(siteID: siteID)
                    }
                    .buttonStyle(.borderedProminent)
                case nil:
                    Button("Close", action: onDismiss)
                }
            }
            .padding(16)
        }
    }

    private var subtitle: String {
        switch site?.state {
        case .importing: "Copying photos into app storage…"
        case .processing: "Reconstruction and analysis are running. You can keep using the app."
        case .ready: "Ready for inspection."
        case .failed: "Processing failed."
        case .cancelled: "Processing was cancelled."
        case .interrupted: "Processing was interrupted by an app relaunch."
        case nil: ""
        }
    }

    private func stageRow(_ stage: PipelineStatus.Stage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            stageIcon(stage.state)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(stage.title)
                        .font(.body.weight(stage.state == "running" ? .semibold : .regular))
                    if let percent = stage.percent, stage.state == "running" {
                        Text("\(Int(percent))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = stage.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let percent = stage.percent, stage.state == "running" {
                    ProgressView(value: percent, total: 100)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(.vertical, 7)
        .opacity(stage.state == "pending" ? 0.45 : 1)
    }

    @ViewBuilder
    private func stageIcon(_ state: String) -> some View {
        switch state {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "running":
            ProgressView()
                .controlSize(.small)
        case "failed":
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Log: \(SiteStore.directory(for: siteID).appendingPathComponent("pipeline.log").path)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum SurveyPhotoPicker {
    /// Native open panel that accepts a folder or multiple JPG/PNG files.
    static func present(completion: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .jpeg, .png]
        panel.message = "Choose a survey folder or several photos. JPG, JPEG, and PNG are supported."
        panel.prompt = "Import"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        panel.begin { response in
            completion(response == .OK ? panel.urls : nil)
        }
    }
}
