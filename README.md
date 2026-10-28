# Ongaku

Ongaku is a native iPhone music player built with SwiftUI and AVFoundation. It brings music from the iPhone, the system Music library, network folders, and Google Drive into one listening experience, with customizable effects and a VU meter.

[Ongaku on the App Store](https://apps.apple.com/jp/app/ongaku-%E9%99%90%E7%95%8C%E3%81%BE%E3%81%A7%E9%AB%98%E9%9F%B3%E8%B3%AA%E3%82%92%E6%B1%82%E3%82%81%E3%82%8B%E3%83%8F%E3%82%A4%E3%83%AC%E3%82%BE%E9%9F%B3%E6%A5%BD%E3%83%97%E3%83%AC%E3%83%BC%E3%83%A4%E3%83%BC/id6761979714) · [Ongaku Desktop](https://github.com/matsushibadenki/Ongaku-desktop) · [Roadmap](docs/ROADMAP.md)

## Features

- **Library and playback:** Browse and play music in the system Music library and files managed by Ongaku. The local library reads metadata and artwork from supported files and folders.
- **Audio effects:** Choose OFF, Basic, or Pro and adjust effects including EQ, Exciter, OptoFET, Space, and the experimental Transient and Vocal Presence controls. The prototypes start off by default.
- **Playback display:** Follow a VU meter, spectrum display, track details, and available source-format information. Choose from several appearances, including pastel themes.
- **Lyrics:** Search LRCLIB for plain or synchronized lyrics, follow timed lyrics during playback, and save them on the device. For supported files in the Ongaku folder, lyrics can also be embedded in the file's metadata.
- **Mac sync:** Pair with Ongaku Desktop over the local network and transfer individual local tracks. Transfers are verified with SHA-256.
- **Network sources:** Select a network folder connected through the iOS Files app, or connect Google Drive with read-only access to find and stream supported audio.
- **Languages:** English, Japanese, and Simplified Chinese.

Playback and effect availability depend on the source. For example, iOS does not expose audio samples from protected Apple Music/system tracks to Ongaku, so its custom effects and visualizers cannot be applied to those tracks. Apple Music catalog access and adding items to a library also depend on the user's permissions and account.

## Add music

Ongaku scans its `Documents/Ongaku` folder and can also read the system Music library with permission. The local scanner recognizes AAC, AIFF, ALAC, CAF, FLAC, M4A, MP3, and WAV file extensions; actual playback depends on whether iOS can decode the file.

To use a network folder, connect to the server in Files first, then select the folder in Ongaku's Network settings. To sync local tracks with a Mac, open **Settings → Mac Sync** on the iPhone and start **Sync with iPhone** in Ongaku Desktop. Keep both devices on the same network and approve the matching pairing code.

## Build and run

The app target is `audio`, with a deployment target of iOS 17.0 and an iPhone device family. The project was created with Xcode 26.4. A Mac with Xcode and the iOS SDK is required.

1. Open `Ongaku.xcodeproj` in Xcode.
2. Select the **audio** scheme and an iPhone or iOS Simulator destination.
3. For a physical device, select your development team and use a bundle identifier that your team can sign.
4. Build and run. Grant Music library or local network access when the features you use request it.

For an unsigned simulator build:

```sh
xcodebuild -project Ongaku.xcodeproj -scheme audio -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ongaku-derived-data CODE_SIGNING_ALLOWED=NO build
```

Google Drive sign-in uses the OAuth client and callback scheme configured in `audio/GoogleOAuthController.swift` and `AppInfo.plist`. A separately signed distribution may need its own Google OAuth configuration.

## Audio and testing

For audio that Ongaku can process directly, the effect rack uses a 96 kHz processing format. The app selects the upsampling path according to available device memory. Its ordinary output path includes Apple's peak limiter and a margin; this is not a general true-peak guarantee. Additional final true-peak protection remains subject to device qualification and is not enabled in ordinary builds.

Focused regression scripts are in [`tests/`](tests/). For example, on macOS:

```sh
bash tests/run_audio_fidelity_policy_regression.sh
bash tests/run_vocal_presence_regression.sh
```

Some audio tests require access to macOS audio services, and some measurements use Python dependencies or Simulator devices. See the scripts and the [validation documents](docs/) for prerequisites, results, and limitations. Simulator and offline results do not replace listening and route testing on physical devices.

## Project layout

- [`audio/`](audio/) — iOS app, playback, library, effects, localization, and assets.
- [`tests/`](tests/) — focused regression tests and measurement tools.
- [`docs/`](docs/) — roadmap, design notes, and validation results.
- [`Ongaku.xcodeproj`](Ongaku.xcodeproj) — Xcode project and app target.

Ongaku Desktop is maintained separately in the [desktop repository](https://github.com/matsushibadenki/Ongaku-desktop).
