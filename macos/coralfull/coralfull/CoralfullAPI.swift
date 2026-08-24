//
//  CoralfullAPI.swift
//  coralfull
//
//  Client for the Go backend that owns the site list, the analysis manifests
//  and every artifact. Until this existed the app had no networking at all: it
//  read the bundled reference site and whatever the local pipeline had written.
//

import Foundation

// MARK: - Configuration

nonisolated enum CoralfullAPIConfig {
    static let defaultBaseURL = URL(string: "http://localhost:8321")!

    /// Resolution order: UserDefaults, then the environment, then the default.
    /// The environment variable matches the one tools/publish_site.py reads, so
    /// one export points the whole toolchain at the same backend.
    static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: "CoralfullAPIBaseURL"),
           let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme != nil {
            return url
        }
        if let raw = ProcessInfo.processInfo.environment["CORALFULL_API"],
           let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme != nil {
            return url
        }
        return defaultBaseURL
    }
}

// MARK: - Errors

nonisolated enum CoralfullAPIError: LocalizedError, Equatable, Sendable {
    /// The backend could not be reached at all -- almost always "it isn't running".
    case unreachable(String)
    /// The backend answered with its {code, message, status, details} envelope.
    case backend(code: String, message: String, status: Int, details: [String])
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case let .unreachable(detail):
            "Cannot reach the CoralFull backend at \(CoralfullAPIConfig.baseURL.absoluteString). \(detail)"
        case let .backend(_, message, _, details):
            details.isEmpty ? message : "\(message): \(details.prefix(3).joined(separator: ", "))"
        case let .decoding(detail):
            "The backend sent something unexpected. \(detail)"
        }
    }

    var isNotFound: Bool {
        if case let .backend(_, _, status, _) = self { return status == 404 }
        return false
    }
}

// MARK: - Wire types

/// A site exactly as the backend serves it.
///
/// `state` decodes straight into `UploadedSite.State`: the backend deliberately
/// emits Swift's synthesised enum-with-associated-value encoding
/// (`{"ready":{}}`, `{"failed":{"_0":"..."}}`), which is pinned by a test on
/// that side. Changing either end breaks this decode.
nonisolated struct RemoteSite: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let state: UploadedSite.State
    let photoCount: Int
    let priority: String
    let tags: [String]
    let coverUrl: String?
    let analysisUrl: String?
    let filesBase: String

    var hasAnalysis: Bool { analysisUrl != nil }
}

/// The backend wraps successes in {"data": ...}.
nonisolated private struct Envelope<T: Decodable>: Decodable {
    let data: T
}

nonisolated private struct BackendErrorBody: Decodable {
    let code: String
    let message: String
    let status: Int
    let details: [String]?
}

nonisolated struct CreateSiteResult: Decodable, Sendable {
    let site: RemoteSite
    let missing: [String]
}

// MARK: - Client

