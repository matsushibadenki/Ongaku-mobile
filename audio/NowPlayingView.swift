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
    var onGoToAlbum: (SystemAlbum) -> Void
    
    @State private var dragOffset: CGSize = .zero
    @State private var dragAxis: Axis? = nil
    @State private var artworkMode: ArtworkMode = .thumbnail
    
    private var canUseVisualizationModes: Bool {
        player.supportsRealtimeEffects
    }
    
    var body: some View {
        ZStack {
            // 背景レイヤー
            if artworkMode == .vuMeter && canUseVisualizationModes {
                ZStack {
                    Color.black.ignoresSafeArea()
                    
                    // アップサンプリングモードに応じたメーター画像
                    Group {
                        if player.upsamplingMode.isPrecisionSinc {
                            Image("VUmeter_green")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Image("VUmeter_orange")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .ignoresSafeArea()
            } else if artworkMode == .classicSpectrum && canUseVisualizationModes {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ClassicSpectrumView(
                        spectrum: player.currentSpectrum,
                        isPlaying: player.isPlaying,
                        accentColor: player.accentColor
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 64)
                    .padding(.bottom, 240)
                }
                .ignoresSafeArea()
            } else if (artworkMode == .spectrum3D || artworkMode == .classicSpectrum) && canUseVisualizationModes {
                Color.black.ignoresSafeArea()
            } else {
                BlurredBackgroundView(image: player.nowPlayingArtwork, isPlaying: player.isPlaying)
                    .ignoresSafeArea()
            }
            
            // VU 針レイヤー (背景の直上、コンテンツの下)
            if artworkMode == .vuMeter && canUseVisualizationModes {
                VUMeterView(value: player.currentVUValue, accentColor: player.accentColor)
                    .ignoresSafeArea()
            }
            
            // コンテンツレイヤー
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                
                // アートワーク
                ArtworkView(
                    image: player.nowPlayingArtwork,
                    isPlaying: player.isPlaying,
                    isLoading: player.isLoading,
                    mode: artworkMode,
                    accentColor: player.accentColor,
                    player: player
                )
                .padding(.bottom, artworkMode == .vuMeter ? 0 : 24)
                    .offset(dragOffset)
                    .opacity(max(0.3, 1.0 - Double(abs(dragOffset.width) + abs(dragOffset.height)) / 300.0))
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                let h = value.translation.width
                                let v = value.translation.height
                                
                                if dragAxis == nil {
                                    dragAxis = abs(h) > abs(v) ? .horizontal : .vertical
                                }
                                
                                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.7)) {
                                    if dragAxis == .horizontal {
                                        dragOffset = CGSize(width: h * 0.7, height: 0)
                                    } else {
                                        dragOffset = CGSize(width: 0, height: v * 0.7)
                                    }
                                }
                            }
                            .onEnded { value in
                                let h = value.translation.width
                                let v = value.translation.height
                                
                                if dragAxis == .horizontal {
                                    if h > 40 {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { player.playNextTrack() }
                                    } else if h < -40 {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { player.playPreviousTrack() }
                                    }
                                } else if dragAxis == .vertical {
                                    if v < -60, let album = player.nowPlayingAlbum {
                                        onGoToAlbum(album)
                                    } else if v > 60, canUseVisualizationModes {
                                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                            let nextRaw = (artworkMode.rawValue + 1) % ArtworkMode.allCases.count
                                            artworkMode = ArtworkMode(rawValue: nextRaw) ?? .thumbnail
                                        }
                                    }
                                }
                                
                                dragAxis = nil
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                    dragOffset = .zero
                                }
                            }
                    )
                
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

                    if let signalSummary = player.playbackSignalSummary {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 10, weight: .semibold))
                            Text(signalSummary)
                                .font(.appCaption())
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
                    }
                }
                .padding(.bottom, 28)
                
                // プログレスバー
                VStack(spacing: 12) {
                    CustomProgressBar(
                        value: Binding(
                            get: { player.progress },
                            set: { player.seek(to: $0) }
                        ),
                        accentColor: player.accentColor
                    )
                    .disabled(!player.hasTrack)
                    .frame(width: Theme.maxContentWidth, height: 12)
                    
                    HStack {
                        Text(player.currentTimeText)
                        Spacer()
                        Text(player.durationText)
                    }
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    .frame(width: Theme.maxContentWidth)
                }
                .padding(.bottom, 32)
                
                // コントロール
                PlaybackControlsView(player: player)
                    .padding(.bottom, 12)

                PlaybackModeButtonsView(player: player)
                    .padding(.bottom, 12)
                
                Spacer(minLength: 24)
                
                if player.canOpenNowPlayingAlbum {
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.textSecondary.opacity(0.3))
                }
                
                Spacer(minLength: 12)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !canUseVisualizationModes {
                artworkMode = .thumbnail
            }
        }
        .onChange(of: player.supportsRealtimeEffects) { _, enabled in
            if !enabled {
                artworkMode = .thumbnail
            }
        }
    }
}

private struct PlaybackModeButtonsView: View {
    @ObservedObject var player: AudioPlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ModeIconButton(
                    iconName: "repeat.1",
                    isActive: player.isSingleTrackRepeatEnabled,
                    isDisabled: !player.hasTrack,
                    accentColor: player.accentColor
                ) {
                    player.toggleSingleTrackRepeat()
                }

                ModeIconButton(
                    iconName: "repeat",
                    isActive: player.isAlbumRepeatEnabled,
                    isDisabled: !player.canUseAlbumScopedPlaybackModes,
                    accentColor: player.accentColor
                ) {
                    player.toggleAlbumRepeat()
                }

