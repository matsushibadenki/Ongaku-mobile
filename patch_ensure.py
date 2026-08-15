import re

with open("audio/HiResPlaybackEngine.swift", "r") as f:
    text = f.read()

# Make playFastFile throw
text = text.replace(
    "func playFastFile(autoplay: Bool) {",
    "func playFastFile(autoplay: Bool) throws {\n        try ensureEngineRunning()"
)

# In seamlessUpgrade, replace newNode.play()
text = text.replace(
    "if shouldResume {\n                newNode.play()",
    "if shouldResume {\n                try? self.ensureEngineRunning()\n                newNode.play()"
)

with open("audio/HiResPlaybackEngine.swift", "w") as f:
    f.write(text)

