import SwiftUI

/// Measured against the uncropped 852 × 1846 pastel assets. All four colorways
/// retain the same window and pivot; the face and needle share this coordinate space.
enum PastelVUMeterGeometry {
    static let sourceSize = CGSize(width: 852, height: 1846)
    static let pivot = CGPoint(x: 426, y: 664)
    static func point(level: Double) -> CGPoint {
        scalePoint(position: PastelVUMeterScale.position(forLevel: level))
    }

    static func scalePoint(position: Double) -> CGPoint {
        CGPoint(x: 218 + 416 * position, y: 516 - 34 * sin(.pi * position))
    }

    static func fitted(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x / sourceSize.width * rect.width,
                y: rect.minY + point.y / sourceSize.height * rect.height)
    }
}

struct PastelVUMeterFace: View {
    let value: Double
    let isPrecisionSinc: Bool
    private let ink = Color(red: 0.27, green: 0.20, blue: 0.24)
    private let overload = Color(red: 0.72, green: 0.23, blue: 0.29)

    var body: some View {
        ZStack {
            Canvas { context, size in
                context.scaleBy(x: size.width / 852, y: size.height / 1846)
                context.draw(Text("#Ongaku").font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(ink), at: CGPoint(x: 426, y: 337))
                context.draw(Text("PROFESSIONAL VU METER").font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.85)), at: CGPoint(x: 426, y: 383))
                let marks = PastelVUMeterScale.marks
                for (a, b) in zip(marks, marks.dropFirst()) {
                    let position = (a.position + b.position) / 2
                    let point = PastelVUMeterGeometry.scalePoint(position: position)
                    var tick = Path()
                    tick.move(to: point); tick.addLine(to: CGPoint(x: point.x, y: point.y - 12))
                    context.stroke(tick, with: .color(a.vu >= 0 ? overload : ink), lineWidth: 1.5)
                }
                for mark in marks {
                    let point = PastelVUMeterGeometry.scalePoint(position: mark.position)
                    let color = mark.vu > 0 ? overload : ink
                    var tick = Path()
                    tick.move(to: point); tick.addLine(to: CGPoint(x: point.x, y: point.y - 25))
                    context.stroke(tick, with: .color(color), lineWidth: mark.vu == 0 ? 4 : 2)
                    let label = mark.vu > 0 ? "+\(mark.vu)" : "\(mark.vu)"
                    context.draw(Text(label).font(.system(size: mark.vu == 0 ? 23 : 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(color), at: CGPoint(x: point.x, y: point.y - 42))
                    if PastelVUMeterScale.secondaryMarks.contains(mark.vu) {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y + 7, width: 4, height: 4)), with: .color(color))
                        context.draw(Text(label).font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(mark.vu == 0 ? overload : ink), at: CGPoint(x: point.x, y: point.y + 25))
                    }
                }
                for positive in [false, true] {
                    let zero = PastelVUMeterScale.position(forLevel: 20.0 / 23)
                    let lower = positive ? zero : 0
                    let upper = positive ? 1 : zero
                    var arc = Path()
                    for step in 0...80 {
                        let point = PastelVUMeterGeometry.scalePoint(position: lower + (upper - lower) * Double(step) / 80)
                        if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
                    }
                    context.stroke(arc, with: .color(positive ? overload : ink),
                                   style: StrokeStyle(lineWidth: positive ? 7 : 3, lineCap: .round))
                }
                context.draw(Text("VU").font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(ink), at: CGPoint(x: 426, y: 579))
                context.draw(Text("dB").font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(ink), at: CGPoint(x: 426, y: 611))
                // The original meter changes illumination for Precision Sinc.
                // Pastel faces keep their finish and expose that state as a tiny lamp.
                let lamp = CGRect(x: 605, y: 331, width: 12, height: 12)
                context.fill(Path(ellipseIn: lamp), with: .color(isPrecisionSinc
                    ? Color(red: 0.22, green: 0.57, blue: 0.39)
                    : Color(red: 0.82, green: 0.47, blue: 0.16)))
            }
            GeometryReader { geometry in
                PastelVUNeedle(value: value)
                    .stroke(ink, style: StrokeStyle(lineWidth: max(0.8, geometry.size.width * 3.8 / 852), lineCap: .round))
                Circle().fill(ink)
                    .frame(width: geometry.size.width * 15 / 852, height: geometry.size.width * 15 / 852)
                    .position(PastelVUMeterGeometry.fitted(PastelVUMeterGeometry.pivot,
                        in: CGRect(origin: .zero, size: geometry.size)))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PastelVUNeedle: Shape {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: PastelVUMeterGeometry.fitted(PastelVUMeterGeometry.pivot, in: rect))
        path.addLine(to: PastelVUMeterGeometry.fitted(PastelVUMeterGeometry.point(level: value), in: rect))
        return path
    }
}

struct PastelVUMeterFace_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview.previewDevice("iPhone SE (3rd generation)")
            preview.previewDevice("iPhone 16 Pro Max")
        }
    }
    private static var preview: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 852, geometry.size.height / 1846)
            Image("VUmeter_pastel_pink").resizable()
                .overlay { PastelVUMeterFace(value: 20.0 / 23, isPrecisionSinc: true) }
                .frame(width: 852 * scale, height: 1846 * scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(.horizontal, 16)
    }
}
