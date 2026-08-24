//
//  SiteMirror.swift
//  coralfull
//
//  Downloads a published site's manifest and artifacts into the same directory
//  layout the local pipeline produces.
//
//  This is deliberately a mirror rather than a rewrite of the viewer. The
//  analysis stack -- the hand-rolled binary PLY parser, CGImageSource decoding,
//  the mtime+size cache signature, the sibling-".jpg" texture fallback -- is all
//  built on local file URLs. Materialising the bytes where SiteAnalysisSource
//  .uploaded(siteID:) already looks means none of that has to change, and it
//  buys offline viewing for free.
//

import Foundation

@MainActor
final class SiteMirror {
    /// The manifest filename SiteAnalysisSource.uploaded expects. The backend
    /// stores whatever the publisher sent (site_b_sequence.json for the
    /// reference scan), so it is normalised on the way in.
    static let manifestFilename = "site_sequence.json"

    /// How many artifacts to fetch at once. A published site is ~134 files;
    /// serial would be slow, unbounded would open 134 sockets at once.
    private static let concurrency = 6

    private let api: CoralfullAPI
    /// Sites already mirrored this launch, so revisiting one is free.
    private var completed: Set<String> = []
    private var inFlight: [String: Task<Void, Error>] = [:]

    init(api: CoralfullAPI) {
        self.api = api
    }

    struct Progress: Equatable {
        var completedFiles: Int
        var totalFiles: Int
        var bytes: Int64

        var fraction: Double {
            totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 1
        }
    }

    func forget(siteID: String) {
        completed.remove(siteID)
        inFlight[siteID]?.cancel()
        inFlight[siteID] = nil
    }

    /// Ensures every artifact the site's manifest references is on disk.
    ///
    /// Idempotent and resumable: a file already present with the expected size
    /// is skipped, so an interrupted mirror is repaired by calling again.
    /// Concurrent calls for the same site share one task.
    func ensureMirrored(
        site: RemoteSite,
        onProgress: (@MainActor (Progress) -> Void)? = nil
    ) async throws {
        guard site.hasAnalysis else { return }
        if completed.contains(site.id) { return }
        if let existing = inFlight[site.id] {
            return try await existing.value
        }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.mirror(site: site, onProgress: onProgress)
        }
        inFlight[site.id] = task
        defer { inFlight[site.id] = nil }

        try await task.value
        completed.insert(site.id)
    }

    private func mirror(
        site: RemoteSite,
        onProgress: (@MainActor (Progress) -> Void)?
    ) async throws {
        let analysisDirectory = SiteStore.directory(for: site.id)
            .appendingPathComponent("analysis", isDirectory: true)
        try FileManager.default.createDirectory(
            at: analysisDirectory, withIntermediateDirectories: true
        )

        let manifestData = try await api.analysisData(siteID: site.id)
        let sequence = try JSONDecoder().decode(AnalysisSequence.self, from: manifestData)

        var wanted = Self.referencedPaths(in: sequence)
        // The cover lives beside the site directory, not under analysis/, so it
        // is fetched separately below.
        wanted.sort()

        var progress = Progress(completedFiles: 0, totalFiles: wanted.count, bytes: 0)
        onProgress?(progress)

        try await withThrowingTaskGroup(of: Int64.self) { group in
            var iterator = wanted.makeIterator()
            var running = 0

            func enqueueNext() -> Bool {
                guard let relative = iterator.next() else { return false }
                let destination = analysisDirectory.appendingPathComponent(relative)
                let api = self.api
                let siteID = site.id
                group.addTask {
                    try await Self.download(
                        api: api, siteID: siteID,
                        relativePath: relative, destination: destination
                    )
                }
                return true
            }

            while running < Self.concurrency, enqueueNext() { running += 1 }

            while running > 0 {
                let bytes = try await group.next() ?? 0
                running -= 1
                progress.completedFiles += 1
                progress.bytes += bytes
                onProgress?(progress)
                if enqueueNext() { running += 1 }
            }
        }

        // The manifest is written last and only when it changed. Last, because
        // it is the sentinel SiteAnalysisArtifacts stats -- a crash mid-mirror
        // then re-runs instead of showing a manifest whose frames are missing.
        // Only when changed, because SiteAnalysisArtifacts.refresh() keys its
        // cache on mtime+size and would drop every decoded image otherwise.
        let manifestURL = analysisDirectory.appendingPathComponent(Self.manifestFilename)
        let existing = try? Data(contentsOf: manifestURL)
        if existing != manifestData {
            try manifestData.write(to: manifestURL, options: .atomic)
        }

        try? await mirrorCover(site: site)
    }

    /// Fetches the cover into <siteDir>/cover.jpg, where SiteStore.loadCover
    /// already looks for it.
    private func mirrorCover(site: RemoteSite) async throws {
        guard let coverPath = site.coverUrl else { return }
        let destination = SiteStore.directory(for: site.id)
            .appendingPathComponent("cover.jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return }

        let data = try await Self.fetch(api.url(path: coverPath))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Helpers

    /// Every artifact this app will actually read, deduplicated.
    ///
    /// Deliberately narrower than the backend's referencedPaths in
    /// internal/services/site/manifest.go: that includes each frame's mask,
    /// which AnalysisFrame has no field for and the viewer never displays.
    /// Skipping them avoids downloading 26 files per site for nothing.
    nonisolated static func referencedPaths(in sequence: AnalysisSequence) -> [String] {
        var paths = Set<String>()
        for frame in sequence.frames {
            for candidate in [frame.rgb, frame.semantic, frame.depth] where !candidate.isEmpty {
                paths.insert(candidate)
            }
        }
        if let mesh = sequence.mesh {
            for candidate in [mesh.ply, mesh.texture, mesh.vertexLabels] {
                if let candidate, !candidate.isEmpty { paths.insert(candidate) }
            }
        }
        return Array(paths)
    }

    nonisolated private static func download(
        api: CoralfullAPI, siteID: String, relativePath: String, destination: URL
    ) async throws -> Int64 {
        guard let remote = api.fileURL(siteID: siteID, relativePath: relativePath) else {
            throw CoralfullAPIError.decoding("Could not build a URL for \(relativePath)")
        }

        // Already mirrored? Artifacts are immutable per content hash on the
        // backend, so presence with a non-zero size is enough.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attributes[.size] as? NSNumber, size.int64Value > 0 {
            return 0
        }

        let data = try await fetch(remote)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return Int64(data.count)
    }

    nonisolated private static func fetch(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw CoralfullAPIError.decoding("Response was not HTTP.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw CoralfullAPIError.backend(
                    code: "HTTP_\(http.statusCode)",
                    message: "Could not download \(url.lastPathComponent).",
                    status: http.statusCode, details: []
                )
            }
            return data
        } catch let error as CoralfullAPIError {
            throw error
        } catch {
            throw CoralfullAPIError.unreachable(error.localizedDescription)
        }
    }
}
