import sys

with open("audio/HiResPlaybackEngine.swift", "r") as f:
    content = f.read()

# 1. Add upgradePlayerNode
content = content.replace("private let playerNode = AVAudioPlayerNode()", "private let playerNode = AVAudioPlayerNode()\n    private let upgradePlayerNode = AVAudioPlayerNode()\n    private var isUpgradePlayerNodeActive = false\n    private var activePlayerNode: AVAudioPlayerNode { isUpgradePlayerNodeActive ? upgradePlayerNode : playerNode }")

# 2. Attach and connect upgradePlayerNode in init
init_str = """
        engine.attach(playerNode)
        engine.attach(declickMixer)
        engine.attach(loudnessCompensationEQ)
        engine.attach(automaticDSPEQ)
"""
new_init_str = """
        engine.attach(playerNode)
        engine.attach(upgradePlayerNode)
        engine.attach(declickMixer)
        engine.attach(loudnessCompensationEQ)
        engine.attach(automaticDSPEQ)
"""
content = content.replace(init_str, new_init_str)

connect_str = """
        engine.connect(playerNode, to: declickMixer, format: nil)
        engine.connect(declickMixer, to: loudnessCompensationEQ, format: nil)
"""
new_connect_str = """
        engine.connect(playerNode, to: declickMixer, format: nil)
        engine.connect(upgradePlayerNode, to: declickMixer, format: nil)
        engine.connect(declickMixer, to: loudnessCompensationEQ, format: nil)
"""
content = content.replace(connect_str, new_connect_str)

# 3. Update load method
load_str = """    func load(
        url: URL,
        effectSettings: [RealtimeAudioEffectSetting],
        headphoneSpatialSettings: HeadphoneSpatialSettings? = nil,
        upsamplingMode: UpsamplingMode? = nil
    ) throws {
        stop()
        let resolvedSpatialSettings = memorySafetyMode.safeSpatialSettings(headphoneSpatialSettings ?? .default)
        let resolvedUpsamplingMode = memorySafetyMode.safeUpsamplingMode(upsamplingMode ?? .avAudioConverter)
        let safeEffectSettings = memorySafetyMode.safeEffectSettings(effectSettings)
        
        self.headphoneSpatialSettings = resolvedSpatialSettings
        currentUpsamplingMode = resolvedUpsamplingMode
        let preloadKey = Self.makePreloadedPlaybackKey(
            url: url,
            upsamplingMode: resolvedUpsamplingMode,
            spatialSettings: resolvedSpatialSettings
        )
        playbackOffset = 0

        if let prepared = consumePreloadedPlaybackData(for: preloadKey) {
            try applyPreparedPlaybackData(prepared, effectSettings: safeEffectSettings)
        } else {
            let prepared = try Self.preparePlaybackData(
                url: url,
                headphoneSpatialSettings: resolvedSpatialSettings,
                upsamplingMode: resolvedUpsamplingMode
            )
            try applyPreparedPlaybackData(prepared, effectSettings: safeEffectSettings)
        }
    }"""

# Actually, the user's issue with seamless upgrade was about fast load vs high quality.
# In HEAD, `load` always does `preparePlaybackData` which takes 3 seconds! It's NOT fast!
# Oh, the PREVIOUS agent implemented fast loading!

with open("audio/HiResPlaybackEngine.swift", "w") as f:
    f.write(content)