                ModeIconButton(
                    iconName: "shuffle",
                    isActive: player.isAlbumShuffleEnabled,
                    isDisabled: !player.canUseAlbumScopedPlaybackModes,
                    accentColor: player.accentColor
                ) {
                    player.toggleAlbumShuffle()
                }

                ModeIconButton(
                    iconName: "shuffle.circle",
                    isActive: player.isLibraryShuffleEnabled,
                    isDisabled: !player.canUseLibraryShuffle,
                    accentColor: player.accentColor
                ) {
                    player.toggleLibraryShuffle()
                }
            }
            .frame(width: Theme.maxContentWidth)
        }
        .frame(width: Theme.maxContentWidth)
    }
}

private struct ModeIconButton: View {
    let iconName: String
    let isActive: Bool
    let isDisabled: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(
                        isActive ? accentColor.opacity(0.55) : Theme.border,
                        lineWidth: 1
                    )
                    .background(
                        Circle()
                            .fill(isActive ? accentColor.opacity(0.16) : Color.clear)
                    )
                    .frame(width: 34, height: 34)

                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        isDisabled
                            ? Theme.textSecondary.opacity(0.5)
                            : (isActive ? accentColor : Theme.textSecondary)
                    )
            }
            .opacity(isDisabled ? 0.35 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct ArtworkView: View {
    let image: UIImage?
    let isPlaying: Bool
    let isLoading: Bool
    let mode: ArtworkMode
    let accentColor: Color
    @ObservedObject var player: AudioPlayerViewModel
    
    var body: some View {
        ZStack {
            switch mode {
            case .thumbnail:
                thumbnailView
            case .vuMeter:
                // レイアウト維持のための透明なスペーサー（ジェスチャー反応のため透明度を極小に設定）
                Color.black.opacity(0.001)
                    .frame(width: Theme.artworkSize, height: Theme.artworkSize)
                    .contentShape(Rectangle())
            case .classicSpectrum:
                // 背景レイヤー表示へ移動したため、ジェスチャー領域のみ維持
                Color.black.opacity(0.001)
                    .frame(width: Theme.artworkSize, height: Theme.artworkSize)
                    .contentShape(Rectangle())
            case .spectrum3D:
                Spectrum3DView(spectrum: player.currentSpectrum, isPlaying: isPlaying, accentColor: accentColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.artworkSize)
            }
            
            if isLoading {
                StartupLoadingIndicator(accentColor: accentColor, showsTitle: false)
            }
        }
        .scaleEffect(isPlaying ? 1.0 : 0.94)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: isPlaying)
    }
    
    private var thumbnailView: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Theme.artworkSize, height: Theme.artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .customShadow(Theme.subtleShadow)
            } else {
                if isLoading {
                    Color.clear
                        .frame(width: Theme.artworkSize, height: Theme.artworkSize)
                } else {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Theme.secondaryBackground)
                        .frame(width: Theme.artworkSize, height: Theme.artworkSize)
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

    private let barCount = 108

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let values = normalizedBars(from: spectrum, count: barCount, isPlaying: isPlaying)
            let spacing: CGFloat = 0.9
            let totalSpacing = spacing * CGFloat(max(0, barCount - 1))
            let horizontalInset: CGFloat = 10
            let availableWidth = max(0, size.width - horizontalInset * 2)
            let barWidth = max(1.2, (availableWidth - totalSpacing) / CGFloat(barCount))
            let mainHeight = size.height * 0.62
            let reflectionHeight = size.height * 0.18
            let maxBarHeight = mainHeight * 1.05
            let spectrumColor = accentColor

            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.96),
                        spectrumColor.opacity(0.08),
                        Color.black.opacity(0.94)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(0..<barCount, id: \.self) { i in
                            let level = values[i]
                            let h = max(2, maxBarHeight * CGFloat(level))
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
                            let h = max(1, reflectionHeight * CGFloat(level))
                            RoundedRectangle(cornerRadius: min(barWidth * 0.5, 3), style: .continuous)
                                .fill(spectrumColor)
                                .frame(width: barWidth, height: h)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .frame(height: reflectionHeight, alignment: .top)
                    .mask(
                        LinearGradient(
                            colors: [Color.white.opacity(0.40), Color.white.opacity(0.20)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.95)
                    .blur(radius: 1.2)
                    .blendMode(.screen)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: -(size.height * 0.02))
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

private struct VUMeterView: View {
    let value: Double
    let accentColor: Color
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // 画像内のメーターの中心位置
            let pivot = CGPoint(x: w * 0.5, y: h * 0.342 + 30)
            let radius = w * 0.24

            ZStack {
                VUNeedle(value: value)
                    .stroke(Color.black, lineWidth: 1.8)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(pivot)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0.5, y: 0.5)
            }
        }
    }
}

private struct VUNeedle: Shape {
    var value: Double
    
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        
        // 画像のスケール角を推定
        // -20dB: 左方向約-50度, +3dB: 右方向約+50度
        let startAngle = -140.0 // 左端
        let endAngle = -40.0   // 右端
        let angle = Angle.degrees(startAngle + value * (endAngle - startAngle))
        
        let end = CGPoint(
            x: center.x + cos(angle.radians) * radius,
            y: center.y + sin(angle.radians) * radius
        )
        
        path.move(to: center)
        path.addLine(to: end)
        return path
    }
}

private struct CustomProgressBar: View {
    @Binding var value: Double
    let accentColor: Color
    
    var body: some View {
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
