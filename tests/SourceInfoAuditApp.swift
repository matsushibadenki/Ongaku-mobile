import SwiftUI
import UIKit
import AVFoundation

@main @MainActor final class SourceInfoAuditApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIHostingController(rootView: Text("Source info audit"))
        window.makeKeyAndVisible()
        Task { await run() }
        return true
    }
    private func run() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let url = root.appendingPathComponent("CD-source.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
            pcm.frameLength = 4410
            for i in 0..<4410 { pcm.floatChannelData![0][i] = Float(0.1 * sin(Double(i) * 0.1)) }
            do { let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false]); try file.write(from: pcm) }
            let song = SystemSong(id: 1, title: "CD取り込み曲の音源ファイル情報", artist: "検証アーティスト", album: "アルバム",
                artistID: nil, albumID: nil, discNumber: nil, trackNumber: nil, duration: 0.1, url: url)
            window!.rootViewController = UIHostingController(rootView: TrackCapabilityDetailView(song: song))
            try await Task.sleep(for: .seconds(2))
            save(root.appendingPathComponent("source-top.png"))
            func scrolls(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            if let scroll = scrolls(window!).max(by: { $0.contentSize.height < $1.contentSize.height }) {
                scroll.setContentOffset(CGPoint(x: 0, y: min(270, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
            }
            try await Task.sleep(for: .milliseconds(400))
            save(root.appendingPathComponent("source-details.png"))
            let missing = SystemSong(id: 2, title: "読み込めない音源", artist: "検証", album: "アルバム",
                artistID: nil, albumID: nil, discNumber: nil, trackNumber: nil, duration: 60,
                url: root.appendingPathComponent("missing.wav"))
            window!.rootViewController = UIHostingController(rootView: TrackCapabilityDetailView(song: missing))
            try await Task.sleep(for: .seconds(2))
            if let scroll = scrolls(window!).max(by: { $0.contentSize.height < $1.contentSize.height }) {
                scroll.setContentOffset(CGPoint(x: 0, y: min(300, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
            }
            try await Task.sleep(for: .milliseconds(400))
            save(root.appendingPathComponent("source-unavailable.png"))
            try "PASS".write(to: root.appendingPathComponent("source-result.txt"), atomically: true, encoding: .utf8)
        } catch {
            try? "FAIL: \(error)".write(to: root.appendingPathComponent("source-result.txt"), atomically: true, encoding: .utf8)
        }
    }
    private func save(_ url: URL) {
        window!.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window!.bounds).image { _ in
            window!.drawHierarchy(in: window!.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url)
    }
}
