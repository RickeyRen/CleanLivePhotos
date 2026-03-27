//
//  CleanLivePhotosApp.swift
//  CleanLivePhotos
//
//  Created by RENJIAWEI on 2025/6/11.
//

import SwiftUI
import AppKit

@main
struct CleanLivePhotosApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(AspectRatioLocker(ratio: NSSize(width: 12, height: 7)))
        }
        .defaultSize(width: 1200, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// 锁定窗口宽高比，通过 NSWindow.contentAspectRatio 实现
private struct AspectRatioLocker: NSViewRepresentable {
    let ratio: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.contentAspectRatio = ratio
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.contentAspectRatio = ratio
        }
    }
}
