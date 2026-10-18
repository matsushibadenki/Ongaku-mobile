import SwiftUI
import UIKit

@main @MainActor final class PastelAppearanceAuditApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let player = AudioPlayerViewModel()
    private let sync = DesktopSyncController()
    private var lines: [String] = []
    private var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIHostingController(rootView: Text("Appearance audit"))
        window.makeKeyAndVisible()
        Task { await run() }
        return true
    }

    private func log(_ line: String) {
        lines.append(line)
        try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("pastel-result.txt"), atomically: true, encoding: .utf8)
    }

    private func show<V: View>(_ view: V) async {
        window!.rootViewController = UIHostingController(rootView: view)
        try? await Task.sleep(for: .milliseconds(700))
        window!.layoutIfNeeded()
    }

    private func capture(_ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window!.bounds).image { _ in
            window!.drawHierarchy(in: window!.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()!.write(to: root.appendingPathComponent(name + ".png"))
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func run() async {
        let themes: [AppAppearance] = [.pink, .purple, .green, .beige]
        let expected: [UInt32] = [0xfbeefa, 0xeeecfe, 0xe1fff4, 0xfaf7e3]
        precondition(AppAppearance.allCases.count == 7)
        for (theme, hex) in zip(themes, expected) {
            AppearanceSettings.shared.selection = theme
            precondition(theme.isLight && theme.isRealistic && theme.pastelHex == hex)
            precondition(UserDefaults.standard.string(forKey: AppearanceSettings.storageKey) == theme.rawValue)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(theme.palette.background).getRed(&r, green: &g, blue: &b, alpha: &a)
            precondition(abs(r * 255 - CGFloat((hex >> 16) & 255)) < 0.01)
            precondition(abs(g * 255 - CGFloat((hex >> 8) & 255)) < 0.01)
            precondition(abs(b * 255 - CGFloat(hex & 255)) < 0.01)
            let image = UIImage(named: "VUmeter_pastel_\(theme.rawValue)")!
            precondition(image.size == CGSize(width: 852, height: 1846))
            for locale in ["en", "ja", "zh-Hans"] {
                let bundle = Bundle(path: Bundle.main.path(forResource: locale, ofType: "lproj")!)!
                let key = "appearance.\(theme.rawValue)"
                precondition(bundle.localizedString(forKey: key, value: nil, table: nil) != key)
            }
            await show(ContentView(player: player).environmentObject(sync))
            capture("now-playing-\(theme.rawValue)")
            for level in [0.0, 20.0 / 23, 1.0] {
                await show(ZStack {
                    HardwareSurface()
                    VUMeterView(value: level, isPrecisionSinc: level > 0)
                }.ignoresSafeArea().preferredColorScheme(.light))
                capture("dial-\(theme.rawValue)-\(Int(level * 23))")
            }
            log("PASS: \(theme.rawValue) exact background, saved selection, asset, EN/JA/zh-Hans labels; captured production screen and min/0VU/max dial")
        }
        for value in [Double.nan, -Double.infinity, -1, 0, 20.0 / 23, 1, 2] {
            let tip = PastelVUMeterGeometry.point(level: value)
            precondition(tip.x.isFinite && tip.y.isFinite)
            precondition(CGRect(x: 194, y: 276, width: 464, height: 390).contains(tip))
        }
        log("PASS: needle endpoints remain inside the dial; nonfinite and out-of-range telemetry clamps safely")
        await show(AppearanceView())
        capture("appearance-top")
        if let scroll = descendants(window!).compactMap({ $0 as? UIScrollView }).first(where: { $0.contentSize.height > $0.bounds.height }) {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            try? await Task.sleep(for: .milliseconds(400))
            capture("appearance-bottom")
            log("PASS: appearance picker scrolls to the four new choices and preview controls")
        } else { log("FAIL: appearance picker did not expose a scrolling container"); return }
        AppearanceSettings.shared.selection = .pink
        await show(ContentView(player: player).environmentObject(sync))
        log("COMPLETE")
    }
}
