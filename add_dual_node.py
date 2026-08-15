import re

with open("audio/HiResPlaybackEngine.swift", "r") as f:
    text = f.read()

text = text.replace(
    "private let playerNode = AVAudioPlayerNode()",
    "private let playerNode = AVAudioPlayerNode()\n    private let upgradePlayerNode = AVAudioPlayerNode()\n    private var isUpgradePlayerNodeActive = false\n    private var activePlayerNode: AVAudioPlayerNode { isUpgradePlayerNodeActive ? upgradePlayerNode : playerNode }"
)

text = text.replace(
    "engine.attach(playerNode)",
    "engine.attach(playerNode)\n        engine.attach(upgradePlayerNode)"
)

text = text.replace(
    "engine.connect(playerNode, to: declickMixer, format: nil)",
    "engine.connect(playerNode, to: declickMixer, format: nil)\n        engine.connect(upgradePlayerNode, to: declickMixer, format: nil)"
)

text = text.replace("playerNode.pause()", "activePlayerNode.pause()")
text = text.replace("playerNode.play()", "activePlayerNode.play()")
text = text.replace("playerNode.isPlaying", "activePlayerNode.isPlaying")

# In scheduleBuffer, replace playerNode.stop() etc
def replace_in_schedule_buffer(t):
    schedule_buffer_str = """
    private func scheduleBuffer(from time: TimeInterval, autoplay: Bool) {
        guard let sourceBuffer = convertedBuffer, let playbackFormat = convertedFormat else { return }

        playbackGeneration &+= 1
        let generation = playbackGeneration
        playerNode.stop()
        playerNode.reset()
        playbackStartedAt = nil"""
    
    new_schedule_buffer_str = """
    private func scheduleBuffer(from time: TimeInterval, autoplay: Bool) {
        guard let sourceBuffer = convertedBuffer, let playbackFormat = convertedFormat else { return }

        playbackGeneration &+= 1
        let generation = playbackGeneration
        let node = activePlayerNode
        node.stop()
        node.reset()
        playbackStartedAt = nil"""
    t = t.replace(schedule_buffer_str, new_schedule_buffer_str)

    t = t.replace("playerNode.scheduleBuffer(\n            playbackBuffer,", "node.scheduleBuffer(\n            playbackBuffer,")
    t = t.replace("playerNode.play()\n            playbackStartedAt = Date()", "node.play()\n            playbackStartedAt = Date()")
    return t

text = replace_in_schedule_buffer(text)

with open("audio/HiResPlaybackEngine.swift", "w") as f:
    f.write(text)

