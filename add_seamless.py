import re

with open("audio/HiResPlaybackEngine.swift", "r") as f:
    text = f.read()

seamless_methods = """
    // MARK: - Seamless Background Upgrade
    
    func loadFastFile(
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
        
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.resolvedProcessingSampleRate(for: sourceFormat.sampleRate),
            channels: max(AVAudioChannelCount(2), sourceFormat.channelCount),
            interleaved: false
        )!
        
        try configureAudioSession(preferredSampleRate: processingFormat.sampleRate)
        configureProcessingFormat(processingFormat)
        
        currentAudioFile = audioFile
        currentAudioURL = url
        duration = Double(audioFile.length) / sourceFormat.sampleRate
        estimatedPipelineLatencyFrames = effectPipeline.reduce(0) { $0 + $1.estimatedLatencyFrames }
        playbackOffset = 0
        
        // Ensure dual node hot standby
        playerNode.volume = 1.0
        upgradePlayerNode.volume = 0.0
        isUpgradePlayerNodeActive = false
        
        apply(effectSettings: safeEffectSettings)
    }

    func playFastFile(autoplay: Bool) {
        scheduleFastFile(from: playbackOffset, autoplay: autoplay)
    }

    private func scheduleFastFile(from time: TimeInterval, autoplay: Bool) {
        guard let audioFile = currentAudioFile else { return }

        playbackGeneration &+= 1
        let generation = playbackGeneration
        let node = activePlayerNode
        let inactiveNode = isUpgradePlayerNodeActive ? playerNode : upgradePlayerNode
        
        node.stop()
        node.reset()
        inactiveNode.stop()
        inactiveNode.reset()
        playbackStartedAt = nil

        let clampedTime = min(max(0, time), duration)
        let startFrame = AVAudioFramePosition(clampedTime * audioFile.processingFormat.sampleRate)
        guard startFrame < audioFile.length else {
            playbackOffset = duration
            onPlaybackEnded?()
            return
        }

        let completionHandler: AVAudioNodeCompletionHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.playbackStartedAt = nil
                self.playbackOffset = self.duration
                self.onPlaybackEnded?()
            }
        }

        if startFrame == 0 {
            audioFile.framePosition = 0
            playbackOffset = 0
            node.scheduleFile(audioFile, at: nil, completionHandler: completionHandler)
            inactiveNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        } else {
            let frameCount = AVAudioFrameCount(audioFile.length - startFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { return }
            audioFile.framePosition = startFrame
            do {
                try audioFile.read(into: buffer, frameCount: frameCount)
            } catch {
                return
            }
            playbackOffset = clampedTime
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: completionHandler)
            inactiveNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }

        if autoplay {
            node.play()
            inactiveNode.play()
            playbackStartedAt = Date()
        }
    }
    
    nonisolated private static func sliceBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        from time: TimeInterval
    ) throws -> AVAudioPCMBuffer {
        let sampleRate = sourceBuffer.format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(time * sampleRate, Double(sourceBuffer.frameLength))))
        let remainingFrames = max(AVAudioFramePosition(0), AVAudioFramePosition(sourceBuffer.frameLength) - startFrame)
        guard remainingFrames > 0 else { throw HiResEngineError.upconvertBufferFailed }
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceBuffer.format,
            frameCapacity: AVAudioFrameCount(remainingFrames)
        ) else {
            throw HiResEngineError.upconvertBufferFailed
        }
        buffer.frameLength = AVAudioFrameCount(remainingFrames)
        if let sourceChannels = sourceBuffer.floatChannelData,
           let targetChannels = buffer.floatChannelData {
            let offset = Int(startFrame)
            let frames = Int(remainingFrames)
            for channel in 0..<Int(sourceBuffer.format.channelCount) {
                targetChannels[channel].update(
                    from: sourceChannels[channel].advanced(by: offset),
                    count: frames
                )
            }
        }
        return buffer
    }

    func seamlessUpgrade(
        url: URL,
        effectSettings: [RealtimeAudioEffectSetting],
        headphoneSpatialSettings: HeadphoneSpatialSettings,
        upsamplingMode: UpsamplingMode,
        shouldResume: Bool,
        onHandoffReady: (() -> Void)? = nil
    ) async throws {
        let preloadKey = Self.makePreloadedPlaybackKey(
            url: url,
            upsamplingMode: upsamplingMode,
            spatialSettings: headphoneSpatialSettings
        )
        let prepared: PreparedPlaybackData
        if let cachedPrepared = consumePreloadedPlaybackData(for: preloadKey) {
            prepared = cachedPrepared
        } else {
            prepared = try await Task.detached(priority: .utility) {
                try Self.preparePlaybackData(
                    url: url,
                    headphoneSpatialSettings: headphoneSpatialSettings,
                    upsamplingMode: upsamplingMode
                )
            }.value
        }
        
        try Task.checkCancellation()
        
        onHandoffReady?()
        
        let exactResumeTime = currentTime()
        let evaluationTime = Date()
        let wasPlaying = self.isPlaying
        
        let predictedResumeTime = wasPlaying ? exactResumeTime + 0.05 : exactResumeTime
        let slicedBuffer = try await Task.detached(priority: .utility) {
            try Self.sliceBuffer(prepared.playbackBuffer, from: predictedResumeTime)
        }.value
        
        try Task.checkCancellation()
        
        try await MainActor.run {
            let oldNode = activePlayerNode
            let newNode = isUpgradePlayerNodeActive ? playerNode : upgradePlayerNode
            
            self.currentAudioFile = prepared.audioFile
            self.currentAudioURL = prepared.url
            self.baseConvertedBuffer = prepared.baseBuffer
            self.convertedBuffer = prepared.playbackBuffer
            self.convertedFormat = prepared.targetFormat
            self.signalDiagnostics = prepared.diagnostics
            self.automaticDSPProfile = prepared.automaticDSPProfile
            self.lastAutomaticDSPCacheHit = prepared.analysisCacheHit
            self.currentUpsamplingMode = prepared.upsamplingMode
            self.applyAutomaticDSPProfile(prepared.automaticDSPProfile)
            self.duration = prepared.duration
            self.estimatedPipelineLatencyFrames = self.effectPipeline.reduce(0) { $0 + $1.estimatedLatencyFrames }
            self.currentFormat = prepared.formatDescription
            self.apply(effectSettings: effectSettings)
            
            let elapsed = Date().timeIntervalSince(evaluationTime)
            let actualResumeTime = wasPlaying ? exactResumeTime + elapsed : exactResumeTime
            
            self.playbackGeneration &+= 1
            let generation = self.playbackGeneration
            newNode.stop()
            newNode.reset()
            
            newNode.scheduleBuffer(slicedBuffer, at: nil, options: []) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.playbackGeneration == generation else { return }
                    self.playbackStartedAt = nil
                    self.playbackOffset = self.duration
                    self.onPlaybackEnded?()
                }
            }
            
            oldNode.volume = 1.0
            newNode.volume = 0.0
            
            if shouldResume {
                newNode.play()
            }
            
            let steps = 16
            for step in 1...steps {
                let progress = Float(step) / Float(steps)
                let oldGain = 1.0 - progress
                let newGain = progress
                let delay = 0.004 * Double(step)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    oldNode.volume = oldGain
                    newNode.volume = newGain
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.064) { [weak oldNode] in
                oldNode?.stop()
                oldNode?.reset()
                oldNode?.volume = 1.0
            }
            self.isUpgradePlayerNodeActive.toggle()
            self.playbackOffset = min(max(0, actualResumeTime), self.duration)
            self.playbackStartedAt = shouldResume ? Date() : nil
        }
    }

"""

target = "    nonisolated private static func applyTPDFDither(to buffer: AVAudioPCMBuffer, sourceBitDepth: UInt32) {"
text = text.replace(target, seamless_methods + target)

with open("audio/HiResPlaybackEngine.swift", "w") as f:
    f.write(text)

