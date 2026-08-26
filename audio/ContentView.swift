//
//  ContentView.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI
import MusicKit

private enum RootTab {
    case nowPlaying, library, effects, search
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all, playlists, artists, albums, songs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.tr("search.scope.all")
        case .playlists: return L10n.tr("library.playlists")
        case .artists: return L10n.tr("library.artists")
        case .albums: return L10n.tr("library.albums")
        case .songs: return L10n.tr("library.songs")
        }
    }
}

enum LibraryRoute: Hashable {
    case artist(SystemArtist)
    case album(SystemAlbum)
    case playlist(SystemPlaylist)
}

private enum LibraryCategory: String, CaseIterable, Identifiable {
    case playlists, artists, albums, songs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playlists: return L10n.tr("library.playlists")
        case .artists: return L10n.tr("library.artists")
        case .albums: return L10n.tr("library.albums")
        case .songs: return L10n.tr("library.songs")
        }
    }
}

private let bottomTabBarContentInset: CGFloat = 132

private extension View {
    func reservingTabBarSpace() -> some View {
        safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: bottomTabBarContentInset)
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var player: AudioPlayerViewModel
    @State private var selectedTab: RootTab = .nowPlaying
    @State private var selectedLibraryCategory: LibraryCategory = .artists
    @State private var selectedSearchScope: SearchScope = .songs
    @State private var isSearchPresented = false
    @State private var isShowingSettings = false
    @State private var libraryPath = NavigationPath()
    @State private var hasPreparedEffectsScreen = false
    @State private var shouldRenderEffectsControls = false
    @State private var effectsControlsRenderID = UUID()
    @State private var pendingEffectsActivationWorkItem: DispatchWorkItem?
    
    init(player: AudioPlayerViewModel) {
        self.player = player
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // NOW PLAYING
            NowPlayingView(player: player, onGoToAlbum: { album in
                let artist = player.findArtist(for: album)
                
                // 階層構造を作成: Root -> Artist -> Album
                var newPath = NavigationPath()
                if let artist = artist {
                    newPath.append(LibraryRoute.artist(artist))
                }
                newPath.append(LibraryRoute.album(album))
                
                libraryPath = newPath
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    selectedTab = .library
                }
            })
                .tag(RootTab.nowPlaying)
                .toolbar(.hidden, for: .tabBar)
            
            // LIBRARY
            NavigationStack(path: $libraryPath) {
                VStack(spacing: 0) {
                    if player.mediaLibraryAccess == .authorized {
                        if player.isLibraryBootstrapInProgress {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(player.accentColor)
                                Text(L10n.tr("now_playing.loading.badge"))
                                    .font(.appCaption())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                        Picker(L10n.tr("library.picker"), selection: $selectedLibraryCategory) {
                            ForEach(LibraryCategory.allCases) { category in
                                Text(category.title).tag(category)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: Theme.maxContentWidth)
                        .padding(.vertical, 8)
                        
                        if player.isLibraryBootstrapInProgress && player.systemSongs.isEmpty {
                            LoadingStateView(
                                title: L10n.tr("now_playing.loading.title"),
                                subtitle: L10n.tr("now_playing.loading.subtitle"),
                                accentColor: player.accentColor
                            )
                        } else {
                            libraryRoot
                                .scrollContentBackground(.hidden)
                        }
                    } else {
                        MediaLibraryPermissionView(
                            state: player.mediaLibraryAccess,
                            accentColor: player.accentColor,
                            isLoading: player.isRequestingSystemLibraryAccess
                        ) {
                            player.requestSystemLibraryAccess()
                        }
                    }
                }
                .background(Theme.background)
                .navigationTitle(L10n.tr("library.title"))
                .toolbar { settingsToolbar }
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .artist(let artist):
                        ArtistAlbumsView(artist: artist, player: player, onPlay: { selectedTab = .nowPlaying })
                    case .album(let album):
                        AlbumSongsView(album: album, player: player, onPlay: { selectedTab = .nowPlaying })
                    case .playlist(let playlist):
                        PlaylistSongsView(playlist: playlist, player: player, onPlay: { selectedTab = .nowPlaying })
                    }
                }
            }
            .tag(RootTab.library)
            .toolbar(.hidden, for: .tabBar)
            
