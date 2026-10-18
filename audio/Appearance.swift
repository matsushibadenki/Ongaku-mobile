import SwiftUI
import Observation

// Hallmark · tactile audio hardware · silver / graphite, amber indicators.
// Pre-emit critique: Philosophy 4, Hierarchy 4, Execution 4, Specificity 5, Restraint 4, Variety 4.
enum AppAppearance: String, CaseIterable, Identifiable {
    case original, light, dark, pink, purple, green, beige
    var id: String { rawValue }
    var title: String { L10n.tr("appearance.\(rawValue)") }
    var isPastel: Bool { [.pink, .purple, .green, .beige].contains(self) }
    var isLight: Bool { self == .light || isPastel }
    var colorScheme: ColorScheme { isLight ? .light : .dark }
    var pastelHex: UInt32? {
        switch self {
        case .pink: 0xfbeefa
        case .purple: 0xeeecfe
        case .green: 0xe1fff4
        case .beige: 0xfaf7e3
        default: nil
        }
    }
    var isRealistic: Bool { self != .original }
    var palette: HardwarePalette { HardwarePalette(appearance: self) }
}

@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()
    static let storageKey = "interface.appearance"
    var selection: AppAppearance {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        selection = AppAppearance(rawValue: UserDefaults.standard.string(forKey: Self.storageKey) ?? "") ?? .original
    }
}

