//
//  audioApp.swift
//  audio
//
//  Created by littlebuddha on 2026/04/02.
//

import SwiftUI

@main
struct audioApp: App {
    // The audio engine belongs to the application lifetime. SwiftUI may
    // recreate ContentView during scene and presentation transitions.
    @StateObject private var player = AudioPlayerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(player: player)
        }
    }
}
