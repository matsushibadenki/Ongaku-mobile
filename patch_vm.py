import re

with open("audio/AudioPlayerViewModel.swift", "r") as f:
    text = f.read()

# Replace hiResPlaybackEngine.load with loadFastFile for bootstrap
old_load = """            try hiResPlaybackEngine.load(
                url: assetURL,
                effectSettings: playbackEffectSettings,
                headphoneSpatialSettings: playbackSpatialSettings,
                upsamplingMode: bootstrapUpsampling
            )
            localPlaybackFormatDescription = hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
            if autoplay {
                try hiResPlaybackEngine.play()"""

new_load = """            if bootstrapUpsampling == .avAudioConverter {
                try hiResPlaybackEngine.loadFastFile(
                    url: assetURL,
                    effectSettings: playbackEffectSettings,
                    headphoneSpatialSettings: playbackSpatialSettings,
                    upsamplingMode: bootstrapUpsampling
                )
                localPlaybackFormatDescription = hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                if autoplay {
                    hiResPlaybackEngine.playFastFile(autoplay: true)
            } else {
                try hiResPlaybackEngine.load(
                    url: assetURL,
                    effectSettings: playbackEffectSettings,
                    headphoneSpatialSettings: playbackSpatialSettings,
                    upsamplingMode: bootstrapUpsampling
                )
                localPlaybackFormatDescription = hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                if autoplay {
                    try hiResPlaybackEngine.play()
            }"""

# Wait, `autoplay { try hiResPlaybackEngine.play() }` is matched.
# A simpler regex patch:
def replace_load(t):
    pattern = r"""            try hiResPlaybackEngine\.load\(\n                url: assetURL,\n                effectSettings: playbackEffectSettings,\n                headphoneSpatialSettings: playbackSpatialSettings,\n                upsamplingMode: bootstrapUpsampling\n            \)\n            localPlaybackFormatDescription = hiResPlaybackEngine\.currentFormat\?\.description \?\? L10n\.playbackFormatUnavailable\(\)\n            if autoplay \{\n                try hiResPlaybackEngine\.play\(\)"""
    
    replacement = """            if bootstrapUpsampling == .avAudioConverter {
                try hiResPlaybackEngine.loadFastFile(
                    url: assetURL,
                    effectSettings: playbackEffectSettings,
                    headphoneSpatialSettings: playbackSpatialSettings,
                    upsamplingMode: bootstrapUpsampling
                )
                localPlaybackFormatDescription = hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                if autoplay {
                    hiResPlaybackEngine.playFastFile(autoplay: true)
            } else {
                try hiResPlaybackEngine.load(
                    url: assetURL,
                    effectSettings: playbackEffectSettings,
                    headphoneSpatialSettings: playbackSpatialSettings,
                    upsamplingMode: bootstrapUpsampling
                )
                localPlaybackFormatDescription = hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                if autoplay {
                    try hiResPlaybackEngine.play()
            }"""
    # Note: the closing brace for the `if bootstrapUpsampling` is missing in the replacement!
    # Let me do it safely with python parsing.
    return t

