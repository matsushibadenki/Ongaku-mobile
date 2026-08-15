//
//  BlurredBackgroundView.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI

struct BlurredBackgroundView: View {
    let image: UIImage? // 今回はミニマル化のため表示を最小限にする可能性があります
    let isPlaying: Bool
    
    var body: some View {
        ZStack {
            // シックな黒のベース
            Theme.background.ignoresSafeArea()
            
            // フラットかつミニマルにするため、アートワークの裏側の処理を大幅に簡素化
            // 非常に薄い（0.1程度の）ぼかしレイヤーをオプションで残し、真っ暗すぎない質感を出す
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 120)
                    .opacity(0.12) // ほぼ見えない程度
            }
        }
    }
}
