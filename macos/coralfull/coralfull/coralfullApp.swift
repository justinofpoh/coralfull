//
//  coralfullApp.swift
//  coralfull
//
//  Created by Juno on 14/08/26.
//

import SwiftUI

@main
struct coralfullApp: App {
    init() {
        #if DEBUG
        DebugCapture.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1_500, height: 950)
        .windowStyle(.hiddenTitleBar)
    }
}
