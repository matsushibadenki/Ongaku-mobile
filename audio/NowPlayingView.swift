//
//  NowPlayingView.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI

enum ArtworkMode: Int, CaseIterable {
    case thumbnail, vuMeter, classicSpectrum, spectrum3D
}

struct NowPlayingView: View {
    @ObservedObject var player: AudioPlayerViewModel
    @Binding var artworkMode: ArtworkMode
    var onGoToAlbum: (SystemAlbum) -> Void
    var onSwipeUpToAlbum: (SystemAlbum) -> Void
    var vuScreenFrame: CGRect = .zero
    
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.5, dampingFraction: 0.7)))
    private var dragTranslation: CGSize = .zero

    private var dragOffset: CGSize {
        abs(dragTranslation.width) > abs(dragTranslation.height)
            ? CGSize(width: dragTranslation.width * 0.7, height: 0)
            : CGSize(width: 0, height: dragTranslation.height * 0.7)
    }
    
    var body: some View {
        ZStack {
            if artworkMode == .vuMeter {
                GeometryReader { geometry in
                    let localFrame = geometry.frame(in: .global)
                    let screenFrame = vuScreenFrame.isEmpty ? localFrame : vuScreenFrame
                    NowPlayingVUBackground(player: player)
                        .frame(width: screenFrame.width, height: screenFrame.height)
                        .offset(x: screenFrame.minX - localFrame.minX, y: screenFrame.minY - localFrame.minY)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else {
                BlurredBackgroundView(image: artworkMode == .thumbnail ? player.nowPlayingArtwork : nil,
                                      isPlaying: player.isPlaying)
                    .ignoresSafeArea()
            }

            // Keep every control reachable on compact screens and larger text sizes.
            GeometryReader { geometry in
                // The root stack excludes the fixed transport and menu from this viewport.
                let contentHeight = max(0, geometry.size.height)
                let compact = contentHeight < 650
                ScrollView(.vertical, showsIndicators: false) {
                    NowPlayingContentLayout(availableHeight: contentHeight, artworkSpacing: compact ? 12 : 24) {
                        // アートワーク
                        GeometryReader { artworkGeometry in
                            ArtworkView(
                                image: player.nowPlayingArtwork,
                                isPlaying: player.isPlaying,
                                isLoading: player.isLoading,
                                mode: artworkMode,
                                accentColor: player.accentColor,
                                player: player,
                                size: artworkGeometry.size.width,
                                titleGap: max(0, artworkGeometry.size.height - artworkGeometry.size.width)
                            )
                            .offset(dragOffset)
                            .opacity(max(0.3, 1.0 - Double(abs(dragOffset.width) + abs(dragOffset.height)) / 300.0))
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 10)
                                    .updating($dragTranslation) { value, translation, _ in
                                        translation = value.translation
                                    }
                                    .onEnded { value in
                                        let h = value.translation.width
                                        let v = value.translation.height
                                        // Read this gesture's final direction. A drag cancelled
                                        // by an app switch must not lock the next gesture's axis.
                                        if abs(h) > abs(v) {
                                            guard !player.isLoading else { return }
                                            if h > 40 { player.playNextTrack() }
                                            else if h < -40 { player.playPreviousTrack() }
                                        } else if v < -60, let album = player.nowPlayingAlbum {
                                            onSwipeUpToAlbum(album)
                                        } else if v > 60 {
                                            // Display selection remains available on the system route
                                            // and while the local audio engine is preparing.
                                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                                let nextRaw = (artworkMode.rawValue + 1) % ArtworkMode.allCases.count
                                                artworkMode = ArtworkMode(rawValue: nextRaw) ?? .thumbnail
                                            }
                                        }
                                    }
                            )
                            .accessibilityAction(named: Text(L10n.tr("library.albums"))) {
                                if let album = player.nowPlayingAlbum { onGoToAlbum(album) }
                            }
                        }

                        VStack(spacing: 0) {
                            // トラック情報
                            VStack(spacing: 12) {
                                MarqueeView(
                                    text: player.nowPlayingDisplayTitle,
                                    font: .appTitle(),
                                    color: Theme.textPrimary
                                )

                                MarqueeView(
                                    text: player.nowPlayingDisplaySubtitle,
                                    font: .appSubtitle(),
                                    color: Theme.textSecondary
                                )

                                HStack(spacing: 8) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(player.playbackSignalSummary ?? " ")
                                        .font(.appCaption())
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                .foregroundStyle(player.accentColor.opacity(0.95))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    GlassFallbackShape(
                                        shape: Capsule(style: .continuous),
                                        fallbackFill: player.accentColor.opacity(0.12),
                                        cornerRadius: 100
                                    )
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(player.accentColor.opacity(0.24), lineWidth: 0.5)
                                )
                                // Keep this slot during preparation and for sources without DSP details.
                                .opacity(player.playbackSignalSummary == nil ? 0 : 1)
                                .accessibilityHidden(player.playbackSignalSummary == nil)
                            }
                            .padding(.bottom, compact ? 16 : 28)

                            // プログレスバー
                            VStack(spacing: 0) {
                                CustomProgressBar(
                                    value: Binding(
                                        get: { player.progress },
                                        set: {
                                            guard !player.isLoading, player.hasTrack else { return }
                                            player.seek(to: $0)
                                        }
                                    ),
                                    accentColor: player.accentColor
                                )
                                .disabled(player.isLoading || !player.hasTrack)
                                .allowsHitTesting(!player.isLoading && player.hasTrack)
                                .opacity(player.isLoading ? 0.35 : 1)
                                .frame(height: Theme.isRealistic ? 44 : 12)
                                .frame(maxWidth: Theme.maxContentWidth)

                                HStack {
                                    Text(player.currentTimeText)
                                    Spacer()
                                    Text(player.durationText)
                                }
                                .font(.appCaption())
                                .foregroundStyle(Theme.isRealistic ? Theme.textSecondary : Theme.textSecondary.opacity(0.6))
                                .frame(maxWidth: Theme.maxContentWidth)
                                .overlay {
                                    Image(systemName: "chevron.compact.up")
                                        .font(.system(size: 16, weight: .thin))
                                        .foregroundStyle(Theme.textSecondary.opacity(0.3))
                                        .opacity(player.canOpenNowPlayingAlbum ? 1 : 0)
                                        .accessibilityHidden(true)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: Theme.maxContentWidth)
                    .padding(.horizontal, Theme.horizontalPadding)
                }
            }
        }
        .preferredColorScheme(Theme.appearance.colorScheme)
    }
}

