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
                isDisabled: !player.canGoToPreviousTrack
            ) {
                player.playPreviousTrack()
            }
            
            Spacer(minLength: 4)
            
            // 15秒戻る
            ControlFlatButton(
                iconName: "gobackward.15",
                size: Theme.controlButtonSize,
                isDisabled: !player.hasTrack
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
                isDisabled: !player.hasTrack
            ) {
                player.skip(by: 15)
            }
            
            Spacer(minLength: 4)
            
            // 次の曲へ
            ControlFlatButton(
                iconName: "forward.fill",
                size: Theme.controlButtonSize,
                isDisabled: !player.canGoToNextTrack
            ) {
                player.playNextTrack()
            }
            
            Spacer(minLength: 2)
        }
        .frame(width: Theme.maxContentWidth) // 90%の枠内に物理的に封じ込め
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
                Circle()
                    .stroke(isPressed ? Color.white.opacity(0.3) : Theme.border, lineWidth: 1)
                    .frame(width: size, height: size)
                
                Image(systemName: iconName)
                    .font(.system(size: size * 0.35, weight: .regular))
                    .foregroundStyle(isDisabled ? Theme.textSecondary : Color.white)
            }
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .opacity(isDisabled ? 0.3 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
        .disabled(isDisabled)
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
                Circle()
                    .stroke(isDisabled ? Theme.border : (isVisuallyPlaying ? accentColor.opacity(0.4) : Color.white), lineWidth: 1.5)
                    .frame(width: size, height: size)
                
                Image(systemName: isVisuallyPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.4, weight: .regular))
                    .foregroundStyle(isDisabled ? Theme.textSecondary : (isVisuallyPlaying ? accentColor : Color.white))
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
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
        .disabled(isDisabled)
    }
}
