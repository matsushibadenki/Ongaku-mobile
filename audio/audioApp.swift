//
//  audioApp.swift
//  audio
//
//  Created by littlebuddha on 2026/04/02.
//

import SwiftUI

@main
struct audioApp: App {
    @Environment(\.scenePhase) private var scenePhase
    // The audio engine belongs to the application lifetime. SwiftUI may
    // recreate ContentView during scene and presentation transitions.
    @StateObject private var player = AudioPlayerViewModel()
    @StateObject private var desktopSync = DesktopSyncController()

    var body: some Scene {
        WindowGroup {
            ContentView(player: player)
                .environmentObject(desktopSync)
                .task {
                    desktopSync.onLibraryChanged = {
                        player.scanLocalLibrary()
                    }
                    desktopSync.start()
                    await desktopSync.refreshLocalLibrary()
                    player.scanLocalLibrary()
                }
                .confirmationDialog(
                    L10n.tr("sync.pairing.title"),
                    isPresented: Binding(
                        get: { desktopSync.pairingRequest != nil },
                        set: { isPresented in
                            guard !isPresented, let request = desktopSync.pairingRequest else { return }
                            desktopSync.declinePairing(request)
                        }
                    ),
                    presenting: desktopSync.pairingRequest
                ) { request in
                    Button(L10n.tr("sync.pairing.accept")) {
                        desktopSync.acceptPairing(request)
                    }
                    Button(L10n.tr("sync.pairing.decline"), role: .cancel) {
                        desktopSync.declinePairing(request)
                    }
                } message: { request in
                    Text(L10n.tr("sync.pairing.message", request.deviceName, request.pairingCode))
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        desktopSync.resumeDiscovery()
                    }
                }
        }
    }
}
