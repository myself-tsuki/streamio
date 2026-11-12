//
//  StreamioApp.swift
//  Streamio
//

import SwiftUI

@main
struct StreamioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 750)
    }
}
