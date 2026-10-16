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
    static var accent: Color { appearance == .original ? .orange : appearance.palette.signal }
    static let onAccent = Color.black
    static var appearance: AppAppearance { AppearanceSettings.shared.selection }
    static var isRealistic: Bool { appearance.isRealistic }
    static var background: Color { appearance.palette.background }
    static var secondaryBackground: Color { appearance.palette.panel }
    static var border: Color { appearance.palette.edge }
    static var textPrimary: Color { appearance == .original ? .white : appearance.palette.ink }
    static var textSecondary: Color { appearance.palette.secondary }
    
    // MARK: - Dimens
    static let cornerRadius: CGFloat = 16
    static let innerPadding: CGFloat = 24
    
    // Maximum reading width, never a device/screen-sized fixed frame. Views accept
    // their parent's proposed width so iPad windows and rotation remain contained.
    static let maxContentWidth: CGFloat = 760
    static let horizontalPadding: CGFloat = 16
    static let artworkSize: CGFloat = 300

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
            .background(HardwarePanel())
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
        if Theme.isRealistic {
            shape.fill(Theme.appearance.palette.metal)
                .overlay(shape.stroke(Theme.border, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
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
