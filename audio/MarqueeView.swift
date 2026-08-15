//
//  MarqueeView.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI

struct MarqueeView: View {
    let text: String
    let font: Font
    let color: Color
    var maxWidth: CGFloat = Theme.maxContentWidth
    
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    
    // スクロール速度（ピクセル/秒）
    private let speed: Double = 32
    // 開始前の待機時間（秒）
    private let delay: Double = 2.0
    
    var body: some View {
        ZStack(alignment: .leading) {
            // サイズ計測用のダミー（非表示）
            Text(text)
                .font(font)
                .lineLimit(1)
                .background(
                    GeometryReader { textGeometry in
                        Color.clear.onAppear {
                            self.textWidth = textGeometry.size.width
                        }
                        .onChange(of: text) {
                            self.textWidth = textGeometry.size.width
                            resetAnimation()
                        }
                    }
                )
                .opacity(0)
            
            // 実際の表示エリア（ここで物理的に幅を 90% に制限する）
            HStack(spacing: 50) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .offset(x: offset)
                
                if textWidth > maxWidth {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .offset(x: offset)
                }
            }
            .frame(width: maxWidth, alignment: .leading)
            .clipped() // 枠外を物理的にカット
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(gradient: Gradient(colors: [.clear, .black]), startPoint: .leading, endPoint: .trailing)
                        .frame(width: textWidth > maxWidth ? 16 : 0)
                    Rectangle().fill(.black)
                    LinearGradient(gradient: Gradient(colors: [.black, .clear]), startPoint: .leading, endPoint: .trailing)
                        .frame(width: textWidth > maxWidth ? 16 : 0)
                }
            )
        }
        .frame(width: maxWidth) // 親コンテナに対しても 90% 幅を強制
        .onAppear {
            if textWidth > maxWidth {
                startAnimation()
            }
        }
    }
    
    private func startAnimation() {
        guard textWidth > maxWidth else { return }
        
        let totalDistance = textWidth + 50 // spacing 50
        let duration = totalDistance / speed
        
        // 遅延を置いて開始
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                offset = -totalDistance
            }
        }
    }
    
    private func resetAnimation() {
        withAnimation(.none) {
            offset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if textWidth > maxWidth {
                startAnimation()
            }
        }
    }
}