/// Measures the controls first, then gives the artwork the remaining space.
/// The bottom controls stay anchored; short screens can still scroll.
private struct NowPlayingContentLayout: Layout {
    var availableHeight: CGFloat
    var artworkSpacing: CGFloat
    private let topInset: CGFloat = 12
    private let bottomInset: CGFloat = 0

    private func dimensions(width: CGFloat, subviews: Subviews) -> (artwork: CGFloat, details: CGFloat, height: CGFloat) {
        let details = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let reserved = topInset + artworkSpacing + details + bottomInset
        let artwork = min(width, max(112, availableHeight - reserved))
        return (artwork, details, max(availableHeight, artwork + reserved))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? Theme.maxContentWidth)
        return CGSize(width: width, height: dimensions(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = dimensions(width: bounds.width, subviews: subviews)
        let artworkRegionHeight = bounds.height - topInset - bottomInset - sizes.details
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.minY + topInset), anchor: .top,
                          proposal: ProposedViewSize(width: sizes.artwork, height: artworkRegionHeight))
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.maxY - bottomInset), anchor: .bottom,
                          proposal: ProposedViewSize(width: bounds.width, height: sizes.details))
    }
}

struct PlaybackModeButtonsView: View {
    @ObservedObject var player: AudioPlayerViewModel
    var onLyrics: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 2) {
                ModeIconButton(
                    iconName: "repeat.1",
                    isActive: player.isSingleTrackRepeatEnabled,
                    isDisabled: player.isLoading || !player.hasTrack,
                    accentColor: player.accentColor
                ) {
                    player.toggleSingleTrackRepeat()
                }

                ModeIconButton(
                    iconName: "repeat",
                    isActive: player.isAlbumRepeatEnabled,
                    isDisabled: player.isLoading || !player.canUseAlbumScopedPlaybackModes,
                    accentColor: player.accentColor
                ) {
                    player.toggleAlbumRepeat()
                }

                ModeIconButton(
                    iconName: "shuffle",
                    scopeIconName: "opticaldisc",
                    isActive: player.isAlbumShuffleEnabled,
                    isDisabled: player.isLoading || !player.canUseAlbumScopedPlaybackModes,
                    accentColor: player.accentColor
                ) {
                    player.toggleAlbumShuffle()
                }
                .accessibilityLabel(L10n.tr("playback.shuffle.album"))
                .help(L10n.tr("playback.shuffle.album"))

                ModeIconButton(
                    iconName: "shuffle",
                    scopeIconName: "square.stack",
                    isActive: player.isLibraryShuffleEnabled,
                    isDisabled: player.isLoading || !player.canUseLibraryShuffle,
                    accentColor: player.accentColor
                ) {
                    player.toggleLibraryShuffle()
                }
                .accessibilityLabel(L10n.tr("playback.shuffle.library"))
                .help(L10n.tr("playback.shuffle.library"))
                ModeIconButton(
                    iconName: "text.quote", isActive: false,
                    isDisabled: player.isLoading || player.lyricsPlaybackSong == nil, accentColor: player.accentColor,
                    action: onLyrics
                )
                .accessibilityLabel(L10n.tr("lyrics.title"))
            }
            .frame(maxWidth: Theme.maxContentWidth)
        }
        .frame(maxWidth: Theme.maxContentWidth)
    }
}