            // EFFECTS
            NavigationStack {
                ZStack {
                    Theme.background.ignoresSafeArea()
                    
                    ScrollView {
                        LazyVStack(spacing: 32) {
                            SectionHeader(
                                title: L10n.tr("effects.realtime_processing"),
                                subtitle: player.realtimeEffectsStatusText
                            )
                            .overlay(alignment: .topTrailing) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(player.accentColor)
                                    .padding(.trailing, 16)
                                    .padding(.top, 4)
                                    .opacity(
                                        player.isEffectProcessing || player.isSpatialProcessing
                                            ? 1
                                            : 0
                                    )
                                    .accessibilityLabel(L10n.tr("effects.realtime_processing"))
                                    .accessibilityHidden(
                                        !(player.isEffectProcessing || player.isSpatialProcessing)
                                    )
                                    .animation(
                                        .easeInOut(duration: 0.15),
                                        value: player.isEffectProcessing || player.isSpatialProcessing
                                    )
                            }

                            if !player.supportsRealtimeEffects {
                                Text(player.realtimeEffectsAvailabilityDetail)
                                    .font(.appCaption())
                                    .foregroundStyle(Color.orange.opacity(0.9))
                                    .frame(width: Theme.maxContentWidth, alignment: .leading)
                                    .padding(.horizontal, 20)
                            }
                            
                            if shouldRenderEffectsControls {
                                effectsControlsContent
                                    .id(effectsControlsRenderID)
                            } else {
                                VStack(spacing: 14) {
                                    ProgressView()
                                        .tint(player.accentColor)
                                        .scaleEffect(0.8)
                                    Text("エフェクトを準備中...")
                                        .font(.system(size: 13, weight: .light))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .frame(width: Theme.maxContentWidth)
                                .padding(.vertical, 36)
                                .background(Theme.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                            }
                            
                            if !player.isLoading {
                                Text(player.localPlaybackFormatDescription)
                                    .font(.appCaption())
                                    .foregroundStyle(Theme.textSecondary.opacity(0.4))
                                    .padding(.top, 10)
                                    .frame(width: Theme.maxContentWidth)
                                    .lineLimit(1)
                            }

                            Text(player.signalDiagnosticsSummary)
                                .font(.appCaption())
                                .foregroundStyle(Theme.textSecondary.opacity(0.55))
                                .frame(width: Theme.maxContentWidth)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)

                            Text(player.audioRenderHealthSummary)
                                .font(.appCaption())
                                .foregroundStyle(
                                    player.audioRenderHealth.isStalled
                                        ? Color.red
                                        : Theme.textSecondary.opacity(0.55)
                                )
                                .frame(width: Theme.maxContentWidth)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(L10n.tr("effects.auto_dsp.title"))
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text("\(Int(player.automaticDSPStrength * 100))%")
                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                }

                                Slider(
                                    value: Binding(
                                        get: { player.automaticDSPStrength },
                                        set: { player.setAutomaticDSPStrength($0) }
                                    ),
                                    in: 0...1.5
                                )
                                .tint(player.accentColor)
                                .disabled(!player.supportsRealtimeEffects)

                                Picker("DSP", selection: Binding(
                                    get: { player.automaticDSPVoicing },
                                    set: { player.setAutomaticDSPVoicing($0) }
                                )) {
                                    Text("Natural").tag(AutomaticDSPVoicing.natural)
                                    Text("Reference").tag(AutomaticDSPVoicing.reference)
                                    Text("Immersive").tag(AutomaticDSPVoicing.immersive)
                                    Text("Safe").tag(AutomaticDSPVoicing.safe)
                                }
                                .pickerStyle(.segmented)
                                .disabled(!player.supportsRealtimeEffects)

                                Button {
                                    player.toggleABReferenceMode()
                                } label: {
                                    Label(
                                        player.isABReferenceMode ? "Reference" : "A/B Compare",
                                        systemImage: player.isABReferenceMode ? "waveform" : "arrow.left.arrow.right"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(player.isABReferenceMode ? player.accentColor : Theme.textSecondary)
                                .disabled(!player.supportsRealtimeEffects)

                                Text(player.automaticDSPSummary)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.58))
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .frame(width: Theme.maxContentWidth, alignment: .leading)
                            .background(Theme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                            Text(player.effectAuditSummaryText)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary.opacity(0.58))
                                .frame(width: Theme.maxContentWidth, alignment: .leading)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, Theme.horizontalPadding)
                        .padding(.vertical, 10)
                        .padding(.bottom, 132)
                        .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle(L10n.tr("effects.title"))
                .toolbar { settingsToolbar }
            }
            .tag(RootTab.effects)
            .toolbar(.hidden, for: .tabBar)
            
            // SEARCH
            NavigationStack {
                ZStack {
                    Theme.background.ignoresSafeArea()

                    searchRoot
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                }
                .navigationTitle(L10n.tr("search.title"))
                .toolbar { settingsToolbar }
                .searchable(
                    text: $player.searchText,
                    isPresented: $isSearchPresented,
                    prompt: L10n.tr("search.prompt")
                )
                .onSubmit(of: .search) {
                    isSearchPresented = false
                }
            }
            .tag(RootTab.search)
            .toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom) {
            CustomTabBar(selectedTab: $selectedTab, accentColor: player.accentColor)
        }
        .preferredColorScheme(.dark)
        .tint(player.accentColor)
        .alert(L10n.tr("common.error"), isPresented: errorBinding) {
            Button(L10n.tr("common.ok"), role: .cancel) { player.errorMessage = nil }
        } message: {
            Text(player.errorMessage ?? "")
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(player: player, isShowing: $isShowingSettings)
        }
        .onAppear {
            player.startInitialBootstrapIfNeeded()
            scheduleEffectsPresentationUpdate()
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue != .search {
                isSearchPresented = false
            }
            scheduleEffectsPresentationUpdate(refreshViewIdentity: newValue == .effects)
        }
        .onChange(of: scenePhase) { _, newPhase in
            scheduleEffectsPresentationUpdate(refreshViewIdentity: newPhase == .active && selectedTab == .effects)
        }
    }

    private func activateEffectsScreen(refreshViewIdentity: Bool = false) {
        guard selectedTab == .effects, scenePhase == .active else { return }

        player.setEffectScreenActive(true)
        if refreshViewIdentity {
            effectsControlsRenderID = UUID()
        }

        if hasPreparedEffectsScreen {
            if !shouldRenderEffectsControls {
                shouldRenderEffectsControls = true
            }
            return
        }

        if shouldRenderEffectsControls {
            shouldRenderEffectsControls = false
        }
        let workItem = DispatchWorkItem {
            hasPreparedEffectsScreen = true
            shouldRenderEffectsControls = true
        }
        pendingEffectsActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: workItem)
    }

    private func scheduleEffectsPresentationUpdate(refreshViewIdentity: Bool = false) {
        pendingEffectsActivationWorkItem?.cancel()
        pendingEffectsActivationWorkItem = nil

        let shouldActivate = selectedTab == .effects && scenePhase == .active
        if shouldActivate {
            DispatchQueue.main.async {
                activateEffectsScreen(refreshViewIdentity: refreshViewIdentity)
            }
        } else {
            if shouldRenderEffectsControls && !hasPreparedEffectsScreen {
                shouldRenderEffectsControls = false
            }
            player.setEffectScreenActive(false)
        }
    }

    private var effectsControlsContent: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Picker(
                    L10n.tr("effects.tab.accessibility_label"),
                    selection: Binding(
                        get: { player.selectedEffectPageTab },
                        set: { player.selectEffectPageTab($0) }
                    )
                ) {
                    ForEach(AudioEffectPageTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                Text(L10n.tr("effects.tab.selected_only_footer"))
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Theme.maxContentWidth)

            if player.selectedEffectPageTab == .pro {
                HeadphoneSpatialCard(
                    isEnabled: player.headphoneSpatialSettings.isEnabled,
                    preset: player.headphoneSpatialSettings.preset,
                    spatial: player.headphoneSpatialSettings.spatial,
                    crossfeed: player.headphoneSpatialSettings.crossfeed,
                    isInteractive: player.supportsRealtimeEffects,
                    onToggle: { player.setHeadphoneSpatialEnabled($0) },
                    onPresetChange: { player.setHeadphoneHRTFPreset($0) },
                    onParameterChange: { key, value in
                        player.setHeadphoneSpatialParameter(value, key: key)
                    },
                    accentColor: player.accentColor
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            ForEach(player.visibleEffectSettings) { effect in
                EffectCard(
                    kind: effect.kind,
                    isEnabled: effect.isEnabled,
                    parameters: effect.parameters,
                    isInteractive: player.supportsRealtimeEffects,
                    onToggle: { player.setEffectEnabled($0, for: effect.kind) },
                    onParameterChange: { key, value in
                        player.setEffectParameter(value, key: key, for: effect.kind)
                    },
                    accentColor: player.accentColor
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: player.selectedEffectPageTab)
    }
    
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { isShowingSettings = true } label: {
                Image(systemName: "person.crop.circle")
            }
        }
    }
    
    @ViewBuilder
    private var libraryRoot: some View {
        switch selectedLibraryCategory {
        case .playlists: playlistsView
        case .artists: artistsView
        case .albums: albumsView
        case .songs: songsView
        }
    }
    
    private var playlistsView: some View {
        Group {
            if player.filteredSystemPlaylists.isEmpty {
                emptyStateView(message: L10n.tr("empty.playlists"))
            } else {
                List(player.filteredSystemPlaylists) { playlist in
                    NavigationLink(value: LibraryRoute.playlist(playlist)) {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note.list").foregroundStyle(player.accentColor)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                MarqueeView(text: playlist.name, font: .headline, color: Theme.textPrimary, maxWidth: Theme.maxContentWidth - 80)
                                Text(L10n.songCount(playlist.songCount)).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(width: Theme.maxContentWidth, alignment: .leading)
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .reservingTabBarSpace()
            }
        }
    }
    
    private var artistsView: some View {
        Group {
            if player.filteredSystemArtists.isEmpty {
                emptyStateView(message: L10n.tr("empty.artists"))
            } else {
                List(player.filteredSystemArtists) { artist in
                    NavigationLink(value: LibraryRoute.artist(artist)) {
                        HStack(spacing: 16) {
                            // アーティストサムネイル（円形）
                            if let artwork = player.artistArtwork(for: artist, size: CGSize(width: 80, height: 80)) {
                                Image(uiImage: artwork)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                            } else {
                                Circle()
                                    .fill(Theme.secondaryBackground)
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 18, weight: .thin))
                                            .foregroundStyle(Theme.textSecondary)
                                    )
                                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                MarqueeView(text: artist.name, font: .system(size: 17, weight: .regular), color: Theme.textPrimary, maxWidth: Theme.maxContentWidth - 90)
                                Text(L10n.albumAndSongCount(albums: artist.albumCount, songs: artist.songCount))
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(width: Theme.maxContentWidth, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .reservingTabBarSpace()
            }
        }
    }
    
    private var albumsView: some View {
        Group {
            if player.filteredSystemAlbums.isEmpty {
                emptyStateView(message: L10n.tr("empty.albums"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                        ForEach(player.filteredSystemAlbums) { album in
                            NavigationLink(value: LibraryRoute.album(album)) {
                                AlbumTileView(album: album, artwork: player.albumArtwork(for: album))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.vertical, 20)
                    .padding(.bottom, bottomTabBarContentInset)
                    .frame(maxWidth: .infinity)
                }
                .reservingTabBarSpace()
            }
        }
    }
    
    private var songsView: some View {
        Group {
            if player.filteredSystemSongs.isEmpty {
                emptyStateView(message: L10n.tr("empty.songs"))
            } else {
                List(player.filteredSystemSongs) { song in
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            player.playSystemSong(song)
                            selectedTab = .nowPlaying
                        }
                    } label: {
                        SongRowView(
                            song: song,
                            isActive: player.isSongActive(song),
                            isPlaying: player.isPlaying,
                            isProcessing: player.isLoading,
                            artwork: player.songArtwork(for: song),
                            accentColor: player.accentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .reservingTabBarSpace()
            }
        }
    }
    
    private var searchRoot: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(player.searchResultCountSummary)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.maxContentWidth, alignment: .leading)

                    Picker(L10n.tr("search.scope.picker"), selection: $selectedSearchScope) {
                        ForEach(SearchScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: Theme.maxContentWidth)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)

            if !player.hasActiveSearch {
                Section(L10n.tr("search.section.discover")) {
                    Text(L10n.tr("search.cross_library_hint"))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.maxContentWidth, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }

            if player.mediaLibraryAccess == .authorized {
                if selectedSearchScope == .all || selectedSearchScope == .playlists {
                    Section(L10n.tr("library.playlists")) {
                        if player.filteredSystemPlaylists.isEmpty {
                            searchEmptyRow
                        } else {
                            ForEach(player.filteredSystemPlaylists.prefix(6)) { playlist in
                                NavigationLink(value: LibraryRoute.playlist(playlist)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(player.accentColor)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(playlist.name)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(L10n.songCount(playlist.songCount))
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .frame(width: Theme.maxContentWidth, alignment: .leading)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }

                if selectedSearchScope == .all || selectedSearchScope == .artists {
                    Section(L10n.tr("library.artists")) {
                        if player.filteredSystemArtists.isEmpty {
                            searchEmptyRow
                        } else {
                            ForEach(player.filteredSystemArtists.prefix(8)) { artist in
                                NavigationLink(value: LibraryRoute.artist(artist)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .foregroundStyle(player.accentColor)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(artist.name)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(L10n.albumAndSongCount(albums: artist.albumCount, songs: artist.songCount))
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .frame(width: Theme.maxContentWidth, alignment: .leading)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }

                if selectedSearchScope == .all || selectedSearchScope == .albums {
                    Section(L10n.tr("library.albums")) {
                        if player.filteredSystemAlbums.isEmpty {
                            searchEmptyRow
                        } else {
                            ForEach(player.filteredSystemAlbums.prefix(8)) { album in
                                NavigationLink(value: LibraryRoute.album(album)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "square.stack.fill")
                                            .foregroundStyle(player.accentColor)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.title)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(album.artist)
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .frame(width: Theme.maxContentWidth, alignment: .leading)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }

                if selectedSearchScope == .all || selectedSearchScope == .songs {
                    Section(L10n.tr("library.songs")) {
                        if player.filteredSystemSongs.isEmpty {
                            searchEmptyRow
                        } else {
                            ForEach(player.filteredSystemSongs.prefix(24)) { song in
                                Button {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                        player.playSystemSong(song)
                                        selectedTab = .nowPlaying
                                    }
                                } label: {
                                    SongRowView(
                                        song: song,
                                        isActive: player.isSongActive(song),
                                        isPlaying: player.isPlaying,
                                        isProcessing: player.isLoading,
                                        artwork: player.songArtwork(for: song),
                                        accentColor: player.accentColor
                                    )
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
            } else {
                Section(L10n.tr("search.section.local_library")) {
                    MediaLibraryPermissionInlineCard(
                        title: L10n.tr("search.local_library_locked"),
                        description: L10n.tr("search.local_library_locked_detail"),
                        accentColor: player.accentColor,
                        actionTitle: L10n.tr("permission.allow_access"),
                        isLoading: player.isRequestingSystemLibraryAccess,
                        action: { player.requestSystemLibraryAccess() }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            Section(L10n.tr("search.section.apple_music")) {
                if player.appleMusicAccessStatus != .authorized {
                    MediaLibraryPermissionInlineCard(
                        title: L10n.tr("apple_music.permission.title"),
                        description: L10n.tr("apple_music.permission.description"),
                        accentColor: player.accentColor,
                        actionTitle: L10n.tr("permission.allow_access"),
                        isLoading: player.isRequestingAppleMusicAccess,
                        action: { player.requestAppleMusicAccess() }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                } else {
                    if let statusMessage = player.appleMusicStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(Color.orange.opacity(0.92))
                            .frame(width: Theme.maxContentWidth, alignment: .leading)
                            .padding(.vertical, 4)
                    }

                    if player.isSearchingAppleMusicCatalog {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(player.accentColor)
                            Text(L10n.tr("apple_music.searching"))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(width: Theme.maxContentWidth, alignment: .leading)
                        .padding(.vertical, 6)
                    } else if !player.hasActiveSearch {
                        Text(L10n.tr("apple_music.search_hint"))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: Theme.maxContentWidth, alignment: .leading)
                            .padding(.vertical, 6)
                    } else if player.appleMusicCatalogAlbums.isEmpty && player.appleMusicCatalogSongs.isEmpty {
                        Text(L10n.tr("apple_music.empty"))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: Theme.maxContentWidth, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        if !player.appleMusicCatalogAlbums.isEmpty {
                            appleMusicSubsectionHeader(L10n.tr("library.albums"))
                            ForEach(player.appleMusicCatalogAlbums) { album in
                                AppleMusicCatalogAlbumRow(
                                    album: album,
                                    canAdd: player.canModifyAppleMusicLibrary,
                                    isAdding: player.isAddingAppleMusicItemIDs.contains(album.id),
                                    isAdded: player.addedAppleMusicItemIDs.contains(album.id),
                                    accentColor: player.accentColor,
                                    onAdd: { player.addAppleMusicAlbumToLibrary(album) }
                                )
                                .listRowInsets(EdgeInsets(top: 6, leading: Theme.horizontalPadding, bottom: 6, trailing: Theme.horizontalPadding))
                                .listRowBackground(Color.clear)
                            }
                        }

                        if !player.appleMusicCatalogSongs.isEmpty {
                            appleMusicSubsectionHeader(L10n.tr("library.songs"))
                            ForEach(player.appleMusicCatalogSongs) { song in
                                AppleMusicCatalogSongRow(
                                    song: song,
                                    canAdd: player.canModifyAppleMusicLibrary,
                                    isAdding: player.isAddingAppleMusicItemIDs.contains(song.id),
                                    isAdded: player.addedAppleMusicItemIDs.contains(song.id),
                                    accentColor: player.accentColor,
                                    onAdd: { player.addAppleMusicSongToLibrary(song) }
                                )
                                .listRowInsets(EdgeInsets(top: 6, leading: Theme.horizontalPadding, bottom: 6, trailing: Theme.horizontalPadding))
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .reservingTabBarSpace()
    }

    private func appleMusicSubsectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: Theme.maxContentWidth, alignment: .leading)
            .padding(.top, 4)
    }

    private var searchEmptyRow: some View {
        Text(player.hasActiveSearch ? L10n.tr("search.empty.active") : L10n.tr("search.empty.idle"))
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: Theme.maxContentWidth, alignment: .leading)
            .padding(.vertical, 6)
    }
    
    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(Theme.textSecondary.opacity(0.3))
            Text(message)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(width: Theme.maxContentWidth)
    }
    
    private var errorBinding: Binding<Bool> {
        Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })
    }
}

// MARK: - Navigation Views

struct ArtistAlbumsView: View {
    let artist: SystemArtist
    let player: AudioPlayerViewModel
    let onPlay: () -> Void
    
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                        ForEach(player.albums(for: artist)) { album in
                            NavigationLink(value: LibraryRoute.album(album)) {
                                AlbumTileView(album: album, artwork: player.albumArtwork(for: album))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.vertical, 20)
                    .padding(.bottom, bottomTabBarContentInset)
                }
                .frame(maxWidth: .infinity)
            }
            .reservingTabBarSpace()
        }
        .navigationTitle(artist.name)
    }
}

struct AlbumSongsView: View {
    let album: SystemAlbum
    let player: AudioPlayerViewModel
    let onPlay: () -> Void
    
    var body: some View {
        let songs = player.songs(for: album)
        ScrollViewReader { proxy in
            List {
                HeaderSection(album: album, artwork: player.albumArtwork(for: album), count: songs.count)
                    .listRowBackground(Color.clear)
                
                Section(L10n.tr("album.track_list")) {
                    ForEach(songs) { song in
                        Button {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                player.playSystemQueue(songs, startAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0, title: album.title)
                                onPlay()
                            }
                        } label: {
                            SongRowView(
                                song: song,
                                isActive: player.isSongActive(song),
                                isPlaying: player.isPlaying,
                                isProcessing: player.isLoading,
                                artwork: player.songArtwork(for: song),
                                accentColor: player.accentColor
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .id(song.id)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listStyle(.plain)
            .reservingTabBarSpace()
            .navigationTitle(album.title)
            .onAppear {
                if let activeSong = songs.first(where: { player.isSongActive($0) }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            proxy.scrollTo(activeSong.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

struct PlaylistSongsView: View {
    let playlist: SystemPlaylist
    let player: AudioPlayerViewModel
    let onPlay: () -> Void
    
    var body: some View {
        let songs = player.songs(in: playlist)
        List(songs) { song in
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    player.playSystemQueue(songs, startAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0, title: playlist.name)
                    onPlay()
                }
            } label: {
                SongRowView(
                    song: song,
                    isActive: player.isSongActive(song),
                    isPlaying: player.isPlaying,
                    isProcessing: player.isLoading,
                    artwork: player.songArtwork(for: song),
                    accentColor: player.accentColor
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listStyle(.plain)
        .reservingTabBarSpace()
        .navigationTitle(playlist.name)
    }
}

// MARK: - Supporting Components

private struct MediaLibraryPermissionInlineCard: View {
    let title: String
    let description: String
    let accentColor: Color
    let actionTitle: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(description)
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: action) {
                LoadingButtonLabel(
                    title: actionTitle,
                    isLoading: isLoading,
                    accentColor: .black
                )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(18)
        .frame(width: Theme.maxContentWidth, alignment: .leading)
        .background(Theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct AppleMusicCatalogSongRow: View {
    let song: AppleMusicCatalogSongResult
    let canAdd: Bool
    let isAdding: Bool
    let isAdded: Bool
    let accentColor: Color
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppleMusicArtworkView(url: song.artworkURL, accentColor: accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            AppleMusicAddButton(
                canAdd: canAdd,
                isAdding: isAdding,
                isAdded: isAdded,
                accentColor: accentColor,
                action: onAdd
            )
        }
        .frame(width: Theme.maxContentWidth, alignment: .leading)
    }
}

private struct AppleMusicCatalogAlbumRow: View {
    let album: AppleMusicCatalogAlbumResult
    let canAdd: Bool
    let isAdding: Bool
    let isAdded: Bool
    let accentColor: Color
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppleMusicArtworkView(url: album.artworkURL, accentColor: accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(albumSubtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            AppleMusicAddButton(
                canAdd: canAdd,
                isAdding: isAdding,
                isAdded: isAdded,
                accentColor: accentColor,
                action: onAdd
            )
        }
        .frame(width: Theme.maxContentWidth, alignment: .leading)
    }

    private var albumSubtitle: String {
        if let trackCount = album.trackCount, trackCount > 0 {
            return "\(album.artistName) • \(L10n.songCount(trackCount))"
        }
        return album.artistName
    }
}

private struct AppleMusicArtworkView: View {
    let url: URL?
    let accentColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.secondaryBackground)
                .frame(width: 48, height: 48)

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ProgressView()
                            .tint(accentColor)
                            .frame(width: 48, height: 48)
                    default:
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(accentColor.opacity(0.85))
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accentColor.opacity(0.85))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct AppleMusicAddButton: View {
    let canAdd: Bool
    let isAdding: Bool
    let isAdded: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isAdding {
                    ProgressView()
                        .tint(.black)
                        .frame(width: 18, height: 18)
                } else if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canAdd ? .black : Theme.textSecondary)
                }
            }
            .frame(width: 34, height: 34)
            .background(canAdd ? accentColor : Theme.secondaryBackground)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(canAdd ? accentColor.opacity(0.22) : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canAdd || isAdding || isAdded)
    }
}

struct HeaderSection: View {
    let album: SystemAlbum
    let artwork: UIImage?
    let count: Int
    
    var body: some View {
        HStack(spacing: 20) {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable().scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Theme.secondaryBackground)
                    .frame(width: 80, height: 80)
                    .overlay(Image(systemName: "opticaldisc").font(.title3.weight(.thin)).foregroundStyle(Theme.textSecondary))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                MarqueeView(text: album.title, font: .headline, color: Theme.textPrimary, maxWidth: Theme.maxContentWidth - 120)
                MarqueeView(text: album.artist, font: .subheadline, color: Theme.textSecondary, maxWidth: Theme.maxContentWidth - 120)
                Text(L10n.songCount(count)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 8)
        .frame(width: Theme.maxContentWidth)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            
            Text(subtitle)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
        }
        .frame(width: Theme.maxContentWidth, alignment: .leading)
    }
}

struct SettingsView: View {
    @ObservedObject var player: AudioPlayerViewModel
    @Binding var isShowing: Bool
    @State private var isShowingCacheDeletionConfirmation = false
    
    var body: some View {
        NavigationStack {
            List {
                Section(L10n.tr("settings.section.info")) {
                    LabeledContent(L10n.tr("settings.access_status"), value: player.mediaLibraryAccess.description)
                    LabeledContent(L10n.tr("settings.current_track"), value: player.trackTitle)
                }
                .listRowBackground(Theme.secondaryBackground)
                
                Section(L10n.tr("library.title")) {
                    Button {
                        player.reloadSystemLibrary()
                    } label: {
                        LoadingButtonLabel(
                            title: L10n.tr("settings.reload_library"),
                            isLoading: player.isRequestingSystemLibraryAccess || player.isLibraryBootstrapInProgress,
                            accentColor: player.accentColor
                        )
                    }
                    .disabled(
                        player.isRequestingSystemLibraryAccess
                            || player.isLibraryBootstrapInProgress
                            || player.isScanningLocalLibrary
                            || player.isPlaying
                            || player.isPlaybackStarting
                    )

                    Button {
                        player.scanLocalLibrary()
                    } label: {
                        LoadingButtonLabel(
                            title: L10n.tr("settings.scan_local_library"),
                            isLoading: player.isScanningLocalLibrary,
                            accentColor: player.accentColor
                        )
                    }
                    .disabled(
                        player.isScanningLocalLibrary
                            || player.isLibraryBootstrapInProgress
                            || player.isRequestingSystemLibraryAccess
                            || player.isPlaying
                            || player.isPlaybackStarting
                    )

                    if let loadingMessage = player.libraryLoadingMessage {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(player.accentColor)
                            Text(loadingMessage)
                                .font(.appCaption())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(Theme.secondaryBackground)

                Section(L10n.tr("settings.section.audio")) {
                    LabeledContent(
                        L10n.tr("settings.upsampling_mode"),
                        value: L10n.upsamplingModeTitle(player.upsamplingMode)
                    )
                    .foregroundStyle(Theme.textPrimary)
                    Text(L10n.tr("settings.upsampling_footer"))
                        .font(.appCaption())
                        .foregroundStyle(Theme.textSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("settings.audio_cache.title"))
                            .foregroundStyle(Theme.textPrimary)
                        Text(player.preparedAudioCacheSummary)
                            .font(.appCaption())
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(role: .destructive) {
                        isShowingCacheDeletionConfirmation = true
                    } label: {
                        HStack(spacing: 10) {
                            Text(L10n.tr("settings.audio_cache.clear"))
                            Spacer()
                            if player.isClearingPreparedAudioCache {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(
                        player.isClearingPreparedAudioCache
                            || player.preparedAudioCacheStatistics.byteCount == 0
                    )

                    Text(L10n.tr("settings.audio_cache.footer"))
                        .font(.appCaption())
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.secondaryBackground)
                
                Section(L10n.tr("settings.section.about")) {
                    Link("Cue", destination: URL(string: "https://cue.college/")!)
                }
                .listRowBackground(Theme.secondaryBackground)
            }
            .preferredColorScheme(.dark)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.tr("settings.title"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.tr("common.close")) { isShowing = false } } }
            .onAppear {
                player.refreshPreparedAudioCacheStatistics()
            }
            .confirmationDialog(
                L10n.tr("settings.audio_cache.clear_confirmation.title"),
                isPresented: $isShowingCacheDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.tr("settings.audio_cache.clear"), role: .destructive) {
                    player.clearPreparedAudioCache()
                }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("settings.audio_cache.clear_confirmation.message"))
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SettingsView(
                player: AudioPlayerViewModel(),
                isShowing: .constant(true)
            )
            .previewDevice("iPhone SE (3rd generation)")

            SettingsView(
                player: AudioPlayerViewModel(),
                isShowing: .constant(true)
            )
            .previewDevice("iPhone 16 Pro Max")
        }
    }
}

// MARK: - Custom Tab Bar

private struct CustomTabBar: View {
    @Binding var selectedTab: RootTab
    let accentColor: Color
    
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // Apple Music
            TabBarButton(
                icon: "applelogo",
                title: L10n.tr("tab.music"),
                isActive: false,
                accentColor: accentColor
            ) {
                if let url = URL(string: "music://") { openURL(url) }
            }
            
            Spacer()
            
            // Library
            TabBarButton(
                icon: "music.note.house.fill",
                title: L10n.tr("library.title"),
                isActive: selectedTab == .library,
                accentColor: accentColor
            ) { selectedTab = .library }
            
            Spacer()
            
            // Now Playing — ラジオアイコン (中央・大きめ)
            Button {
                selectedTab = .nowPlaying
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(selectedTab == .nowPlaying
                                  ? accentColor.opacity(0.15)
                                  : Color.white.opacity(0.08))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle()
                                    .stroke(
                                        selectedTab == .nowPlaying
                                        ? accentColor.opacity(0.4)
                                        : Color.white.opacity(0.12),
                                        lineWidth: 1
                                    )
                            )
                        
                        Image(systemName: "radio.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(
                                selectedTab == .nowPlaying
                                ? accentColor
                                : Theme.textSecondary
                            )
                    }
                    
                    Text(L10n.tr("tab.now_playing"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            selectedTab == .nowPlaying
                            ? accentColor
                            : Theme.textSecondary
                        )
                }
                .frame(width: 60)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Effects
            TabBarButton(
                icon: "waveform.path.ecg",
                title: L10n.tr("effects.title"),
                isActive: selectedTab == .effects,
                accentColor: accentColor
            ) { selectedTab = .effects }
            
            Spacer()
            
            // Search
            TabBarButton(
                icon: "magnifyingglass",
                title: L10n.tr("search.title"),
                isActive: selectedTab == .search,
                accentColor: accentColor
            ) { selectedTab = .search }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            GlassFallbackShape(
                shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                fallbackFill: Theme.secondaryBackground.opacity(0.86),
                cornerRadius: 22
            )
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

private struct TabBarButton: View {
    let icon: String
    let title: String
    let isActive: Bool
    let accentColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 44) // 固定の高さを設けてアイコン自体の位置を揃える
                
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isActive ? accentColor : Theme.textSecondary.opacity(0.7))
            .frame(width: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
