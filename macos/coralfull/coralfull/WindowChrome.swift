//
//  WindowChrome.swift
//  coralfull
//

import AppKit
import SwiftUI

struct WindowTrafficControls: View {
    var body: some View {
        HStack(spacing: 10) {
            trafficButton(color: .red) {
                NSApp.keyWindow?.performClose(nil)
            }
            trafficButton(color: .yellow) {
                NSApp.keyWindow?.miniaturize(nil)
            }
            trafficButton(color: .green) {
                NSApp.keyWindow?.zoom(nil)
            }
        }
    }

    private func trafficButton(color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
