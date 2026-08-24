//
//  SiteStore.swift
//  coralfull
//
//  Persistent model and processing coordinator for user-uploaded survey
//  sites. Each site owns a directory under Application Support:
//
//    coralfull/sites/<uuid>/
//      site.json      app-owned record (name, created date, state)
//      photos/        imported photos (copied at import time; the original
//                     selection is never referenced again)
//      project/       Agisoft Metashape project
//      mesh/          exported textured PLY + reconstruction metadata
//      analysis/      per-frame artifacts + site_sequence.json manifest
//      status.json    staged progress written by tools/process_site.py
//      cover.jpg      dashboard cover
//
//  Processing runs out-of-process: the store launches
//  tools/process_site.py (in the reef_segment Python environment), which in
//  turn drives Metashape Pro headlessly. The store polls status.json while
//  any site is processing and republishes the staged progress.
//

import AppKit
import Combine
import Foundation

// MARK: - Records

struct UploadedSite: Identifiable, Codable, Equatable {
    enum State: Codable, Equatable {
        case importing
        case processing
        case ready
        case failed(String)
        case cancelled
        case interrupted

        var isTerminal: Bool {
            switch self {
            case .ready, .failed, .cancelled, .interrupted: true
            case .importing, .processing: false
            }
        }
    }

    let id: String
    var name: String
    var createdAt: Date
    var state: State
    var photoCount: Int
    /// App-owned paths; never the user's original selection after import.
    var sourcePhotoDirectory: String?
    var metashapeProjectPath: String?
    var meshPlyPath: String?
    var meshTexturePath: String?
    var analysisManifestPath: String?
}

/// Mirror of the status.json contract documented in tools/process_site.py.
struct PipelineStatus: Codable, Equatable {
    struct Stage: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let state: String // pending | running | done | failed
        let detail: String?
        let percent: Double?
    }

    let state: String // running | ready | failed | cancelled
    let error: String?
    let updatedAt: String?
    let stages: [Stage]

    var runningStage: Stage? { stages.first { $0.state == "running" } }
    var completedStages: Int { stages.filter { $0.state == "done" }.count }
}

// MARK: - Pipeline environment

/// Locates the external tools the processing pipeline depends on and turns
/// missing pieces into actionable prerequisite messages.
struct PipelineEnvironment {
    static let toolsRootDefaultsKey = "CoralPipelineRoot"

    let repositoryRoot: URL
    var python: URL { repositoryRoot.appendingPathComponent("tools/reef_segment/.venv/bin/python") }
    var orchestrator: URL { repositoryRoot.appendingPathComponent("tools/process_site.py") }
    var metashape: URL { URL(fileURLWithPath: "/Applications/MetashapePro.app") }