private struct ModeIconButton: View {
    let iconName: String
    var scopeIconName: String? = nil
    let isActive: Bool
    let isDisabled: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if let scopeIconName {
                    Image(systemName: scopeIconName)
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 10)
                }
                Image(systemName: iconName)
                    .font(.system(size: scopeIconName == nil ? 11 : 9, weight: .medium))
            }
                .foregroundStyle(
                    isDisabled
                        ? Theme.textSecondary.opacity(0.5)
                        : (isActive ? accentColor : Theme.textSecondary)
                )
                .frame(width: 30, height: 28)
                .background { if Theme.isRealistic { HardwarePanel(radius: 8) } }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .opacity(isDisabled ? 0.35 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct ArtworkView: View {
    let image: UIImage?
    let isPlaying: Bool
    let isLoading: Bool
    let mode: ArtworkMode
    let accentColor: Color
    @ObservedObject var player: AudioPlayerViewModel
    var size: CGFloat = Theme.artworkSize
    var titleGap: CGFloat = 0

    private var displayHeight: CGFloat {
        size + (mode == .classicSpectrum ? max(0, titleGap - 8) : 0)
    }

    private var isVisualizing: Bool {
        isPlaying && player.supportsRealtimeEffects
    }
    
    var body: some View {
        ZStack {
            switch mode {
            case .thumbnail:
                thumbnailView
            case .vuMeter:
                // The root renders VU behind the entire screen; retain the swipe area here.
                Color.clear.frame(width: size, height: size)
            case .classicSpectrum:
                ClassicSpectrumView(spectrum: player.currentSpectrum, isPlaying: isVisualizing,
                                    accentColor: accentColor, titleGap: titleGap)
                    .frame(width: size, height: displayHeight)
            case .spectrum3D:
                Spectrum3DView(spectrum: player.currentSpectrum, isPlaying: isVisualizing, accentColor: accentColor)
                    .frame(width: size, height: size)
            }
            
            if isLoading {
                StartupLoadingIndicator(accentColor: accentColor, showsTitle: false)
            }
        }
        .frame(width: size, height: displayHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .scaleEffect(mode == .thumbnail && !isPlaying ? 0.94 : 1.0)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: isPlaying)
    }
    
    private var thumbnailView: some View {
        let thumbnailSize = size * 0.85
        return Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbnailSize, height: thumbnailSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .customShadow(Theme.subtleShadow)
            } else {
                if isLoading {
                    Color.clear
                        .frame(width: thumbnailSize, height: thumbnailSize)
                } else {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Theme.secondaryBackground)
                        .frame(width: thumbnailSize, height: thumbnailSize)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 70, weight: .thin))
                                .foregroundStyle(Theme.textSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                }
            }
        }
    }
    
}