/// Stateless HTTP client. Every method is `async` and throws `CoralfullAPIError`.
nonisolated struct CoralfullAPI: Sendable {
    var baseURL: URL
    var session: URLSession

    init(baseURL: URL = CoralfullAPIConfig.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: URLs

    func url(path: String) -> URL {
        URL(string: path.hasPrefix("/") ? String(path.dropFirst()) : path, relativeTo: baseURL)?
            .absoluteURL ?? baseURL
    }

    /// Absolute URL for one artifact, given the path exactly as the manifest
    /// spells it. Percent-encodes each segment but keeps the separators, so
    /// nested paths like "site_b_frames/x_rgb.jpg" address correctly.
    func fileURL(siteID: String, relativePath: String) -> URL? {
        let encoded = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "api/sites/\(siteID)/files/\(encoded)", relativeTo: baseURL)?.absoluteURL
    }

    // MARK: Sites

    func listSites() async throws -> [RemoteSite] {
        try await get(Envelope<[RemoteSite]>.self, path: "/api/sites").data
    }

    func site(id: String) async throws -> RemoteSite {
        try await get(Envelope<RemoteSite>.self, path: "/api/sites/\(id)").data
    }

    /// Creates the record up front so a scan being built is visible in every
    /// client before it has any artifacts.
    func createSite(name: String, photoCount: Int, priority: String = "medium",
                    tags: [String] = []) async throws -> RemoteSite {
        let body: [String: Any] = [
            "name": name,
            "priority": priority,
            "photoCount": photoCount,
            "tags": tags,
            "state": ["importing": [:]],
        ]
        return try await send(Envelope<CreateSiteResult>.self,
                              method: "POST", path: "/api/sites", json: body).data.site
    }

    func patchSite(id: String, name: String? = nil, priority: String? = nil,
                   photoCount: Int? = nil, tags: [String]? = nil,
                   state: UploadedSite.State? = nil) async throws -> RemoteSite {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let priority { body["priority"] = priority }
        if let photoCount { body["photoCount"] = photoCount }
        if let tags { body["tags"] = tags }
        if let state { body["state"] = Self.encodeState(state) }
        return try await send(Envelope<RemoteSite>.self,
                              method: "PATCH", path: "/api/sites/\(id)", json: body).data
    }

    func deleteSite(id: String) async throws {
        _ = try await raw(method: "DELETE", path: "/api/sites/\(id)", body: nil, contentType: nil)
    }

    /// The manifest, served verbatim -- the same bytes the pipeline wrote.
    func analysisData(siteID: String) async throws -> Data {
        try await raw(method: "GET", path: "/api/sites/\(siteID)/analysis",
                      body: nil, contentType: nil)
    }

    // MARK: Publishing

    func missingAssets(siteID: String) async throws -> [String] {
        struct Missing: Decodable { let missing: [String] }
        return try await get(Envelope<Missing>.self,
                             path: "/api/sites/\(siteID)/missing").data.missing
    }

    func uploadAsset(siteID: String, relativePath: String, data: Data,
                     contentType: String) async throws {
        guard let target = fileURL(siteID: siteID, relativePath: relativePath) else {
            throw CoralfullAPIError.decoding("Could not build an upload URL for \(relativePath)")
        }
        var request = URLRequest(url: target)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await perform(request)
    }

    func publish(siteID: String) async throws -> RemoteSite {
        try await send(Envelope<RemoteSite>.self, method: "POST",
                       path: "/api/sites/\(siteID)/publish", json: [:]).data
    }

    // MARK: Transport

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let data = try await raw(method: "GET", path: path, body: nil, contentType: nil)
        return try Self.decode(type, from: data)
    }

    private func send<T: Decodable>(_ type: T.Type, method: String, path: String,
                                    json: [String: Any]) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json)
        let data = try await raw(method: method, path: path, body: body,
                                 contentType: "application/json")
        return try Self.decode(type, from: data)
    }

    private func raw(method: String, path: String, body: Data?,
                     contentType: String?) async throws -> Data {
        var request = URLRequest(url: url(path: path))
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    @discardableResult
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CoralfullAPIError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CoralfullAPIError.decoding("Response was not HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The backend's error envelope is flat, not wrapped in "data".
            if let body = try? JSONDecoder().decode(BackendErrorBody.self, from: data) {
                throw CoralfullAPIError.backend(code: body.code, message: body.message,
                                                status: body.status, details: body.details ?? [])
            }
            throw CoralfullAPIError.backend(code: "HTTP_\(http.statusCode)",
                                            message: "Request failed (\(http.statusCode)).",
                                            status: http.statusCode, details: [])
        }
        return data
    }

    // MARK: Coding

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw CoralfullAPIError.decoding(String(describing: error))
        }
    }

    /// Go's `time.Time` marshals as RFC 3339 *with* fractional seconds
    /// ("2026-08-25T00:52:56.011101+07:00"). `JSONDecoder.dateDecodingStrategy
    /// = .iso8601` uses ISO8601DateFormatter's default options, which do not
    /// include `.withFractionalSeconds` -- it throws on exactly that string.
    /// Both spellings are accepted here.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractionalFormatter.date(from: text) { return date }
            if let date = plainFormatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 date, got \"\(text)\"."
            )
        }
        return decoder
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Mirrors the synthesised Codable encoding the backend expects.
    static func encodeState(_ state: UploadedSite.State) -> [String: Any] {
        switch state {
        case .importing: ["importing": [:]]
        case .processing: ["processing": [:]]
        case .ready: ["ready": [:]]
        case .cancelled: ["cancelled": [:]]
        case .interrupted: ["interrupted": [:]]
        case let .failed(message): ["failed": ["_0": message]]
        }
    }
}