struct HardwarePalette {
    let appearance: AppAppearance
    private var light: Bool { appearance.isLight }
    private func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    private var pastel: Color? { appearance.pastelHex.map(rgb) }
    // White finishes use #f4f4f4 / #fbfbfb / #ffffff. Graphite keeps
    // its compact tonal range, with true black reserved for recessed details.
    var background: Color { pastel ?? (light ? Color(white: 244.0 / 255) : (appearance == .original ? .black : Color(white: 0.10))) }
    var panel: Color { pastel ?? (light ? Color(white: 251.0 / 255) : Color(white: appearance == .original ? 0.05 : 0.115)) }
    var top: Color { light ? .white : Color(white: 0.15) }
    var bottom: Color { pastel ?? (light ? Color(white: 244.0 / 255) : Color(white: 0.09)) }
    var ink: Color { light ? Color(white: 0.13) : Color(white: 0.82) }
    var secondary: Color { light ? Color(white: 0.32) : (appearance == .original ? Color.white.opacity(0.55) : Color(white: 0.65)) }
    var edge: Color { light ? Color.black.opacity(0.14) : Color.white.opacity(appearance == .original ? 0.12 : 0.08) }
    var highlight: Color { Color.white.opacity(light ? 0.28 : 0.07) }
    var shadow: Color { Color.black.opacity(light ? 0.12 : 0.22) }
    var well: Color { appearance.isPastel ? signal.opacity(0.13) : (light ? Color(white: 0.60) : .black) }
    var signal: Color {
        switch appearance {
        case .pink: rgb(0xa83f79)
        case .purple: rgb(0x7051b4)
        case .green: rgb(0x24765b)
        case .beige: rgb(0x856122)
        case .original: .orange
        case .light: Color(red: 1, green: 121.0 / 255, blue: 0)
        case .dark: Color(red: 1, green: 138.0 / 255, blue: 28.0 / 255)
        }
    }
    var metal: LinearGradient {
        LinearGradient(colors: [top, panel, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // One upper-left light source: raised edges catch light, recessed edges
    // reverse it, and the contact shadow falls toward the lower right.
    var raisedEdge: LinearGradient {
        LinearGradient(stops: [
            .init(color: .white.opacity(light ? 0.9 : 0.22), location: 0),
            .init(color: highlight, location: 0.38),
            .init(color: .black.opacity(light ? 0.08 : 0.35), location: 0.62),
            .init(color: .black.opacity(light ? 0.22 : 0.65), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var recessedEdge: LinearGradient {
        LinearGradient(colors: [.black.opacity(light ? 0.24 : 0.8), highlight],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var contactShadow: Color { .black.opacity(light ? 0.18 : 0.55) }
}

/// A tiny cached tile replaces repeated full-screen path construction.
private enum HardwareTexture {
    static let light = makeTile(ink: UIColor.black)
    static let dark = makeTile(ink: UIColor.white)

    static func image(for appearance: AppAppearance) -> UIImage {
        appearance.isLight ? light : dark
    }

    private static func makeTile(ink: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { renderer in
            ink.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
        }
    }
}

struct HardwareSurface: View {
    var appearance: AppAppearance = Theme.appearance
    var body: some View {
        let p = appearance.palette
        ZStack {
            p.background
            if appearance == .light {
                LinearGradient(stops: [
                    .init(color: p.background, location: 0),
                    .init(color: p.panel, location: 0.45),
                    .init(color: .white, location: 1)
                ], startPoint: .bottomTrailing, endPoint: .topLeading)
            } else if appearance == .dark {
                LinearGradient(colors: [p.highlight.opacity(0.18), .clear, p.shadow.opacity(0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(uiImage: HardwareTexture.image(for: appearance))
                    .resizable(resizingMode: .tile)
                    .opacity(0.012)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AppBackgroundFrameKey: EnvironmentKey {
    static let defaultValue: CGRect = .zero
}

extension EnvironmentValues {
    var appBackgroundFrame: CGRect {
        get { self[AppBackgroundFrameKey.self] }
        set { self[AppBackgroundFrameKey.self] = newValue }
    }
}

/// Navigation, tab content and fixed controls share one screen-space finish.
/// Each opaque container can cover its backing without restarting the gradient.
struct AppBackground: View {
    @Environment(\.appBackgroundFrame) private var screenFrame

    var body: some View {
        GeometryReader { geometry in
            let localFrame = geometry.frame(in: .global)
            let frame = screenFrame.isEmpty ? localFrame : screenFrame
            HardwareSurface()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX - localFrame.minX, y: frame.minY - localFrame.minY)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct HardwarePanel: View {
    var radius: CGFloat = Theme.cornerRadius
    var body: some View {
        let p = Theme.appearance.palette
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.isRealistic ? p.metal : LinearGradient(colors: [p.panel], startPoint: .top, endPoint: .bottom))
            .overlay {
                if Theme.isRealistic {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(p.raisedEdge, lineWidth: 1)
                }
            }
            .shadow(color: Theme.isRealistic ? p.shadow.opacity(0.45) : .clear, radius: 5, x: 2, y: 3)
    }
}

struct HardwareDial: View {
    var appearance: AppAppearance = Theme.appearance
    var accent: Color = Theme.accent
    var active = true
    var isPressed = false
    var isBreathing = false
    var outerInset: CGFloat = 0
    var body: some View {
        let p = appearance.palette
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(p.well)
                    .overlay(Circle().strokeBorder(p.recessedEdge, lineWidth: 1))
                    .padding(outerInset)
                HardwareIlluminatedRing(color: active ? accent : p.edge,
                                        active: active, isBreathing: isBreathing)
                    .padding(5)
                Circle().fill(p.metal)
                    .overlay(Circle().strokeBorder(p.raisedEdge, lineWidth: 1.25))
                    .padding(size * 0.14)
                    .shadow(color: p.contactShadow, radius: isPressed ? 1 : 2,
                            x: isPressed ? 0.5 : 2, y: isPressed ? 0.5 : 3)
                    .offset(x: isPressed ? 0.5 : 0, y: isPressed ? 0.5 : 0)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Animate only the illuminated ring; the dial face, symbols and layout stay still.
private struct HardwareIlluminatedRing: View {
    let color: Color
    let active: Bool
    let isBreathing: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ring: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .shadow(color: active ? color.opacity(0.18) : .clear, radius: 2)
    }

    var body: some View {
        if isBreathing && active && scenePhase == .active && !reduceMotion {
            ring.phaseAnimator([false, true]) { content, bright in
                content
                    .opacity(bright ? 1 : 0.55)
                    .brightness(bright ? 0.08 : 0)
            } animation: { _ in
                .easeInOut(duration: 1.8)
            }
        } else {
            ring
        }
    }
}

struct HardwareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
    }
}

struct AppearanceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsInfo = false
    @State private var sampleLevel = 0.62
    @State private var samplePower = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(AppAppearance.allCases) { appearance in
                        appearanceOption(appearance)
                    }
                    HStack(spacing: 16) {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(Theme.textSecondary)
                        AppearanceSlider(value: $sampleLevel, in: 0...1, accent: Theme.appearance.palette.signal)
                            .accessibilityLabel(L10n.tr("appearance.preview.level"))
                        Toggle(L10n.tr("appearance.preview.power"), isOn: $samplePower)
                            .toggleStyle(AppearanceToggleStyle(accent: Theme.appearance.palette.signal))
                            .labelsHidden()
                    }
                    .padding(16)
                    .background(HardwarePanel())
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L10n.tr("appearance.preview"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(L10n.tr("appearance.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsInfo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel(L10n.tr("appearance.info.title"))
                        .help(L10n.tr("appearance.info.message"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.tr("common.close"))
                }
            }
            .alert(L10n.tr("appearance.info.title"), isPresented: $showsInfo) {
                Button(L10n.tr("common.ok"), role: .cancel) {}
            } message: { Text(L10n.tr("appearance.info.message")) }
        }
        .tint(Theme.textPrimary)
        .preferredColorScheme(Theme.appearance.colorScheme)
    }

    private func appearanceOption(_ appearance: AppAppearance) -> some View {
        let p = appearance.palette
        let selected = Theme.appearance == appearance
        return Button { AppearanceSettings.shared.selection = appearance } label: {
            HStack(spacing: 18) {
                ZStack {
                    if appearance.isRealistic {
                        HardwareDial(appearance: appearance, accent: p.signal, outerInset: 2)
                    } else {
                        Circle().stroke(p.edge, lineWidth: 1)
                    }
                    Image(systemName: "pause.fill")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(appearance.isRealistic ? p.signal : p.ink)
                }
                .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 10) {
                    Text(appearance.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 6) {
                        ForEach(0..<16) { index in
                            Capsule().fill(index < 10 ? p.signal : p.edge)
                                .frame(width: 3, height: index.isMultiple(of: 4) ? 12 : 7)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? p.signal : p.secondary)
            }
            .foregroundStyle(p.ink)
            .padding(18)
                        .background(HardwareSurface(appearance: appearance))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? p.signal : p.edge, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(HardwareButtonStyle())
        .accessibilityIdentifier("appearance.\(appearance.rawValue)")
        .accessibilityLabel(appearance.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AppearanceView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AppearanceView().previewDevice("iPhone SE (3rd generation)")
            AppearanceView().previewDevice("iPhone 16 Pro Max")
        }
    }
}
