import SwiftUI
import UIKit

/// The native slider retains VoiceOver adjustment, cancellation and scroll arbitration.
struct AppearanceSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var accent: Color

    init(value: Binding<Double>, in range: ClosedRange<Double>, accent: Color = Theme.accent) {
        _value = value
        self.range = range
        self.accent = accent
    }

    var body: some View {
        Group {
            if Theme.isRealistic {
                ZStack {
                    Canvas { context, size in
                        var ticks = Path()
                        for index in 0...40 {
                            let x = 14 + (size.width - 28) * CGFloat(index) / 40
                            ticks.move(to: CGPoint(x: x, y: 31))
                            ticks.addLine(to: CGPoint(x: x, y: index.isMultiple(of: 5) ? 38 : 35))
                        }
                        context.stroke(ticks, with: .color(Theme.textSecondary.opacity(0.45)), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
                    HardwareSlider(value: $value, range: range, accent: accent, appearance: Theme.appearance)
                }
                .frame(height: 44)
            } else {
                Slider(value: $value, in: range).tint(accent)
            }
        }
    }
}

private struct HardwareSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accent: Color
    let appearance: AppAppearance
    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject {
        var parent: HardwareSlider
        var appearance: AppAppearance?
        init(_ parent: HardwareSlider) { self.parent = parent }
        @objc func changed(_ sender: UISlider) { parent.value = Double(sender.value) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        if !slider.isTracking { slider.value = Float(value) }
        slider.isEnabled = isEnabled
        slider.minimumTrackTintColor = UIColor(accent)
        slider.maximumTrackTintColor = UIColor(appearance.palette.well)
        if context.coordinator.appearance != appearance {
            context.coordinator.appearance = appearance
            let thumb = thumbImage()
            slider.setThumbImage(thumb, for: .normal)
            slider.setThumbImage(thumb, for: .highlighted)
        }
    }

    private func thumbImage() -> UIImage {
        let p = appearance.palette
        let dark = appearance == .dark
        let face = dark ? UIColor(white: 0.52, alpha: 1) : UIColor(p.panel)
        let highlight = dark ? UIColor(white: 1, alpha: 0.50) : UIColor(p.highlight)
        let grip = dark ? UIColor(white: 0, alpha: 0.55) : UIColor(p.edge)
        let shadow = dark ? UIColor(white: 0, alpha: 0.65) : UIColor(p.shadow)
        let colors = dark
            ? [UIColor(white: 0.66, alpha: 1).cgColor, UIColor(white: 0.40, alpha: 1).cgColor, UIColor(white: 0.56, alpha: 1).cgColor]
            : [UIColor(p.top).cgColor, UIColor(p.bottom).cgColor, UIColor(p.top).cgColor]
        return UIGraphicsImageRenderer(size: CGSize(width: 30, height: 32)).image { renderer in
            let context = renderer.cgContext
            let rect = CGRect(x: 4, y: 3, width: 22, height: 22)
            context.setShadow(offset: CGSize(width: dark ? 1 : 0, height: 2), blur: 3, color: shadow.cgColor)
            context.setFillColor(face.cgColor)
            context.fillEllipse(in: rect)
            context.setShadow(offset: .zero, blur: 0)
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.6, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 5, y: 3), end: CGPoint(x: 25, y: 25), options: [])
            }
            context.restoreGState()
            context.setStrokeColor(highlight.cgColor)
            context.setLineWidth(0.75)
            context.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            context.setStrokeColor(grip.cgColor)
            for x in [12.0, 15.0, 18.0] {
                context.move(to: CGPoint(x: x, y: 10))
                context.addLine(to: CGPoint(x: x, y: 18))
            }
            context.strokePath()
        }
    }
}

struct AppearanceToggleStyle: ToggleStyle {
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        if Theme.isRealistic {
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(Theme.appearance.palette.well)
                        .overlay(Capsule().strokeBorder(Theme.appearance.palette.highlight, lineWidth: 1))
                        .frame(width: 51, height: 28)
                    Circle().fill(Theme.appearance.palette.metal)
                        .overlay(Circle().strokeBorder(Theme.appearance.palette.highlight, lineWidth: 1))
                        .overlay {
                            Circle().fill(configuration.isOn ? accent : Theme.textSecondary)
                                .frame(width: 6, height: 6)
                                .shadow(color: configuration.isOn ? accent : .clear, radius: 4)
                        }
                        .frame(width: 26, height: 26)
                        .shadow(color: Theme.appearance.palette.shadow, radius: 2, x: 0, y: 2)
                        .padding(.horizontal, 1)
                }
                .frame(width: 51, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(HardwareButtonStyle())
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .toggleStyle(.switch)
            }
        } else {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(SwitchToggleStyle(tint: accent))
        }
    }
}
