//
//  AudioEffectNode.swift
//  audio
//
//  2026/04/08.
//

import AVFoundation

/// 全てのオーディオエフェクトクラスが準拠する基礎プロトコル。
/// パイプライン・アーキテクチャによる安全な動的ルーティングとゲイン管理を提供します。
protocol AudioEffectNode: AnyObject {
    /// エフェクトの種別
    var kind: RealtimeAudioEffectKind { get }
    
    /// このエフェクトが有効化されているかどうか
    var isEnabled: Bool { get }
    
    /// このエフェクトを構成する全ての AVAudioNode の配列 (エンジンへのアタッチ用)
    var nodes: [AVAudioNode] { get }
    
    /// 前段のエフェクトやソースから信号を受け取るノード
    var inputNode: AVAudioNode { get }
    
    /// 次段のエフェクトやミキサーへ信号を送るノード
    var outputNode: AVAudioNode { get }
    
    /// 音楽信号に対する予測音量ブースト（dB）。周波数や残響で変化する
    /// 参考値であり、ピーク上限の保証ではない。最終段の実信号で保護する。
    /// - 0未満: 音量が減衰する
    /// - 0を超える: 音量が増幅する
    var estimatedGainBoostDB: Double { get }

    /// Known algorithmic latency. Parallel dry/wet effects report zero here;
    /// callers can still aggregate explicit look-ahead stages consistently.
    var estimatedLatencyFrames: AVAudioFramePosition { get }
    
    /// エンジンにノードをアタッチし、内部の初期接続を行います。
    /// - Parameter engine: 接続対象の AVAudioEngine
    func attach(to engine: AVAudioEngine)
    
    /// エフェクト内部のノード同士の結線を行います（該当エフェクトが2つ以上のノードで構成されている場合）。
    /// - Parameters:
    ///   - engine: 対象の AVAudioEngine
    ///   - format: 結線に使用するオーディオフォーマット
    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?)
    
    /// エンジンから自身のノード群を取り除きます。
    /// - Parameter engine: 対象の AVAudioEngine
    func detach(from engine: AVAudioEngine)
    
    /// エフェクトパラメータを適用し、内部状態を更新します。
    /// - Parameter setting: UIから渡されたエフェクト設定
    func apply(setting: RealtimeAudioEffectSetting)
}

extension AudioEffectNode {
    var estimatedLatencyFrames: AVAudioFramePosition { 0 }
}

/// Shared with Ongaku desktop: Apple dynamics parameters use seconds and stable
/// numeric IDs. Display names are localized, and "threshold" also matches the
/// unrelated expansion threshold.
enum EffectDynamicsParameters {
    static func apply(to unit: AVAudioUnitEffect, thresholdDB: Float,
                      headroomDB: Float, attackMs: Float, releaseMs: Float,
                      masterGainDB: Float) {
        guard unit.audioComponentDescription.componentSubType == kAudioUnitSubType_DynamicsProcessor,
              let tree = unit.auAudioUnit.parameterTree else { return }
        let values: [(AudioUnitParameterID, Float)] = [
            (kDynamicsProcessorParam_Threshold, thresholdDB),
            (kDynamicsProcessorParam_HeadRoom, headroomDB),
            (kDynamicsProcessorParam_AttackTime, attackMs / 1000),
            (kDynamicsProcessorParam_ReleaseTime, releaseMs / 1000),
            (kDynamicsProcessorParam_OverallGain, masterGainDB),
            (kDynamicsProcessorParam_ExpansionRatio, 1)
        ]
        for (id, value) in values {
            if let parameter = tree.parameter(withAddress: AUParameterAddress(id)) {
                parameter.value = min(parameter.maxValue, max(parameter.minValue, value))
            }
        }
    }
}
