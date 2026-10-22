import AVFoundation
import Foundation
@main struct AudioGraphConfigurationRegression {
    static func main() {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let source = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        func key(_ source: AVAudioFormat? = nil, _ processing: AVAudioFormat? = nil,
                 _ out: AVAudioFormat? = nil, _ route: String? = "route-1") -> AudioGraphConfiguration? {
            AudioGraphConfiguration(source: source, processing: processing ?? stereo, output: out ?? output, routeIdentifier: route)
        }
        let baseline = key(source)!
        precondition(baseline == key(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!))
        precondition(baseline != key(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!))
        precondition(baseline != key(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!))
        precondition(baseline != key(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true)!))
        precondition(baseline != key(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true)!))
        precondition(baseline != key(source, AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!))
        precondition(baseline != key(source, nil, stereo))
        precondition(baseline != key(source, nil, AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!))
        precondition(baseline != key(source, nil, nil, "route-2"))
        precondition(key(source, nil, nil, nil) == nil && key(source, nil, nil, "") == nil)
        precondition(baseline != key())
        let binaural = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000,
            interleaved: false, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Binaural)!)
        precondition(key(source, binaural) != key(source))
        print("PASS: complete source/processing/output formats, encoding, interleave, channel layout and known route govern reuse; unknown route fails closed")
    }
}
