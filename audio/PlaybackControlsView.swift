//
//  PlaybackControlsView.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var player: AudioPlayerViewModel
    
    var body: some View {
        HStack {
            Spacer(minLength: 2)
            
            // 前の曲へ
            ControlFlatButton(
                iconName: "backward.fill",
                size: Theme.controlButtonSize,
                isDisabled: player.isLoading || !player.canGoToPreviousTrack
            ) {
                player.playPreviousTrack()
            }
            
            Spacer(minLength: 4)
            
            // 15秒戻る
            ControlFlatButton(
                iconName: "gobackward.15",
                size: Theme.controlButtonSize,
                isDisabled: player.isLoading || !player.hasTrack
            ) {
                player.skip(by: -15)
            }
            
            Spacer(minLength: 8)
            
            // 再生 / 停止
            PrimaryControlFlatButton(
                isPlaying: player.isPlaying && !player.isLoading,
                isProcessing: false,
                accentColor: player.accentColor,
                size: Theme.primaryControlButtonSize,
                isDisabled: !player.hasTrack || player.isLoading
            ) {
                player.togglePlayback()
            }
            
            Spacer(minLength: 8)
            
            // 15秒進む
            ControlFlatButton(
                iconName: "goforward.15",
                size: Theme.controlButtonSize,
                isDisabled: player.isLoading || !player.hasTrack
            ) {
                player.skip(by: 15)
            }
            
            Spacer(minLength: 4)
            
            // 次の曲へ
            ControlFlatButton(
                iconName: "forward.fill",
                size: Theme.controlButtonSize,
                isDisabled: player.isLoading || !player.canGoToNextTrack
            ) {
                player.playNextTrack()
            }
            
            Spacer(minLength: 2)
        }
        .frame(maxWidth: Theme.maxContentWidth) // Parent supplies the safe-area gutters.
    }
}

private struct ControlFlatButton: View {
    let iconName: String
    let size: CGFloat
    let isDisabled: Bool
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if Theme.isRealistic {
                    HardwareDial(active: false, isPressed: isPressed, outerInset: 2)
                        .frame(width: size, height: size)
                } else {
                    Circle()
                        .stroke(isPressed ? Theme.textPrimary.opacity(0.3) : Theme.border, lineWidth: 1)
                        .frame(width: size, height: size)
                }
                
                Image(systemName: iconName)
                    .font(.system(size: size * 0.35 * 2 / 3, weight: .regular))
                    .foregroundStyle(isDisabled ? Theme.textSecondary : Theme.textPrimary)
            }
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .opacity(isDisabled ? 0.3 : 1.0)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
        .disabled(isDisabled)
        .accessibilityLabel(L10n.tr("playback.control.\(iconName)"))
    }
}

private struct PrimaryControlFlatButton: View {
    let isPlaying: Bool
    let isProcessing: Bool
    let accentColor: Color
    let size: CGFloat
    let isDisabled: Bool
    let action: () -> Void
    
    @State private var isPressed = false

    private var isVisuallyPlaying: Bool {
        isPlaying || isProcessing
    }
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if Theme.isRealistic {
                    HardwareDial(accent: accentColor, active: !isDisabled, isPressed: isPressed,
                                 isBreathing: isPlaying && !isProcessing && !isDisabled,
                                 outerInset: 2)
                        .frame(width: size, height: size)
                } else {
                    Circle()
                        .stroke(isDisabled ? Theme.border : (isVisuallyPlaying ? accentColor.opacity(0.4) : Theme.textPrimary), lineWidth: 1.5)
                        .frame(width: size, height: size)
                }
                
                Image(systemName: isVisuallyPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.4 * 2 / 3, weight: .regular))
                    .foregroundStyle(isDisabled ? Theme.textSecondary : (isVisuallyPlaying ? accentColor : Theme.textPrimary))
                    .offset(x: isVisuallyPlaying ? 0 : 2)

                if isProcessing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                        .scaleEffect(0.72)
                        .frame(width: size * 0.9, height: size * 0.9)
                }
            }
            .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
        .disabled(isDisabled)
        .accessibilityLabel(L10n.tr(isVisuallyPlaying ? "playback.control.pause" : "playback.control.play"))
    }
}