private struct ClassicSpectrumView: View {
    let spectrum: [Float]
    let isPlaying: Bool
    let accentColor: Color
    var titleGap: CGFloat = 0

    private let barCount = 108

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let values = normalizedBars(from: spectrum, count: barCount, isPlaying: isPlaying)
            let horizontalInset: CGFloat = 10
            let availableWidth = max(0, size.width - horizontalInset * 2)
            let spacing = min(0.9, availableWidth / CGFloat(barCount * 3))
            let totalSpacing = spacing * CGFloat(max(0, barCount - 1))
            let barWidth = max(0, (availableWidth - totalSpacing) / CGFloat(barCount))
            // Halve the old baseline-to-title gap, including space below the square.
            // Double the previous 0.62-height gain, capping peaks inside the viewport.
            // Keep the original square's bar geometry while extending only the reflection
            // into the space above the title. The parent reserves 8 pt of clearance.
            let squareHeight = size.width
            let topInset = squareHeight * 0.02
            let baseline = min(squareHeight * 0.98, squareHeight * 0.86 + titleGap * 0.5)
            let mainHeight = baseline - topInset
            let reflectionHeight = max(0, size.height - baseline)
            let maxBarHeight = squareHeight * 1.24
            let spectrumColor = accentColor

            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        .clear,
                        spectrumColor.opacity(0.08),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(0..<barCount, id: \.self) { i in
                            let level = values[i]
                            let h = max(2, min(mainHeight, maxBarHeight * CGFloat(level)))
                            RoundedRectangle(cornerRadius: min(barWidth * 0.5, 3), style: .continuous)
                                .fill(spectrumColor)
                                .overlay(
                                    RoundedRectangle(cornerRadius: min(barWidth * 0.5, 3), style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                                )
                                .frame(width: barWidth, height: h)
                                .shadow(color: spectrumColor.opacity(0.24), radius: 3, x: 0, y: 0)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .frame(height: mainHeight, alignment: .bottom)

                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<barCount, id: \.self) { i in
                            let level = values[i]
                            let barHeight = max(2, min(mainHeight, maxBarHeight * CGFloat(level)))
                            let h = reflectionHeight * barHeight / max(1, mainHeight)
                            RoundedRectangle(cornerRadius: min(barWidth * 0.5, 3), style: .continuous)
                                .fill(spectrumColor)
                                .frame(width: barWidth, height: h)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .frame(height: reflectionHeight, alignment: .top)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.44), location: 0),
                                .init(color: .white.opacity(0.26), location: 0.5),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.95)
                    .blur(radius: 1.2)
                }
                .padding(.top, topInset)
                .frame(width: size.width, height: size.height, alignment: .top)
            }
        }
    }

    private func normalizedBars(from spectrum: [Float], count: Int, isPlaying: Bool) -> [Double] {
        guard count > 0 else { return [] }
        guard isPlaying, !spectrum.isEmpty else { return Array(repeating: 0.03, count: count) }

        // The analyzer already supplies logarithmic 20 Hz–20 kHz bands.
        let filtered = spectrum

        var bars: [Double] = []
        bars.reserveCapacity(count)
        let n = filtered.count

        for i in 0..<count {
            let position = Double(i) / Double(max(1, count - 1))
            // 解析側がすでに20Hz〜20kHzの対数バンドなので、表示側では過剰な低域寄せをしない
            let center = Int(position * Double(max(0, n - 1)))
            let halfWindow = max(1, n / (count * 2))
            let start = max(0, center - halfWindow)
            let end = min(n, center + halfWindow + 1)
            if end <= start {
                bars.append(0.02)
                continue
            }

            let slice = filtered[start..<end]
            // dB is logarithmic. Combine neighboring bars in linear power,
            // then convert the result back to dB for display shaping.
            var powerSum: Float = 0
            var peakPower: Float = 0
            for db in slice {
                let power = pow(10, db / 10)
                powerSum += power
                peakPower = max(peakPower, power)
            }
            let averagePower = powerSum / Float(slice.count)
            let mixedPower = averagePower * 0.60 + peakPower * 0.40
            let mixedDB = mixedPower > 0 ? 10 * log10(mixedPower) : -120
            let normalized = max(0.0, min(1.0, Double((mixedDB + 82.0) / 82.0)))

            let shaped = pow(normalized, 1.14)
            bars.append(max(0.02, min(1.0, shaped * 0.90 + 0.02)))
        }

        return bars
    }
}

