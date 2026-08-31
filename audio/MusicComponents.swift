//
//  MusicComponents.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI

struct LoadingStateView: View {
    let title: String
    var subtitle: String? = nil
    var accentColor: Color = Theme.accent

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(accentColor)
                .scaleEffect(0.9)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 36)
    }
}

struct LoadingButtonLabel: View {
    let title: String
    let isLoading: Bool
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .tint(accentColor)
                    .scaleEffect(0.82)
            }
            Text(title)
        }
    }
}

struct StartupLoadingIndicator: View {
    let accentColor: Color
    var showsTitle = true

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 0.04)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<18, id: \.self) { index in
                        let position = dotPosition(for: index, time: time)
                        let intensity = dotIntensity(for: index, time: time)
                        Circle()
                            .fill(Color.white.opacity(0.22 + intensity * 0.78))
                            .frame(width: 4 + intensity * 7, height: 4 + intensity * 7)
                            .shadow(color: Color.white.opacity(intensity * 0.45), radius: 5)
                            .position(position)
                    }
                }
                .frame(width: 104, height: 104)
            }

            if showsTitle {
                Text("ライブラリを準備中")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("音楽の舞台を整えています")
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ライブラリを準備中")
    }

    private func dotPosition(for index: Int, time: TimeInterval) -> CGPoint {
        let angle = (Double(index) / 18.0) * Double.pi * 2.0 + time * 1.8
        let radius = 36.0 + sin(time * 2.4 + Double(index) * 0.7) * 2.0
        return CGPoint(
            x: 52.0 + cos(angle) * radius,
            y: 52.0 + sin(angle) * radius
        )
    }

    private func dotIntensity(for index: Int, time: TimeInterval) -> CGFloat {
        let phase = time * 5.0 - Double(index) * 0.72
        return CGFloat((sin(phase) + 1.0) * 0.5)
    }
}

