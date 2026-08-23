//
//  ReefAssetServerTestMain.swift
//  Command-line verification for the Spark local asset server.
//

import Foundation

@main
struct ReefAssetServerTestMain {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            fputs("usage: ReefAssetServerTestMain <ReefViewer folder>\n", stderr)
            exit(2)
        }

        let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let server = ReefAssetServer(root: root)

        let plyURL = try server.fileURL(for: "/reef_struct_orient_proper_cleaned.ply")
        let htmlURL = try server.fileURL(for: "/index.html")
        let jsURL = try server.fileURL(for: "/viewer.js")

        precondition(FileManager.default.fileExists(atPath: plyURL.path), "missing ply")
        precondition(FileManager.default.fileExists(atPath: htmlURL.path), "missing index.html")
        precondition(FileManager.default.fileExists(atPath: jsURL.path), "missing viewer.js")

        do {
            _ = try server.fileURL(for: "/../ContentView.swift")
            fputs("path traversal was allowed\n", stderr)
            exit(1)
        } catch ReefAssetServerError.invalidPath {
            // expected
        }

        let pageURL = try await server.start()
        defer { server.stop() }

        try await assertHTTP(pageURL, contains: "<div id=\"canvas\">")
        try await assertHTTP(pageURL.deletingLastPathComponent().appendingPathComponent("viewer.js"), contains: "SparkRenderer")
        try await assertPLY(pageURL.deletingLastPathComponent().appendingPathComponent("reef_struct_orient_proper_cleaned.ply"))

        print("port=\(server.port ?? 0)")
        print("page=\(pageURL.absoluteString)")
        print("OK")
    }

    static func assertHTTP(_ url: URL, contains needle: String) async throws {
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        precondition(http.statusCode == 200, "\(url.lastPathComponent) status \(http.statusCode)")
        let body = String(decoding: data, as: UTF8.self)
        precondition(body.contains(needle), "\(url.lastPathComponent) missing \(needle)")
    }

    static func assertPLY(_ url: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        precondition(http.statusCode == 200, "ply status \(http.statusCode)")
        precondition(http.expectedContentLength > 1_000_000, "ply too small")
        let prefix = String(decoding: data.prefix(32), as: UTF8.self)
        precondition(prefix.hasPrefix("ply"), "ply header missing, got \(prefix)")
    }
}