// MARK: - Visualization Components

/// Observes meter telemetry independently of the root navigation view.
struct NowPlayingVUBackground: View {
    @ObservedObject var player: AudioPlayerViewModel

    var body: some View {
        ZStack {
            HardwareSurface()
            VUMeterView(value: player.supportsRealtimeEffects ? player.currentVUValue : 0,
                        isPrecisionSinc: player.upsamplingMode.isPrecisionSinc)
            if Theme.appearance == .light {
                // Blend only the empty studio backdrop into the app finish.
                // The meter housing and face remain fully visible and uncropped.
                HardwareSurface()
                    .mask(LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .clear, location: 0.075),
                        .init(color: .clear, location: 0.45),
                        .init(color: .white, location: 0.62)
                    ], startPoint: .top, endPoint: .bottom))
            } else {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.44),
                    .init(color: Theme.background.opacity(0.82), location: 0.54),
                    .init(color: Theme.background.opacity(0.90), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct VUMeterView: View {
    let value: Double
    let isPrecisionSinc: Bool

    // Fit the entire portrait asset, without cropping or changing its aspect ratio.
    // The needle uses the same fitted image coordinates, including letterboxing.
    var body: some View {
        GeometryReader { geometry in
            let light = Theme.appearance == .light
            let sourceSize = light ? CGSize(width: 852, height: 1846) : CGSize(width: 1170, height: 2532)
            let scale = min(geometry.size.width / sourceSize.width, geometry.size.height / sourceSize.height)
            let assetName = (isPrecisionSinc ? "VUmeter_green" : "VUmeter_orange") + (light ? "_light" : "")
            Image(assetName)
                .resizable()
                .frame(width: sourceSize.width * scale, height: sourceSize.height * scale)
                .overlay {
                    VUNeedle(value: value)
                        .stroke(.black, style: StrokeStyle(lineWidth: max(0.75, sourceSize.width * scale * (5.1 / 1170)), lineCap: .round))
                        .shadow(color: .black.opacity(0.15), radius: 1, x: 0.5, y: 0.5)
                }
                .mask {
                    if light {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.07),
                            .init(color: .white, location: 0.93),
                            .init(color: .clear, location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                    } else {
                        Color.white
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }
}

private struct VUNeedle: Shape {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Normalized coordinates from the complete original asset; the generated
        // Light variants preserve the same pivot and scale positions.
        let level = value.isFinite ? min(1, max(0, value)) : 0
        let pivot = CGPoint(x: rect.minX + rect.width * (585.0 / 1170),
                            y: rect.minY + rect.height * (961.0 / 2532))
        let tip = CGPoint(x: rect.minX + rect.width * ((304.5 + 561 * level) / 1170),
                          y: rect.minY + rect.height * ((746.8 - 40.8 * sin(.pi * level)) / 2532))
        var path = Path()
        path.move(to: pivot)
        path.addLine(to: tip)
        return path
    }
}

private struct CustomProgressBar: View {
    @Binding var value: Double
    let accentColor: Color
    
    var body: some View {
        if Theme.isRealistic {
            AppearanceSlider(value: $value, in: 0...1, accent: accentColor)
                .accessibilityLabel(L10n.tr("appearance.playback_position"))
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // 背景レール
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 2)

                    // プログレス
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: geometry.size.width * CGFloat(max(0, min(value, 1))), height: 2)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let newValue = Double(max(0, min(gesture.location.x / geometry.size.width, 1)))
                            value = newValue
                        }
                )
            }
        }
    }
}