struct SongRowView: View {
    let song: SystemSong
    let isActive: Bool
    let isPlaying: Bool
    var isProcessing: Bool = false
    var artwork: UIImage? = nil
    var trailingText: String? = nil
    var accentColor: Color = Theme.accent
    var overlay: LibraryTrackOverlay? = nil
    var ongakuPlaylists: [OngakuPlaylist] = []
    var onFavoriteChange: ((Bool) -> Void)? = nil
    var onRatingChange: ((Int) -> Void)? = nil
    var onTagsChange: (([String]) -> Void)? = nil
    var onAddToPlaylist: ((UUID) -> Void)? = nil
    @State private var isShowingTrackDetails = false
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.secondaryBackground)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: isPlaying && isActive ? "waveform" : "music.note")
                                .font(.system(size: 14, weight: .thin))
                                .foregroundStyle(isActive ? accentColor : Theme.textSecondary)
                        )
                }
                
                if isProcessing && isActive {
                    ZStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                }
                
                RoundedRectangle(cornerRadius: artwork != nil ? 6 : 8, style: .continuous)
                    .stroke(isActive ? accentColor.opacity(0.6) : Theme.border, lineWidth: 1)
                    .frame(width: 40, height: 40)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                MarqueeView(
                    text: song.title,
                    font: .system(size: 16, weight: .regular),
                    color: isActive ? accentColor : Theme.textPrimary,
                    maxWidth: Theme.maxContentWidth - 88
                )
                
                HStack(spacing: 6) {
                    MarqueeView(
                        text: "\(song.artist) • \(song.album)",
                        font: .system(size: 12, weight: .light),
                        color: Theme.textSecondary,
                        maxWidth: max(120, Theme.maxContentWidth - 170)
                    )

                    Label(song.source.localizedName, systemImage: song.source.systemImageName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(song.source == .ongakuManaged ? accentColor : Theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    song.source == .ongakuManaged
                                        ? accentColor.opacity(0.12)
                                        : Color.white.opacity(0.06)
                                )
                        )
                        .accessibilityLabel(
                            L10n.tr("library.source.accessibility", song.source.localizedName)
                        )
                }

                if let tags = overlay?.displayTags, !tags.isEmpty {
                    Text(tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            Spacer(minLength: 4)

            if let overlay, overlay.isFavorite || overlay.rating > 0 {
                HStack(spacing: 5) {
                    if overlay.isFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(accentColor)
                    }
                    if overlay.rating > 0 {
                        Text("\(overlay.rating)★")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
            }
            if let trailingText {
                Text(trailingText)
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
        }
        .padding(.vertical, 8)
        .frame(width: Theme.maxContentWidth)
        .background(
            Rectangle()
                .fill(isActive ? accentColor.opacity(0.05) : Color.clear)
        )
        .contextMenu {
            Button {
                isShowingTrackDetails = true
            } label: {
                Label(L10n.tr("library.track_info.open"), systemImage: "info.circle")
            }
        }
        .sheet(isPresented: $isShowingTrackDetails) {
            TrackCapabilityDetailView(
                song: song,
                accentColor: accentColor,
                overlay: overlay,
                ongakuPlaylists: ongakuPlaylists,
                onFavoriteChange: onFavoriteChange,
                onRatingChange: onRatingChange,
                onTagsChange: onTagsChange,
                onAddToPlaylist: onAddToPlaylist
            )
        }
    }
}

struct TrackCapabilityDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let song: SystemSong
    var accentColor: Color = Theme.accent
    var overlay: LibraryTrackOverlay? = nil
    var ongakuPlaylists: [OngakuPlaylist] = []
    var onFavoriteChange: ((Bool) -> Void)? = nil
    var onRatingChange: ((Int) -> Void)? = nil
    var onTagsChange: (([String]) -> Void)? = nil
    var onAddToPlaylist: ((UUID) -> Void)? = nil
    @State private var tagsText = ""

    private var availableCapabilities: [LibraryTrackCapability] {
        LibraryTrackCapability.allCases.filter(song.supports)
    }

    private var unavailableCapabilities: [LibraryTrackCapability] {
        LibraryTrackCapability.allCases.filter { !song.supports($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: song.source.systemImageName)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(song.source == .ongakuManaged ? accentColor : Theme.textSecondary)
                            .frame(width: 42, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(song.source == .ongakuManaged
                                        ? accentColor.opacity(0.12)
                                        : Color.white.opacity(0.06))
                            )

                        VStack(alignment: .leading, spacing: 5) {
                            Text(song.title)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.joinedMetadata([song.artist, song.album]))
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)

                    LabeledContent(L10n.tr("library.track_info.source")) {
                        Label(song.source.localizedName, systemImage: song.source.systemImageName)
                            .foregroundStyle(song.source == .ongakuManaged ? accentColor : Theme.textSecondary)
                    }

                    Text(sourceDescription)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if song.supports(.metadataOverlay), let overlay {
                    Section {
                        Toggle(
                            L10n.tr("library.overlay.favorite"),
                            isOn: Binding(
                                get: { overlay.isFavorite },
                                set: { onFavoriteChange?($0) }
                            )
                        )

                        LabeledContent(L10n.tr("library.overlay.rating")) {
                            HStack(spacing: 7) {
                                ForEach(1...5, id: \.self) { rating in
                                    Button {
                                        onRatingChange?(overlay.rating == rating ? 0 : rating)
                                    } label: {
                                        Image(systemName: rating <= overlay.rating ? "star.fill" : "star")
                                            .foregroundStyle(rating <= overlay.rating ? accentColor : Theme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.tr("library.overlay.rating_value", rating))
                                }
                            }
                        }

                        LabeledContent(
                            L10n.tr("library.overlay.play_count"),
                            value: String(overlay.playCount)
                        )
                        LabeledContent(
                            L10n.tr("library.overlay.skip_count"),
                            value: String(overlay.skipCount)
                        )
                        if let lastPlayedAt = overlay.lastPlayedAt {
                            LabeledContent(
                                L10n.tr("library.overlay.last_played"),
                                value: lastPlayedAt.formatted(date: .abbreviated, time: .omitted)
                            )
                        }


                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.tr("library.overlay.tags"))
                                .font(.subheadline.weight(.medium))
                            TextField(L10n.tr("library.overlay.tags.placeholder"), text: $tagsText)
                                .textInputAutocapitalization(.never)
                            Button(L10n.tr("library.overlay.tags.save")) {
                                onTagsChange?(parsedTags)
                            }
                            .disabled(parsedTags == overlay.displayTags)
                        }

                        if song.supports(.addToPlaylist) {
                            if ongakuPlaylists.isEmpty {
                                Text(L10n.tr("library.ongaku_playlist.create_hint"))
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                Menu {
                                    ForEach(ongakuPlaylists) { playlist in
                                        Button(playlist.name) {
                                            onAddToPlaylist?(playlist.id)
                                        }
                                    }
                                } label: {
                                    Label(
                                        L10n.tr("library.ongaku_playlist.add"),
                                        systemImage: "text.badge.plus"
                                    )
                                }
                            }
                        }
                    } header: {
                        Text(L10n.tr("library.overlay.section"))
                    } footer: {
                        Text(L10n.tr("library.overlay.footer"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                capabilitySection(
                    title: L10n.tr("library.track_info.available"),
                    capabilities: availableCapabilities,
                    isAvailable: true
                )

                if !unavailableCapabilities.isEmpty {
                    capabilitySection(
                        title: L10n.tr("library.track_info.restricted"),
                        capabilities: unavailableCapabilities,
                        isAvailable: false
                    )
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(L10n.tr("library.track_info.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(accentColor)
        .onAppear {
            tagsText = overlay?.displayTags.joined(separator: ", ") ?? ""
        }
    }

    private var parsedTags: [String] {
        tagsText
            .split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var sourceDescription: String {
        switch song.source {
        case .systemMusic:
            return L10n.tr("library.track_info.source.music.detail")
        case .ongakuManaged:
            return L10n.tr("library.track_info.source.ongaku.detail")
        }
    }

    private func capabilitySection(
        title: String,
        capabilities: [LibraryTrackCapability],
        isAvailable: Bool
    ) -> some View {
        Section {
            ForEach(capabilities, id: \.self) { capability in
                HStack(spacing: 12) {
                    Image(systemName: capability.systemImageName)
                        .foregroundStyle(isAvailable ? accentColor : Theme.textSecondary)
                        .frame(width: 24)
                    Text(capability.localizedName)
                        .foregroundStyle(isAvailable ? Theme.textPrimary : Theme.textSecondary)
                    Spacer(minLength: 8)
                    Image(systemName: isAvailable ? "checkmark.circle.fill" : "lock.fill")
                        .foregroundStyle(isAvailable ? Color.green : Theme.textSecondary)
                        .accessibilityLabel(
                            isAvailable
                                ? L10n.tr("library.track_info.status.available")
                                : L10n.tr("library.track_info.status.restricted")
                        )
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(title)
        } footer: {
            if !isAvailable {
                Text(L10n.tr("library.track_info.restricted.detail"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AlbumTileView: View {
    let album: SystemAlbum
    let artwork: UIImage?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let artwork {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            Image(uiImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Theme.secondaryBackground)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 30, weight: .thin))
                                .foregroundStyle(Theme.textSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                MarqueeView(
                    text: album.title,
                    font: .system(size: 14, weight: .regular),
                    color: Theme.textPrimary,
                    maxWidth: (Theme.maxContentWidth / 2) - 16
                )
                
                MarqueeView(
                    text: album.artist,
                    font: .system(size: 12, weight: .light),
                    color: Theme.textSecondary,
                    maxWidth: (Theme.maxContentWidth / 2) - 16
                )
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: (Theme.maxContentWidth / 2) - 10)
    }
}

#if DEBUG
struct SongRowView_Previews: PreviewProvider {
    private static let musicSong = SystemSong(
        id: 1,
        title: "Midnight in Shibuya",
        artist: "Aoi Ensemble",
        album: "City Afterglow",
        artistID: 10,
        albumID: 20,
        discNumber: 1,
        trackNumber: 1,
        duration: 248,
        url: nil
    )

    private static let ongakuSong = SystemSong(
        id: UInt64.max,
        title: "A Very Long Track Title for Narrow Screens",
        artist: "Ongaku Sessions",
        album: "Transferred from Mac",
        artistID: nil,
        albumID: nil,
        discNumber: 1,
        trackNumber: 2,
        duration: 312,
        url: URL(fileURLWithPath: "/Documents/Ongaku/preview.flac")
    )

    static var previews: some View {
        Group {
            previewList
                .previewDisplayName("iPhone SE")
                .previewDevice("iPhone SE (3rd generation)")

            previewList
                .previewDisplayName("iPhone 16 Pro Max")
                .previewDevice("iPhone 16 Pro Max")
        }
    }

    private static var previewList: some View {
        VStack(spacing: 0) {
            SongRowView(
                song: musicSong,
                isActive: false,
                isPlaying: false
            )
            SongRowView(
                song: ongakuSong,
                isActive: true,
                isPlaying: true
            )
        }
        .padding(.horizontal, 16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
#endif

struct EffectCard: View {
    let kind: RealtimeAudioEffectKind
    let isEnabled: Bool
    let parameters: [String: Double]
    let isInteractive: Bool
    let onToggle: (Bool) -> Void
    let onParameterChange: (String, Double) -> Void
    let accentColor: Color

    private var exciterMode: ExciterMode {
        ExciterMode.from(parameterValue: parameters["mode"])
    }

    private var exciterOpenTone: ExciterOpenTone {
        ExciterOpenTone.from(parameterValue: parameters["openTone"])
    }

    private var maximizerMode: MaximizerMode {
        MaximizerMode.from(parameterValue: parameters["mode"])
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ヘッダー部分
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.displayName)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.textPrimary)
                    
                    Text(kind.description)
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { isEnabled }, set: onToggle))
                    .toggleStyle(SwitchToggleStyle(tint: accentColor))
                    .labelsHidden()
                    .scaleEffect(0.9)
                    .disabled(!isInteractive)
            }
            
            // パラメータスライダー群
            VStack(alignment: .leading, spacing: 16) {
                let defs = kind.parameterDefinitions
                ForEach(Array(defs.enumerated()), id: \.offset) { index, def in
                    let prevGroup = index > 0 ? defs[index - 1].group : nil
                    
                    if def.group != prevGroup, let groupName = def.group {
                        Text(groupName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accentColor.opacity(0.8))
                            .padding(.top, index > 0 ? 8 : 0)
                            .tracking(1.2)
                    }
                    
                    if kind == .exciter && def.key == "mode" {
                        exciterModeControl(title: def.name)
                    } else if kind == .bbe && def.key == "mode" {
                        maximizerModeControl(title: def.name)
                    } else if kind == .exciter && def.key == "openTone" {
                        exciterOpenToneControl(title: def.name)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(def.name)
                                    .font(.system(size: 12, weight: .light))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                
                                let rawValue = parameters[def.key] ?? def.defaultValue
                                let displayValue: Int = def.isBiPolar ? Int(round((rawValue - 0.5) * 200)) : Int(round(rawValue * 100))
                                let sign = (def.isBiPolar && displayValue > 0) ? "+" : ""
                                
                                Text("\(sign)\(displayValue)")
                                    .font(.system(size: 12, weight: .light, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            
                            Slider(
                                value: Binding(
                                    get: { parameters[def.key] ?? def.defaultValue },
                                    set: { onParameterChange(def.key, $0) }
                                ),
                                in: def.range
                            )
                            .tint(isEnabled ? accentColor : Theme.textSecondary.opacity(0.3))
                            .disabled(!isEnabled || !isInteractive)
                        }
                    }
                }
            }
        }
        .padding(Theme.innerPadding)
        .background(Theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(isEnabled ? accentColor.opacity(0.3) : Theme.border, lineWidth: 1)
        )
        .frame(width: Theme.maxContentWidth)
        .opacity(isInteractive ? (isEnabled ? 1.0 : 0.6) : 0.35)
    }

    private func exciterModeControl(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                ForEach(ExciterMode.allCases) { option in
                    exciterModeButton(for: option)
                }
            }
            .opacity((isEnabled && isInteractive) ? 1.0 : 0.5)
        }
    }

    private func exciterModeButton(for option: ExciterMode) -> some View {
        let isSelected = option == exciterMode
        let textColor: Color = isSelected ? .black : Theme.textPrimary

        return Button {
            onParameterChange("mode", option.parameterValue)
        } label: {
            Text(option.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? accentColor : Theme.secondaryBackground.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? accentColor.opacity(0.95) : Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || !isInteractive)
    }

    private func exciterOpenToneControl(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                ForEach(ExciterOpenTone.allCases) { option in
                    exciterOpenToneButton(for: option)
                }
            }
            .opacity((isEnabled && isInteractive && exciterMode == .open) ? 1.0 : 0.5)
        }
    }

    private func exciterOpenToneButton(for option: ExciterOpenTone) -> some View {
        let isSelected = option == exciterOpenTone
        let textColor: Color = isSelected ? .black : Theme.textPrimary

        return Button {
            onParameterChange("openTone", option.parameterValue)
        } label: {
            Text(option.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? accentColor : Theme.secondaryBackground.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? accentColor.opacity(0.95) : Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || !isInteractive || exciterMode != .open)
    }

    private func maximizerModeControl(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                ForEach(MaximizerMode.allCases) { option in
                    maximizerModeButton(for: option)
                }
            }
            .opacity((isEnabled && isInteractive) ? 1.0 : 0.5)
        }
    }

    private func maximizerModeButton(for option: MaximizerMode) -> some View {
        let isSelected = option == maximizerMode
        let textColor: Color = isSelected ? .black : Theme.textPrimary

        return Button {
            onParameterChange("mode", option.parameterValue)
        } label: {
            Text(option.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? accentColor : Theme.secondaryBackground.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? accentColor.opacity(0.95) : Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || !isInteractive)
    }
}

struct HeadphoneSpatialCard: View {
    let isEnabled: Bool
    let preset: HeadphoneHRTFPreset
    let spatial: Double
    let crossfeed: Double
    let isInteractive: Bool
    let onToggle: (Bool) -> Void
    let onPresetChange: (HeadphoneHRTFPreset) -> Void
    let onParameterChange: (String, Double) -> Void
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("headphone_spatial.title"))
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.textPrimary)

                    Text(L10n.tr("headphone_spatial.description"))
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { isEnabled }, set: onToggle))
                    .toggleStyle(SwitchToggleStyle(tint: accentColor))
                    .labelsHidden()
                    .scaleEffect(0.9)
                    .disabled(!isInteractive)
            }

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("headphone_spatial.parameter.hrtf_preset"))
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(Theme.textSecondary)

                    HStack(spacing: 8) {
                        ForEach(HeadphoneHRTFPreset.allCases, id: \.self) { option in
                            presetButton(for: option)
                        }
                    }
                    .opacity((isEnabled && isInteractive) ? 1.0 : 0.5)
                }

                headphoneSlider(
                    title: L10n.tr("headphone_spatial.parameter.spatial"),
                    value: spatial,
                    key: "spatial"
                )
                headphoneSlider(
                    title: L10n.tr("headphone_spatial.parameter.crossfeed"),
                    value: crossfeed,
                    key: "crossfeed"
                )
            }
        }
        .padding(Theme.innerPadding)
        .background(Theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(isEnabled ? accentColor.opacity(0.3) : Theme.border, lineWidth: 1)
        )
        .frame(width: Theme.maxContentWidth)
        .opacity(isInteractive ? (isEnabled ? 1.0 : 0.6) : 0.35)
    }

    private func headphoneSlider(title: String, value: Double, key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(value * 100))")
                    .font(.system(size: 12, weight: .light, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }

            Slider(
                value: Binding(
                    get: { value },
                    set: { onParameterChange(key, $0) }
                ),
                in: 0...1
            )
            .tint(isEnabled ? accentColor : Theme.textSecondary.opacity(0.3))
            .disabled(!isEnabled || !isInteractive)
        }
    }

    private func hrtfPresetTitle(_ preset: HeadphoneHRTFPreset) -> String {
        switch preset {
        case .natural:
            return L10n.tr("headphone_spatial.hrtf.natural")
        case .frontal:
            return L10n.tr("headphone_spatial.hrtf.frontal")
        case .wide:
            return L10n.tr("headphone_spatial.hrtf.wide")
        case .studio:
            return L10n.tr("headphone_spatial.hrtf.studio")
        }
    }

    private func presetButton(for option: HeadphoneHRTFPreset) -> some View {
        let isSelected = option == preset
        let textColor: Color = isSelected ? .black : Theme.textPrimary
        let backgroundColor: Color = isSelected ? accentColor : Theme.secondaryBackground
        let borderColor: Color = isSelected ? accentColor.opacity(0.35) : Theme.border

        return Button {
            onPresetChange(option)
        } label: {
            Text(hrtfPresetTitle(option))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || !isInteractive)
    }
}
