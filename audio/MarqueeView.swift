import SwiftUI

/// Uses the row/grid cell's actual width, including during iPad window resizing.
struct MarqueeView: View {
    let text: String
    let font: Font
    let color: Color
    var maxWidth: CGFloat = .infinity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var textWidth: CGFloat = 0
    @State private var startedAt = Date()
    @State private var isVisible = false

    private struct AnimationKey: Equatable {
        let text: String
        let available: CGFloat
        let measured: CGFloat
        let reduceMotion: Bool
        let isActive: Bool
    }

    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 0) // The containing row owns its 16 pt gutter.
            .overlay {
                GeometryReader { geometry in
                    let width = max(0, min(maxWidth, geometry.size.width))
                    let scrolling = width > 0 && textWidth > width + 0.5 && !reduceMotion
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                            paused: !scrolling || !isVisible || scenePhase != .active)) { timeline in
                        Canvas { context, size in
                            let label = context.resolve(Text(text).font(font).foregroundStyle(color))
                            let measured = label.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
                            if scrolling, measured.width > size.width {
                                let space = context.resolve(Text("   ").font(font))
                                // Three spaces in the same font, bounded on narrow cells so
                                // the viewport can never contain only the separator.
                                let gap = min(space.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width,
                                              size.width * 0.25)
                                let cycle = measured.width + gap
                                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt) - 1.2)
                                let offset = CGFloat(elapsed * 32).truncatingRemainder(dividingBy: cycle)
                                // Draw both copies explicitly. At a cycle boundary the next
                                // copy occupies exactly the first copy's starting position.
                                context.draw(label, at: CGPoint(x: -offset, y: size.height / 2), anchor: .leading)
                                context.draw(label, at: CGPoint(x: cycle - offset, y: size.height / 2), anchor: .leading)
                            } else {
                                context.draw(label, at: CGPoint(x: 0, y: size.height / 2), anchor: .leading)
                            }
                        }
                    }
                    .frame(width: width, height: geometry.size.height)
                    .clipped()
                    .onChange(of: AnimationKey(text: text, available: width, measured: textWidth,
                                               reduceMotion: reduceMotion, isActive: isVisible && scenePhase == .active),
                              initial: true) { _, _ in
                        startedAt = .now
                    }
                }
            }
            .overlay(alignment: .leading) {
                // Measure untruncated text independently of the clipped drawing surface.
                Text(text).font(font).fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .hidden()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
    }
}
