//
//  Spectrum3DView.swift
//  audio
//
//  3D Waterfall Spectrum Visualizer
//

import SwiftUI

struct Spectrum3DView: View {
    let spectrum: [Float]
    let isPlaying: Bool
    let accentColor: Color
    
    private class History {
        var layers: [[Float]] = []
        var lastUpdateTime: Double = 0
        var wasPlaying = false
    }
    @State private var history = History()
    
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                // 3D視点のチルト（約24度）を与えて、少し斜めから見下ろす印象にする
                let tiltDegrees: CGFloat = 28
                let tiltRadians = tiltDegrees * .pi / 180
                let yScale = cos(tiltRadians)
                context.translateBy(x: size.width * 0.5, y: size.height * 0.56)
                context.scaleBy(x: 1.0, y: yScale)
                context.translateBy(x: -size.width * 0.5, y: -size.height * 0.56)

                let now = timeline.date.timeIntervalSinceReferenceDate
                
                // The analyzer normally publishes about eight FFT snapshots
                // per second. Sampling history at the render frame rate would
                // insert the same snapshot seven or eight times.
                let maxLayers = 24
                let historyInterval = 1.0 / 8.0
                if !isPlaying, history.wasPlaying {
                    history.layers.removeAll(keepingCapacity: true)
                    history.lastUpdateTime = 0
                } else if isPlaying,
                          !spectrum.isEmpty,
                          now - history.lastUpdateTime >= historyInterval {
                    if let firstCount = history.layers.first?.count, firstCount != spectrum.count {
                        history.layers.removeAll(keepingCapacity: true)
                    }
                    history.layers.insert(spectrum, at: 0)
                    if history.layers.count > maxLayers {
                        history.layers.removeLast()
                    }
                    history.lastUpdateTime = now
                }
                history.wasPlaying = isPlaying
                
                drawWaterfall(context: &context, size: size, layers: history.layers, maxLayers: maxLayers)
            }
        }
        .rotation3DEffect(
            .degrees(52),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            perspective: 0.38
        )
        .rotation3DEffect(
            .degrees(9),
            axis: (x: 0, y: 0, z: 1),
            anchor: .center,
            perspective: 0.38
        )
        .scaleEffect(1.15)
        .offset(x: 34, y: 2)
    }
    
    private func drawWaterfall(context: inout GraphicsContext, size: CGSize, layers: [[Float]], maxLayers: Int) {
        let bars = layers.first?.count ?? 0
        guard bars > 0 else { return }
        
        // 奥から手前へ描画（layerIndex が大きいほど奥＝過去）
        for layerIndex in (0..<layers.count).reversed() {
            let layerSpectrum = layers[layerIndex]
            if layerSpectrum.isEmpty { continue }
            let layerBars = min(bars, layerSpectrum.count)
            if layerBars <= 1 { continue }
            let z = CGFloat(layerIndex) / CGFloat(maxLayers - 1) // 0.0(手前) 〜 1.0(一番奥)
            
            // 遠近法（パースペクティブ）の計算：全体をズームアップ
            let zoom: CGFloat = 1.02
            let scale = zoom - (z * 0.34)
            let layerWidth = size.width * scale // 手前は画面幅をはみ出す（カメラが近い表現）
            let startX = (size.width - layerWidth) / 2.0
            
            // Y座標のベース位置（手前は画面下部を少しはみ出し、奥は少し下に下がる）
            let layerY = size.height * 0.98 - z * (size.height * 0.72)
            // 波形の最大高さ（ズームに合わせて高さを強調）
            let maxHeight = size.height * 0.56 * scale
            
            var path = Path()
            path.move(to: CGPoint(x: startX, y: layerY))
            
            for i in 0..<layerBars {
                let dbValue = Double(layerSpectrum[i])
                let normalizedVal = (dbValue + 78.0) / 82.0
                let energyBase = max(0.0, min(1.0, normalizedVal))
                
                let energy = isPlaying ? pow(energyBase, 1.15) : 0.0
                let h = CGFloat(energy) * maxHeight
                
                let x = startX + CGFloat(i) * (layerWidth / CGFloat(layerBars - 1))
                path.addLine(to: CGPoint(x: x, y: layerY - h))
            }
            
            // Fairlight CMI風のシアン・ワイヤーフレーム
            let opacity = 1.0 - (Double(layerIndex) / Double(maxLayers))
            let strokeColor = accentColor.opacity(opacity * 0.90)
            context.stroke(path, with: .color(strokeColor), lineWidth: max(0.75, 1.15 * scale))

            if layerIndex == 0 {
                var glowContext = context
                glowContext.addFilter(.blur(radius: 2.0))
                glowContext.stroke(path, with: .color(accentColor.opacity(0.78)), lineWidth: 1.5)
            }
        }
    }
}
