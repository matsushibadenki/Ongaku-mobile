//
//  Spectrum3DView.swift
//  audio
//
//  Luminous waterfall spectrum with a fixed camera and bounded drawing work.
//

import SwiftUI

struct Spectrum3DView: View {
    let spectrum: [Float]
    let isPlaying: Bool
    let accentColor: Color

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private final class History {
        var layers: [[CGFloat]] = []
        var lastUpdateTime: Double = 0

        func reset() {
            layers.removeAll(keepingCapacity: true)
            lastUpdateTime = 0
        }
    }
    @State private var history = History()
    @State private var isVisible = false
    private let maxLayers = 24
    private let historyInterval = 1.0 / 8.0

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? historyInterval : 1.0 / 30.0,
                                paused: !isPlaying || scenePhase != .active || !isVisible)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                // Normalize only on telemetry cadence, not on every rendered frame.
                if isPlaying, isVisible, scenePhase == .active, !spectrum.isEmpty,
                   now - history.lastUpdateTime >= historyInterval {
                    let levels = normalizedLevels(spectrum)
                    if let count = history.layers.first?.count, count != levels.count {
                        history.reset()
                    }
                    history.layers.insert(levels, at: 0)
                    if history.layers.count > maxLayers { history.layers.removeLast() }
                    history.lastUpdateTime = now
                }
                let travel = reduceMotion ? 1 : min(1, max(0, (now - history.lastUpdateTime) / historyInterval))
                drawWaterfall(context: &context, size: size,
                              layers: isPlaying ? history.layers : [], travel: travel, time: now)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            history.reset()
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing { history.reset() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { history.reset() }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func normalizedLevels(_ spectrum: [Float]) -> [CGFloat] {
        // At most 96 frequency samples per layer; retain narrow peaks when reducing bins.
        let count = min(96, spectrum.count)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let start = index * spectrum.count / count
            let end = (index + 1) * spectrum.count / count
            let peak = spectrum[start..<end].filter(\.isFinite).max() ?? -90
            let level = min(1, max(0, Double(peak + 78) / 82))
            return CGFloat(pow(level, 1.15))
        }
    }

    private func drawWaterfall(context: inout GraphicsContext, size: CGSize,
                               layers: [[CGFloat]], travel: Double, time: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let light = Theme.appearance == .light
        let pink = Color(red: 0.94, green: 0.22, blue: 0.48)
        let violet = Color(red: 0.55, green: 0.29, blue: 0.96)
        let blue = Color(red: 0.12, green: light ? 0.48 : 0.67, blue: 0.96)
        let cyan = Color(red: 0.05, green: light ? 0.58 : 0.88, blue: light ? 0.66 : 0.91)
        let palette = [accentColor, pink, violet, blue, cyan]
        let gradient = Gradient(colors: palette)
        let newest = layers.first ?? []
        let peak = newest.max() ?? 0
        let average = newest.isEmpty ? 0 : newest.reduce(0, +) / CGFloat(newest.count)
        let energy = min(1, average * 0.65 + peak * 0.35)

        // Fixed projection: changing signal levels never moves the camera or controls.
        let yaw: CGFloat = 52 * .pi / 180
        let roll: CGFloat = 9 * .pi / 180
        let tilt: CGFloat = cos(28 * .pi / 180)
        let cosYaw = cos(yaw), sinYaw = sin(yaw)
        let cosRoll = cos(roll), sinRoll = sin(roll)
        let depthScale = 0.38 / max(size.width, size.height)
        let project: (CGPoint) -> CGPoint = { point in
            let x = point.x - size.width * 0.5
            let y = (point.y - size.height * 0.5) * tilt
            let turnedX = x * cosYaw
            let depth = -x * sinYaw
            let perspective = 1 / (1 - depth * depthScale)
            return CGPoint(x: (turnedX * cosRoll - y * sinRoll) * perspective,
                           y: (turnedX * sinRoll + y * cosRoll) * perspective)
        }
        let corners = [CGPoint(x: 0.05, y: 0.20), CGPoint(x: 0.95, y: 0.20),
                       CGPoint(x: 0.05, y: 0.88), CGPoint(x: 0.95, y: 0.88)]
            .map { project(CGPoint(x: $0.x * size.width, y: $0.y * size.height)) }
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? size.width
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? size.height
        let fit = min(size.width * 0.86 / (maxX - minX), size.height * 0.86 / (maxY - minY))
        let fittedPoint: (CGPoint) -> CGPoint = { point in
            let projected = project(point)
            return CGPoint(x: (projected.x - (minX + maxX) / 2) * fit + size.width / 2,
                           y: (projected.y - (minY + maxY) / 2) * fit + size.height / 2)
        }
        let baselinePoint: (CGFloat, CGFloat) -> CGPoint = { frequency, depth in
            let width = size.width * (0.9 - depth * 0.34)
            return fittedPoint(CGPoint(x: (size.width - width) / 2 + frequency * width,
                                       y: size.height * (0.88 - depth * 0.44)))
        }

        // Soft light below the spectrum, driven by signal energy rather than a timer.
        let haloCenter = CGPoint(x: size.width * 0.5, y: size.height * 0.59)
        let haloRadius = size.width * 0.48
        context.fill(Path(ellipseIn: CGRect(x: haloCenter.x - haloRadius, y: haloCenter.y - haloRadius,
                                           width: haloRadius * 2, height: haloRadius * 2)),
                     with: .radialGradient(Gradient(colors: [violet.opacity(Double(energy) * (light ? 0.10 : 0.20)), .clear]),
                                           center: haloCenter, startRadius: 0, endRadius: haloRadius))

        var grid = Path()
        for row in 0...6 {
            let depth = CGFloat(row) / 6
            grid.move(to: baselinePoint(0, depth))
            grid.addLine(to: baselinePoint(1, depth))
        }
        for column in 0...8 {
            let frequency = CGFloat(column) / 8
            grid.move(to: baselinePoint(frequency, 0))
            grid.addLine(to: baselinePoint(frequency, 1))
        }
        var floorContext = context
        floorContext.opacity = light ? 0.15 : 0.24
        floorContext.stroke(grid, with: .linearGradient(gradient, startPoint: baselinePoint(0, 0), endPoint: baselinePoint(1, 0)),
                            style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))

        for layerIndex in layers.indices.reversed() {
            let levels = layers[layerIndex]
            guard levels.count > 1 else { continue }
            let z: CGFloat = layerIndex == 0 ? 0 : CGFloat(Double(layerIndex - 1) + travel) / CGFloat(maxLayers - 1)
            let scale = 0.9 - z * 0.34
            let layerWidth = size.width * scale
            let startX = (size.width - layerWidth) / 2
            let layerY = size.height * (0.88 - z * 0.44)
            let maxHeight = size.height * 0.42 * scale
            let points = levels.enumerated().map { index, level in
                fittedPoint(CGPoint(x: startX + CGFloat(index) * layerWidth / CGFloat(levels.count - 1),
                                    y: layerY - level * maxHeight))
            }
            var ridge = Path()
            ridge.addLines(points)
            let start = baselinePoint(0, z), end = baselinePoint(1, z)
            let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: start, endPoint: end)
            let depthOpacity = 1 - Double(z) * 0.80

            // Translucent ribbons give the wireframe volume without hiding older peaks.
            if layerIndex.isMultiple(of: 3) {
                var ribbon = ridge
                ribbon.addLine(to: end)
                ribbon.addLine(to: start)
                ribbon.closeSubpath()
                var fillContext = context
                fillContext.opacity = depthOpacity * (layerIndex == 0 ? (light ? 0.13 : 0.22) : (light ? 0.035 : 0.06))
                fillContext.fill(ribbon, with: shading)
            }

            if layerIndex == 0 {
                // One blurred pass per frame; the remaining history uses crisp strokes.
                var glow = context
                glow.opacity = Double(energy) * (light ? 0.42 : 0.85)
                glow.addFilter(.blur(radius: 3))
                glow.stroke(ridge, with: shading, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            }
            var lineContext = context
            lineContext.opacity = depthOpacity * (layerIndex == 0 ? 1 : (light ? 0.65 : 0.82))
            lineContext.stroke(ridge, with: shading,
                               style: StrokeStyle(lineWidth: layerIndex == 0 ? 1.8 : 0.85, lineJoin: .round))

            if layerIndex == 0, !reduceMotion {
                drawPeakLights(context: &context, points: points, levels: levels,
                               palette: palette, time: time, size: size, light: light)
            }
        }
    }

    private func drawPeakLights(context: inout GraphicsContext, points: [CGPoint], levels: [CGFloat],
                                palette: [Color], time: Double, size: CGSize, light: Bool) {
        guard levels.count > 2 else { return }
        let candidates = (1..<(levels.count - 1)).filter {
            levels[$0] > 0.42 && levels[$0] >= levels[$0 - 1] && levels[$0] > levels[$0 + 1]
        }.sorted { levels[$0] > levels[$1] }
        var selected: [Int] = []
        for index in candidates {
            guard selected.allSatisfy({ abs($0 - index) >= 8 }) else { continue }
            selected.append(index)
            if selected.count == 6 { break }
        }
        for index in selected {
            let phase = (time * 0.45 + Double(index) * 0.173).truncatingRemainder(dividingBy: 1)
            let level = Double(levels[index])
            let point = CGPoint(x: points[index].x + sin(phase * .pi) * 4,
                                y: points[index].y - CGFloat(phase) * min(16, size.height * 0.05))
            let color = palette[min(palette.count - 1, index * palette.count / levels.count)]
            let radius: CGFloat = 1.2 + CGFloat(level) * 0.8
            var sparkle = context
            sparkle.opacity = sin(phase * .pi) * level * (light ? 0.85 : 1)
            sparkle.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.65), .clear]),
                                               center: point, startRadius: 0, endRadius: 6))
            sparkle.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                               width: radius * 2, height: radius * 2)),
                         with: .color(light ? color : .white.opacity(0.95)))
            var rays = Path()
            rays.move(to: CGPoint(x: point.x - 3.5, y: point.y))
            rays.addLine(to: CGPoint(x: point.x + 3.5, y: point.y))
            rays.move(to: CGPoint(x: point.x, y: point.y - 3.5))
            rays.addLine(to: CGPoint(x: point.x, y: point.y + 3.5))
            sparkle.stroke(rays, with: .color(color), lineWidth: 0.6)
        }
    }
}

#if DEBUG
struct Spectrum3DView_Previews: PreviewProvider {
    static var previews: some View {
        ForEach(["iPhone SE (3rd generation)", "iPhone 16 Pro Max"], id: \.self) { device in
            Spectrum3DView(spectrum: (0..<96).map { -65 + 50 * Float(pow(abs(sin(Double($0) * 0.10)), 3)) },
                           isPlaying: true, accentColor: .orange)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 16)
                .background(AppBackground().ignoresSafeArea())
                .previewDevice(PreviewDevice(rawValue: device))
        }
    }
}
#endif
