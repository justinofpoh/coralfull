//
//  DebugCapture.swift
//  coralfull
//
//  DEBUG-only automation hook: posting the distributed notification
//  "coralfull.debugCapture" makes the app write PNG snapshots of its main
//  window and any live SceneKit views to Application Support/coralfull/
//  debug-captures. Used by automated UI verification; compiled out of
//  release builds entirely.
//

#if DEBUG
import AppKit
import SceneKit

enum DebugCapture {
    static let directory: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("coralfull", isDirectory: true)
            .appendingPathComponent("debug-captures", isDirectory: true)
    }()

    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("coralfull.debugCapture"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                capture()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("coralfull.debugOrbit"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                orbit()
            }
        }
        // "coralfull.debugImport" with the folder path as the notification
        // object starts the create-site flow exactly as if the user had
        // picked that folder in the open panel (which automation cannot
        // drive without stealing focus).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("coralfull.debugImport"),
            object: nil,
            queue: .main
        ) { notification in
            let path = notification.object as? String
            Task { @MainActor in
                guard let path else { return }
                NotificationCenter.default.post(name: .debugImportRequest, object: path)
            }
        }
    }

    /// Rotates the 3D viewer camera ~30° around the world Y axis, simulating a
    /// user orbit so automation can confirm viewport-dependent rendering.
    @MainActor
    private static func orbit() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView,
              let sceneView = sceneViews(in: content).first,
              let pointOfView = sceneView.pointOfView else { return }
        let rotation = SCNMatrix4MakeRotation(.pi / 6, 0, 1, 0)
        pointOfView.transform = SCNMatrix4Mult(pointOfView.transform, rotation)
    }

    @MainActor
    private static func capture() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView else { return }

        if let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: representation)
            write(representation, name: "window_cache")
        }

        if let layer = content.layer {
            let scale = window.backingScaleFactor
            let size = CGSize(width: content.bounds.width * scale, height: content.bounds.height * scale)
            if let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ) {
                context.scaleBy(x: scale, y: scale)
                layer.render(in: context)
                if let cgImage = context.makeImage() {
                    write(NSBitmapImageRep(cgImage: cgImage), name: "window_layer")
                }
            }
        }

        for (index, sceneView) in sceneViews(in: content).enumerated() {
            let snapshot = sceneView.snapshot()
            if let tiff = snapshot.tiffRepresentation,
               let representation = NSBitmapImageRep(data: tiff) {
                write(representation, name: "scene\(index)")
            }
        }
    }

    private static func sceneViews(in root: NSView) -> [SCNView] {
        var found = [SCNView]()
        var queue: [NSView] = [root]
        while let view = queue.popLast() {
            if let sceneView = view as? SCNView {
                found.append(sceneView)
            }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    private static func write(_ representation: NSBitmapImageRep, name: String) {
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
#endif
