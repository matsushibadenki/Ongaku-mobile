//
//  Theme.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI
import UIKit

enum Theme {
    // MARK: - Colors
    static let accent = Color.orange
    static let precisionSincAccent = Color(red: 0.68, green: 0.9, blue: 0.1)
    static let background = Color.black
    static let secondaryBackground = Color(white: 0.05)
    static let border = Color.white.opacity(0.12)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    
    // MARK: - Dimens
    static let cornerRadius: CGFloat = 16
    static let innerPadding: CGFloat = 24
    
    // 【最重要】画面幅の90%をコンテンツの限界とする
    static var screenWidth: CGFloat {
        let sceneWidth = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width
        return sceneWidth ?? 390
    }
    static var maxContentWidth: CGFloat { screenWidth * 0.9 }
    
    static let horizontalPadding: CGFloat = (screenWidth * 0.1) / 2 // 左右5%ずつの余白
    static let artworkSize: CGFloat = maxContentWidth * 0.85 // 90%の枠に対してさらに余白
    
    static let controlButtonSize: CGFloat = 48
    static let primaryControlButtonSize: CGFloat = 60 // 少しだけ縮小
    
    // MARK: - Shadows
    static let subtleShadow = Shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
}

extension View {
    func customShadow(_ shadow: Theme.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
    
    func flatCard() -> some View {
        self.padding(Theme.innerPadding)
            .background(Theme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

struct GlassFallbackShape<S: Shape>: View {
    let shape: S
    let fallbackFill: Color
    let cornerRadius: CGFloat

    var body: some View {
        if #available(iOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            shape
                .fill(fallbackFill)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

extension Font {
    static func appTitle() -> Font {
        .system(size: 24, weight: .light, design: .default) // 少し縮小
    }
    
    static func appSubtitle() -> Font {
        .system(size: 15, weight: .regular, design: .default) // 少し縮小
    }
    
    static func appCaption() -> Font {
        .system(size: 11, weight: .regular, design: .monospaced) // 少し縮小
    }
}
