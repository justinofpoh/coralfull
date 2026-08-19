//
//  ReefAssetServer.swift
//  coralfull
//
//  Serves the bundled Spark viewer over loopback HTTP so WKWebView fetch()
//  of the PLY succeeds (custom schemes do not return HTTP 200).
//

import Foundation
import Network

enum ReefAssetServerError: Error, LocalizedError {
    case missingViewerRoot
    case listenerFailed
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .missingViewerRoot:
            "The Spark viewer files are missing from the app bundle."
        case .listenerFailed:
            "Could not start the local reef viewer server."
        case .invalidPath:
            "The viewer requested a file outside the bundle."
        }
    }
}

nonisolated final class ReefAssetServer: @unchecked Sendable {
    private let root: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "juno.coralfull.reef-server")
    private(set) var port: UInt16?

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    static func bundledRoot() -> URL? {
        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ReefViewer") {
            return page.deletingLastPathComponent()
        }
        if let page = Bundle.main.url(forResource: "index", withExtension: "html") {
            return page.deletingLastPathComponent()
        }
        return nil
    }

    func start() async throws -> URL {
        if let port {
            return URL(string: "http://127.0.0.1:\(port)/index.html")!
        }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        let pageURL: URL = try await withCheckedThrowingContinuation { continuation in
            let state = ResumeOnce()
            let resume: @Sendable (Result<URL, Error>) -> Void = { result in
                state.run {
                    continuation.resume(with: result)
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        resume(.failure(ReefAssetServerError.listenerFailed))
                        return
                    }
                    self?.port = port
                    resume(.success(URL(string: "http://127.0.0.1:\(port)/index.html")!))
                case .failed:
                    resume(.failure(ReefAssetServerError.listenerFailed))
                case .cancelled:
                    resume(.failure(CancellationError()))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: queue)
        }

        return pageURL
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    func fileURL(for requestPath: String) throws -> URL {
        var path = requestPath
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        path = path.removingPercentEncoding ?? path
        if path.isEmpty || path == "/" {
            path = "/index.html"
        }

        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) || candidate.path == root.path else {
            throw ReefAssetServerError.invalidPath
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw ReefAssetServerError.invalidPath
        }
        return candidate
    }

    func httpResponse(for requestPath: String) throws -> Data {
        let fileURL = try fileURL(for: requestPath)
        let body = try Data(contentsOf: fileURL)
        return Self.response(status: "200 OK", mime: Self.mimeType(for: fileURL.pathExtension), body: body)
    }

    func notFoundResponse() -> Data {
        Self.response(status: "404 Not Found", mime: "text/plain; charset=utf-8", body: Data("Not found".utf8))
    }

    func optionsResponse() -> Data {
        Self.header(
            status: "204 No Content",
            fields: [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, HEAD, OPTIONS",
                "Access-Control-Allow-Headers: *",
                "Content-Length: 0",
                "Connection: close"
            ]
        )
    }

    private static func response(status: String, mime: String, body: Data) -> Data {
        var data = header(
            status: status,
            fields: [
                "Content-Type: \(mime)",
                "Content-Length: \(body.count)",
                "Access-Control-Allow-Origin: *",
                "Cache-Control: no-cache",
                "Connection: close"
            ]
        )
        data.append(body)
        return data
    }

    private static func header(status: String, fields: [String]) -> Data {
        var lines = ["HTTP/1.1 \(status)"]
        lines.append(contentsOf: fields)
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var next = buffer
            if let chunk {
                next.append(chunk)
            }

            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: next[..<range.lowerBound], as: UTF8.self)
                let requestLine = head.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                let parts = requestLine.split(separator: " ")
                let method = parts.first.map(String.init) ?? "GET"
                let path = parts.dropFirst().first.map(String.init) ?? "/"

                let response: Data
                if method == "OPTIONS" {
                    response = self.optionsResponse()
                } else {
                    do {
                        response = try self.httpResponse(for: path)
                    } catch {
                        response = self.notFoundResponse()
                    }
                }

                connection.send(
                    content: response,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: next)
        }
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "wasm": "application/wasm"
        case "ply": "application/octet-stream"
        case "json": "application/json; charset=utf-8"
        case "bin": "application/octet-stream"
        default: "application/octet-stream"
        }
    }
}

private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}
