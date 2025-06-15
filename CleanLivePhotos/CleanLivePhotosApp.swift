//
//  CleanLivePhotosApp.swift
//  CleanLivePhotos
//
//  Created by RENJIAWEI on 2025/6/11.
//

import SwiftUI

@main
struct CleanLivePhotosApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}
