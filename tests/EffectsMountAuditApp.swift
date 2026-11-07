import SwiftUI
import UIKit

// Only compiled in an isolated copy by run_effects_mount_audit.sh.
@MainActor enum EffectsMountCounter { static var cards = 0; static var thumbs = 0 }
@main @MainActor final class EffectsMountAuditApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Audit", sessionRole: session.role)
        configuration.delegateClass = EffectsMountSceneDelegate.self
        return configuration
    }
}
@objc(EffectsMountSceneDelegate) @MainActor final class EffectsMountSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        self.window = window
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        Task { await run() }
    }
    func run() async {
        if ProcessInfo.processInfo.arguments.contains("--pipeline") {
            await FullPreparationAudit.run()
            return
        }
        AppearanceSettings.shared.selection = .light
        let player = AudioPlayerViewModel()
        player.selectEffectPageTab(.pro) // Engine/model setup excluded from the UI measurement.
        var samples: [[String:Any]] = []
        for round in 0..<3 {
            EffectsMountCounter.cards = 0
            EffectsMountCounter.thumbs = 0
            let start = CACurrentMediaTime()
            let host = UIHostingController(rootView: EffectsTabContent(player: player, isPresented: true))
            window!.rootViewController = host
            host.view.layoutIfNeeded()
            let mounted = CACurrentMediaTime()
            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
            let image = renderer.image { context in host.view.layer.render(in: context.cgContext) }
            let end = CACurrentMediaTime()
            let initialCards = EffectsMountCounter.cards
            // Let the shipping scroll-to-top task and deferred layout settle.
            try? await Task.sleep(for: .milliseconds(350))
            let data: [String:Any] = ["round":round,"mountMs":(mounted-start)*1000,
                "mountAndSnapshotMs":(end-start)*1000,"initialCardBodies":initialCards,
                "settledCardBodies":EffectsMountCounter.cards,"thumbRenders":EffectsMountCounter.thumbs,"width":host.view.bounds.width,
                "height":host.view.bounds.height]
            samples.append(data)
            if round == 0 { try? image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("effects-first.png")) }
            if round < 2 { window!.rootViewController = UIViewController() }
            try? await Task.sleep(for: .milliseconds(100))
        }
        func findScroll(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        let scroll = findScroll(window!.rootViewController!.view)!
        let before = EffectsMountCounter.cards
        scroll.setContentOffset(CGPoint(x:0,y:max(0,scroll.contentSize.height-scroll.bounds.height)),animated:false)
        try? await Task.sleep(for:.milliseconds(500))
        precondition(scroll.contentOffset.y > 0)
        let after = EffectsMountCounter.cards
        scroll.setContentOffset(CGPoint(x:0,y:-scroll.adjustedContentInset.top),animated:false)
        try? await Task.sleep(for:.milliseconds(500))
        precondition(abs(scroll.contentOffset.y+scroll.adjustedContentInset.top)<1)
        precondition(player.selectedEffectPageTab == .pro)
        samples[2]["scrollBeforeBodies"] = before
        samples[2]["scrollAfterBodies"] = after
        samples[2]["returnedToTop"] = true
        samples[2]["modePreserved"] = true
        var imageChecks = 0
        for appearance in AppAppearance.allCases {
            for scale in [CGFloat(2), CGFloat(3)] {
                let first = auditThumbImage(appearance, scale)
                let second = auditThumbImage(appearance, scale)
                precondition(first.size == CGSize(width:30,height:32) && first.scale == scale)
                precondition(first.pngData() == second.pngData())
                if !ProcessInfo.processInfo.arguments.contains("--uncached") { precondition(first === second) }
                imageChecks += 1
            }
        }
        samples[2]["thumbCacheChecks"] = imageChecks
        let result = try! JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys])
        try! result.write(to:URL.documentsDirectory.appendingPathComponent("effects-mount.json"))
    }
}
