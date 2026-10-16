import SwiftUI

/// Uses the row/grid cell's actual width, including during iPad window resizing.
struct MarqueeView: View {
    let text: String
    let font: Font
    let color: Color
    var maxWidth: CGFloat = .infinity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    private struct AnimationKey: Equatable {
        let text: String
        let available: CGFloat
        let measured: CGFloat
        let reduceMotion: Bool
    }

    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 0) // The containing row owns its 16 pt gutter.
            .overlay {
                GeometryReader { geometry in
                    let width = min(maxWidth, geometry.size.width)
                    HStack(spacing: 50) {
                        Text(text).font(font).foregroundStyle(color).fixedSize()
                            .background {
                                GeometryReader { measure in
                                    Color.clear
                                        .onAppear { textWidth = measure.size.width }
                                        .onChange(of: measure.size.width) { _, value in textWidth = value }
                                }
                            }
                        if textWidth > width && !reduceMotion {
                            Text(text).font(font).foregroundStyle(color).fixedSize()
                        }
                    }
                    .offset(x: offset)
                    .frame(width: width, height: geometry.size.height, alignment: .leading)
                    .clipped()
                    .task(id: AnimationKey(text: text, available: width, measured: textWidth, reduceMotion: reduceMotion)) {
                        withAnimation(nil) { offset = 0 }
                        guard width > 0, textWidth > width, !reduceMotion else { return }
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        guard !Task.isCancelled else { return }
                        withAnimation(.linear(duration: (textWidth + 50) / 32).repeatForever(autoreverses: false)) {
                            offset = -(textWidth + 50)
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
    }
}
