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

nonisolated struct UploadedSite: Identifiable, Codable, Equatable, Sendable {
    enum State: Codable, Equatable, Sendable {
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
nonisolated struct PipelineStatus: Codable, Equatable, Sendable {
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

    /// The backend owns the site list. Processing stays local -- Metashape and
    /// CoralScapes run on this machine -- so `statuses` is still filled from
    /// status.json while a scan is being built.
    @Published private(set) var backendError: String?
    @Published private(set) var isRefreshing = false
    /// Per-site health from the mirrored manifest, so the dashboard shows
    /// measurements instead of placeholders.
    @Published private(set) var health: [String: SiteHealth] = [:]

    let api: CoralfullAPI
    private let mirror: SiteMirror
    private var remoteSites: [String: RemoteSite] = [:]

    private var processes: [String: Process] = [:]
    private var pollTimer: Timer?

    /// Temporary surveys that were previously presented as shared examples.
    /// They are not part of the release catalogue, so remove their old local
    /// records once when an existing installation next launches.
    private static let retiredSampleSiteIDs: Set<String> = [
        "e742739d-672f-4eb3-9283-cc3dbcc6b87d",
        "upload-test-20260823014036"
    ]

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

    init(api: CoralfullAPI? = nil) {
        // Built here rather than as a default argument: default arguments are
        // evaluated at the call site, outside this main-actor init.
        let api = api ?? CoralfullAPI()
        self.api = api
        self.mirror = SiteMirror(api: api)
        load()
        Task { await refreshFromBackend() }
    }

    // MARK: Backend

    /// Replaces the list with what the backend holds.
    ///
    /// Local records are still read by `load()` and still own pipeline state
    /// while a scan is being built on this machine; see `merge(remote:)`.
    func refreshFromBackend() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let remote = try await api.listSites()
            backendError = nil
            merge(remote: remote)
            log("listed \(remote.count) site(s) from \(api.baseURL.absoluteString)")
        } catch {
            let message = (error as? CoralfullAPIError)?.errorDescription
                ?? error.localizedDescription
            backendError = message
            log("refresh failed: \(message)")
        }
    }

    private func merge(remote: [RemoteSite]) {
        remoteSites = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })

        var merged = remote.map { entry -> UploadedSite in
            let local = sites.first { $0.id == entry.id }
            return UploadedSite(
                id: entry.id,
                name: entry.name,
                createdAt: entry.createdAt,
                state: resolvedState(remote: entry, local: local),
                photoCount: entry.photoCount,
                sourcePhotoDirectory: local?.sourcePhotoDirectory
            )
        }

        // A site whose creation reached this machine but not the backend would
        // otherwise vanish from the UI with its photos still on disk.
        let remoteIDs = Set(remote.map(\.id))
        merged.append(contentsOf: sites.filter { !remoteIDs.contains($0.id) })

        sites = merged.sorted { $0.createdAt > $1.createdAt }
        for site in sites { loadCover(for: site.id) }
    }

    /// While the pipeline is running here, this machine knows more than the
    /// backend does: the backend only learns the outcome when the site is
    /// published. A locally failed run also keeps its local message, which
    /// carries the actual error.
    private func resolvedState(remote: RemoteSite, local: UploadedSite?) -> UploadedSite.State {
        guard let local else { return remote.state }
        if processes[remote.id] != nil { return local.state }
        if case .failed = local.state, !remote.state.isTerminal { return local.state }
        return remote.state
    }

    func remoteSite(id: String) -> RemoteSite? { remoteSites[id] }

    /// Backend interactions are the one thing here that fails for reasons
    /// outside the app, so they are worth a line in the console.
    private func log(_ message: String) {
        #if DEBUG
        // stderr, not print: stdout is block-buffered when the app is not
        // attached to a terminal, which swallows these entirely.
        FileHandle.standardError.write(Data("[coralfull] \(message)\n".utf8))
        #endif
    }

    /// Downloads a published site's artifacts so the existing viewer -- which
    /// reads local files throughout -- can open it.
    func prepareForViewing(siteID: String) async throws {
        guard let remote = remoteSites[siteID] else { return }
        try await mirror.ensureMirrored(site: remote)
        loadHealth(for: siteID)
        loadCover(for: siteID)
        if let health = health[siteID] {
            log(String(
                format: "mirrored %@: %.1f%% healthy, %.1f%% unhealthy (%@)",
                remote.name, health.healthyPercent, health.unhealthyPercent,
                health.hasVertexLabels ? "mesh labels" : "frame mean"
            ))
        }
    }

    /// Reads labels3d counts out of the mirrored manifest.
    private func loadHealth(for siteID: String) {
        let manifestURL = Self.directory(for: siteID)
            .appendingPathComponent("analysis", isDirectory: true)
            .appendingPathComponent(SiteMirror.manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL),
              let sequence = try? JSONDecoder().decode(AnalysisSequence.self, from: data)
        else { return }
        health[siteID] = SiteHealth(sequence: sequence)
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

            guard !Self.retiredSampleSiteIDs.contains(site.id) else {
                try? manager.removeItem(at: directory)
                continue
            }

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
    func createSite(named name: String, photoURLs: [URL], scopedRoots: [URL]) async throws -> UploadedSite {
        // Create the backend record first and adopt its id. Doing it in this
        // order means a scan is visible on every client while it is still being
        // built, and never exists locally under an id the backend disagrees with.
        let remote = try await api.createSite(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            photoCount: photoURLs.count
        )
        remoteSites[remote.id] = remote
        let siteID = remote.id
        let photosDirectory = Self.directory(for: siteID).appendingPathComponent("photos", isDirectory: true)
        let site = UploadedSite(
            id: siteID,
            name: remote.name,
            createdAt: remote.createdAt,
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
        // The pipeline publishes to the backend when it finishes. Passing the
        // client's own resolved base URL means a CoralfullAPIBaseURL override
        // cannot leave the app and the pipeline talking to different servers.
        env["CORALFULL_API"] = api.baseURL.absoluteString
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

    /// Whether the pipeline can be re-run for this site on this machine.
    ///
    /// The site list is shared, so a scan may have been captured and processed
    /// on a different Mac. Its photos are not here, and re-running would launch
    /// the pipeline against an empty directory and fail in a confusing way.
    func canRetry(siteID: String) -> Bool {
        let photos = Self.directory(for: siteID).appendingPathComponent("photos", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: photos.path) else {
            return false
        }
        return !contents.isEmpty
    }

    func retry(siteID: String) {
        guard var site = site(id: siteID) else { return }
        guard canRetry(siteID: siteID) else {
            site.state = .failed(
                "This site's photos are not on this Mac, so processing cannot be re-run here. "
                + "Retry on the machine that captured it."
            )
            update(site)
            return
        }
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

        Task { [api] in
            do {
                let updated = try await api.patchSite(id: siteID, name: trimmed)
                remoteSites[siteID] = updated
            } catch {
                // The local rename stands; the next refresh will show the
                // backend's name again, which is the honest outcome.
                backendError = (error as? CoralfullAPIError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Removes a site from both halves of the system.
    ///
    /// The backend goes first: if that fails the local copy is left alone and
    /// the site stays listed, which is recoverable. The reverse order would
    /// delete the photos and leave an unopenable record behind.
    func delete(siteID: String) {
        cancelProcessing(siteID: siteID)
        let existedRemotely = remoteSites[siteID] != nil

        Task { [api] in
            if existedRemotely {
                do {
                    try await api.deleteSite(id: siteID)
                } catch let error as CoralfullAPIError where !error.isNotFound {
                    backendError = error.errorDescription
                    return
                } catch {
                    backendError = error.localizedDescription
                    return
                }
            }
            removeLocally(siteID: siteID)
        }
    }

    private func removeLocally(siteID: String) {
        sites.removeAll { $0.id == siteID }
        statuses[siteID] = nil
        covers[siteID] = nil
        health[siteID] = nil
        remoteSites[siteID] = nil
        mirror.forget(siteID: siteID)
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
