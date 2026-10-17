//
//  BlurredBackgroundView.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI

struct BlurredBackgroundView: View {
    let image: UIImage?
    let isPlaying: Bool
    
    var body: some View {
        AppBackground()
            .overlay {
                // Aspect-fill artwork must not determine the player's layout size.
                // A square cover filling a tall screen otherwise widens the ZStack.
                GeometryReader { geometry in
                    if let image, !Theme.isRealistic {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: 120)
                            .opacity(0.12)
                    }
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