    static func detect() -> PipelineEnvironment {
        var candidates = [URL]()
        if let configured = UserDefaults.standard.string(forKey: toolsRootDefaultsKey) {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let env = ProcessInfo.processInfo.environment["CORALFULL_ROOT"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Desktop/coralfull"))
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0 ..< 8 {
            candidates.append(directory)
            directory.deleteLastPathComponent()
        }
        for root in candidates {
            let orchestrator = root.appendingPathComponent("tools/process_site.py")
            if FileManager.default.fileExists(atPath: orchestrator.path) {
                return PipelineEnvironment(repositoryRoot: root)
            }
        }
        return PipelineEnvironment(
            repositoryRoot: home.appendingPathComponent("Desktop/coralfull")
        )
    }

    /// Human-readable prerequisite problems; empty when processing can run.
    func issues() -> [String] {
        var issues = [String]()
        let manager = FileManager.default
        if !manager.fileExists(atPath: orchestrator.path) {
            issues.append(
                "Processing tools not found at \(repositoryRoot.path). "
                + "Set the coralfull repository path in the defaults key "
                + "\"\(Self.toolsRootDefaultsKey)\"."
            )
        } else if !manager.isExecutableFile(atPath: python.path) {
            issues.append(
                "The analysis Python environment is missing "
                + "(\(python.path)). Create the venv described in tools/reef_segment/requirements.txt."
            )
        }
        if !manager.fileExists(atPath: metashape.path) {
            issues.append(
                "Agisoft Metashape Pro is not installed at /Applications/MetashapePro.app. "
                + "Reconstruction requires an activated Metashape Pro."
            )
        }
        return issues
    }
}

// MARK: - Store

@MainActor
final class SiteStore: ObservableObject {
    @Published private(set) var sites: [UploadedSite] = []
    @Published private(set) var statuses: [String: PipelineStatus] = [:]
    @Published private(set) var covers: [String: NSImage] = [:]

    let environment = PipelineEnvironment.detect()

    private var processes: [String: Process] = [:]
    private var pollTimer: Timer?

    static let sitesRoot: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("coralfull", isDirectory: true)
            .appendingPathComponent("sites", isDirectory: true)
    }()

    static func directory(for siteID: String) -> URL {
        sitesRoot.appendingPathComponent(siteID, isDirectory: true)
    }

    init() {
        load()
    }

    // MARK: Loading & persistence

    func load() {
        let manager = FileManager.default
        var loaded = [UploadedSite]()
        let directories = (try? manager.contentsOfDirectory(
            at: Self.sitesRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        for directory in directories {
            let recordURL = directory.appendingPathComponent("site.json")
            guard let data = try? Data(contentsOf: recordURL),
                  var site = try? Self.makeDecoder().decode(UploadedSite.self, from: data) else { continue }

            // Reconcile state after a relaunch: processing cannot survive the
            // app closing, but the pipeline may have finished before it did.
            if !site.state.isTerminal {
                let status = readStatus(for: site.id)
                switch status?.state {
                case "ready":
                    site.state = .ready
                case "failed":
                    site.state = .failed(status?.error ?? "Processing failed.")
                case "cancelled":
                    site.state = .cancelled
                default:
                    site.state = .interrupted
                }
                persist(site)
            }
            if let status = readStatus(for: site.id) {
                statuses[site.id] = status
            }
            loaded.append(site)
        }
        sites = loaded.sorted { $0.createdAt > $1.createdAt }
        for site in sites { loadCover(for: site.id) }
    }

    private func persist(_ site: UploadedSite) {
        let directory = Self.directory(for: site.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Self.makeEncoder().encode(site) {
            try? data.write(to: directory.appendingPathComponent("site.json"), options: .atomic)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func update(_ site: UploadedSite) {
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            sites[index] = site
        } else {
            sites.insert(site, at: 0)
        }
        persist(site)
    }

    func site(id: String) -> UploadedSite? {
        sites.first { $0.id == id }
    }

    // MARK: Site creation

    /// Copies the selected photos into app-managed storage and starts
    /// processing. Copying runs off the main thread; the site appears
    /// immediately in `.importing` state.
    ///
    /// `scopedRoots` are the URLs the user picked in the open panel (folders
    /// and/or files). Their security-scoped access is held for the duration
    /// of the copy so child photo URLs remain readable.
    func createSite(named name: String, photoURLs: [URL], scopedRoots: [URL]) -> UploadedSite {
        let siteID = UUID().uuidString.lowercased()
        let photosDirectory = Self.directory(for: siteID).appendingPathComponent("photos", isDirectory: true)
        let site = UploadedSite(
            id: siteID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            state: .importing,
            photoCount: photoURLs.count,
            sourcePhotoDirectory: photosDirectory.path
        )
        update(site)

        Task.detached(priority: .userInitiated) {
            var failure: String?
            let roots = scopedRoots
            let tokens = roots.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer {
                for (url, accessing) in tokens where accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
                var usedNames = Set<String>()
                for source in photoURLs {
                    let accessing = source.startAccessingSecurityScopedResource()
                    defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                    let destination = Self.uniquePhotoDestination(
                        in: photosDirectory,
                        source: source,
                        usedNames: &usedNames
                    )
                    if manager.fileExists(atPath: destination.path) {
                        try manager.removeItem(at: destination)
                    }
                    try manager.copyItem(at: source, to: destination)
                }
            } catch {
                failure = "Could not copy photos into app storage: \(error.localizedDescription)"
            }
            await MainActor.run { [failure] in
                guard var refreshed = self.site(id: siteID) else { return }
                if let failure {
                    refreshed.state = .failed(failure)
                    self.update(refreshed)
                } else {
                    self.startProcessing(siteID: siteID)
                }
            }
        }
        return site
    }

    /// Chooses a collision-free filename inside the site photos folder.
    /// Same-named files from different parent folders (e.g. left/right stereo)
    /// keep both copies by prefixing the parent folder name.
    nonisolated private static func uniquePhotoDestination(
        in directory: URL,
        source: URL,
        usedNames: inout Set<String>
    ) -> URL {
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let parent = source.deletingLastPathComponent().lastPathComponent
        let preferred = ["\(stem).\(ext)", "\(parent)_\(stem).\(ext)"]
        for name in preferred where !usedNames.contains(name.lowercased()) {
            usedNames.insert(name.lowercased())
            return directory.appendingPathComponent(name)
        }
        var extra = 2
        while true {
            let name = "\(parent)_\(stem)_\(extra).\(ext)"
            extra += 1
            guard !usedNames.contains(name.lowercased()) else { continue }
            usedNames.insert(name.lowercased())
            return directory.appendingPathComponent(name)
        }
    }

    // MARK: Processing lifecycle

    func startProcessing(siteID: String) {
        guard var site = site(id: siteID), processes[siteID] == nil else { return }

        let issues = environment.issues()
        if !issues.isEmpty {
            site.state = .failed(issues.joined(separator: "\n"))
            update(site)
            return
        }

        let directory = Self.directory(for: siteID)
        // Remove a stale terminal status so the UI never flashes an old state.
        statuses[siteID] = nil

        let process = Process()
        process.executableURL = environment.python
        process.arguments = [
            environment.orchestrator.path,
            "--site-dir", directory.path,
            "--site-id", siteID,
            "--site-name", site.name,
        ]
        if ProcessInfo.processInfo.environment["CORAL_PIPELINE_FAST"] == "1"
            || UserDefaults.standard.bool(forKey: "CoralPipelineFast") {
            process.arguments? += [
                "--match-downscale", "4",
                "--depth-downscale", "8",
                "--texture-size", "2048",
            ]
        }
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["CORALFULL_ROOT"] = environment.repositoryRoot.path
        process.environment = env
        process.currentDirectoryURL = environment.repositoryRoot
        let logURL = directory.appendingPathComponent("pipeline.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.processDidTerminate(siteID: siteID, exitCode: finished.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            site.state = .failed("Could not launch the processing pipeline: \(error.localizedDescription)")
            update(site)
            return
        }

        processes[siteID] = process
        site.state = .processing
        update(site)
        startPollingIfNeeded()
    }

    func cancelProcessing(siteID: String) {
        guard let process = processes[siteID] else { return }
        process.terminate() // orchestrator traps SIGTERM, stops Metashape, marks cancelled
    }

    func retry(siteID: String) {
        guard var site = site(id: siteID) else { return }
        site.state = .processing
        update(site)
        startProcessing(siteID: siteID)
    }

    func rename(siteID: String, to name: String) {
        guard var site = site(id: siteID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        site.name = trimmed
        update(site)
    }

    func delete(siteID: String) {
        cancelProcessing(siteID: siteID)
        sites.removeAll { $0.id == siteID }
        statuses[siteID] = nil
        covers[siteID] = nil
        try? FileManager.default.removeItem(at: Self.directory(for: siteID))
    }

    private func processDidTerminate(siteID: String, exitCode: Int32) {
        processes[siteID] = nil
        refreshStatus(for: siteID)
        guard var site = site(id: siteID) else { return }
        switch statuses[siteID]?.state {
        case "ready":
            site.state = .ready
            let directory = Self.directory(for: siteID)
            site.metashapeProjectPath = directory.appendingPathComponent("project/site.psx").path
            site.meshPlyPath = directory.appendingPathComponent("mesh/mesh.ply").path
            site.meshTexturePath = directory.appendingPathComponent("mesh/mesh.jpg").path
            site.analysisManifestPath = directory.appendingPathComponent("analysis/site_sequence.json").path
            if let manifest = try? Data(
                contentsOf: directory.appendingPathComponent("analysis/site_sequence.json")
            ),
                let decoded = try? JSONDecoder().decode(AnalysisSequence.self, from: manifest) {
                site.photoCount = decoded.frames.count
            }
            loadCover(for: siteID)
        case "cancelled":
            site.state = .cancelled
        case "failed":
            site.state = .failed(statuses[siteID]?.error ?? "Processing failed.")
        default:
            site.state = .failed(
                "The processing pipeline exited unexpectedly (code \(exitCode)). "
                + "See pipeline.log in the site folder."
            )
        }
        update(site)
        stopPollingIfIdle()
    }

    // MARK: Status polling

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for siteID in self.processes.keys {
                    self.refreshStatus(for: siteID)
                }
                self.stopPollingIfIdle()
            }
        }
    }

    private func stopPollingIfIdle() {
        guard processes.isEmpty else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshStatus(for siteID: String) {
        if let status = readStatus(for: siteID), status != statuses[siteID] {
            statuses[siteID] = status
        }
    }

    private func readStatus(for siteID: String) -> PipelineStatus? {
        let url = Self.directory(for: siteID).appendingPathComponent("status.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PipelineStatus.self, from: data)
    }

    // MARK: Covers

    private func loadCover(for siteID: String) {
        guard covers[siteID] == nil else { return }
        let url = Self.directory(for: siteID).appendingPathComponent("cover.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Task.detached(priority: .utility) {
            guard let image = NSImage(contentsOf: url) else { return }
            await MainActor.run { self.covers[siteID] = image }
        }
    }
}
