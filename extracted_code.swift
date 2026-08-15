        // We now evaluate currentTime() exactly at the moment of crossfade
        // on the main actor to prevent audio backtrack/stutter caused by
        // context switching latency.
        do {
            try Task.checkCancellation()

            try await MainActor.run {
                try self.crossfadeToPreparedPlaybackData(
                    prepared,
                    effectSettings: effectSettings,
                    shouldResume: shouldResume
                )
            }
        } catch {
            throw error
        }
    private func crossfadeToPreparedPlaybackData(
        _ prepared: PreparedPlaybackData,
        effectSettings: [RealtimeAudioEffectSetting],
        shouldResume: Bool
    ) throws {
        let exactResumeTime = self.currentTime()
        let oldNode = activePlayerNode
        let newNode = isUpgradePlayerNodeActive ? playerNode : upgradePlayerNode
        let wasPlaying = oldNode.isPlaying

        let needsFormatChange: Bool
        if let current = configuredProcessingFormat {
            let new = prepared.targetFormat
            needsFormatChange = abs(current.sampleRate - new.sampleRate) >= 0.1 ||
                current.channelCount != new.channelCount ||
                current.commonFormat != new.commonFormat ||
                current.isInterleaved != new.isInterleaved
        } else {
            needsFormatChange = true
        }

        if needsFormatChange {
            oldNode.pause()
        }

        let start = Date()

        // Install the new graph state without stopping the currently audible
        // node (if format remains the same). Both player nodes share the same processing graph and format.
        try installPreparedPlaybackData(prepared, effectSettings: effectSettings)

        let elapsedSeconds = Date().timeIntervalSince(start)
        let adjustedResumeTime = (needsFormatChange || !wasPlaying) ? exactResumeTime : (exactResumeTime + elapsedSeconds)

        oldNode.volume = 1.0
        newNode.volume = 0.0
        try schedulePreparedBuffer(prepared.playbackBuffer, from: adjustedResumeTime, on: newNode)
        try ensureEngineRunning()
        if shouldResume {
            newNode.play()
        }

        // The replacement is already running before the old node is stopped.
        // A short gain crossfade prevents a click without creating silence.
        let steps = 8
        for step in 1...steps {
            let progress = Float(step) / Float(steps)
            let oldGain = 1.0 - progress
            let newGain = progress
            let delay = 0.004 * Double(step)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !needsFormatChange {
                    oldNode.volume = oldGain
                }
                newNode.volume = newGain
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.040) { [weak oldNode] in
            oldNode?.stop()
            oldNode?.reset()
            oldNode?.volume = 0.0
        }
        isUpgradePlayerNodeActive.toggle()
        playbackOffset = min(max(0, adjustedResumeTime), duration)
        playbackStartedAt = shouldResume ? Date() : nil
    }
        // Sample the position while the normal file is still playing. Do not
        // fade to silence here: the old implementation intentionally muted
        // the output during engine reconfiguration, which sounded like a stop
        // before the high-quality buffer resumed.
        let exactResumeTime = currentTime()
        let evaluationTime = Date()
        
        do {
            try Task.checkCancellation()

            try await MainActor.run {
                try self.crossfadeToPreparedPlaybackData(
                    prepared,
                    effectSettings: effectSettings,
                    resumeTime: exactResumeTime,
                    evaluationTime: evaluationTime,
                    shouldResume: shouldResume
                )
            }
        } catch {
            throw error
        }
    private func crossfadeToPreparedPlaybackData(
        _ prepared: PreparedPlaybackData,
        effectSettings: [RealtimeAudioEffectSetting],
        resumeTime: TimeInterval,
        evaluationTime: Date? = nil,
        shouldResume: Bool
    ) throws {
        let oldNode = activePlayerNode
        let newNode = isUpgradePlayerNodeActive ? playerNode : upgradePlayerNode
        let wasPlaying = oldNode.isPlaying

        let needsFormatChange: Bool
        if let current = configuredProcessingFormat {
            let new = prepared.targetFormat
            needsFormatChange = abs(current.sampleRate - new.sampleRate) >= 0.1 ||
                current.channelCount != new.channelCount ||
                current.commonFormat != new.commonFormat ||
                current.isInterleaved != new.isInterleaved
        } else {
            needsFormatChange = true
        }

        // Install the new graph state without stopping the currently audible
        // node (if format remains the same). Both player nodes share the same processing graph and format.
        try installPreparedPlaybackData(prepared, effectSettings: effectSettings)

        let adjustedResumeTime: TimeInterval
        if let evalTime = evaluationTime, !needsFormatChange, wasPlaying {
            // Engine did NOT stop. Audio kept advancing. Add elapsed time to stay perfectly synced!
            let elapsed = Date().timeIntervalSince(evalTime)
            adjustedResumeTime = resumeTime + elapsed
        } else {
            // Engine DID stop, or it was not playing. Audio did NOT advance. Resume from exact time!
            adjustedResumeTime = resumeTime
        }

        oldNode.volume = 1.0
        newNode.volume = 0.0
        try schedulePreparedBuffer(prepared.playbackBuffer, from: adjustedResumeTime, on: newNode)
    private func crossfadeToPreparedPlaybackData(
        _ prepared: PreparedPlaybackData,
        effectSettings: [RealtimeAudioEffectSetting],
        resumeTime: TimeInterval,
        evaluationTime: Date? = nil,
        shouldResume: Bool
    ) throws {
        let oldNode = activePlayerNode
        let newNode = isUpgradePlayerNodeActive ? playerNode : upgradePlayerNode
        let wasPlaying = oldNode.isPlaying

        // The user instructed: "通常音質プレーヤーと高音質プレーヤーは、最初の通常音質再生時には両方用意しておいてください。
        // 高音質のデータが整い次第、再生中の場所からフェードインするだけです。"
        // Since loadFastFile already configures the engine to the highest required processing format,
        // we DO NOT need to call configureAudioSession or configureProcessingFormat here.
        // Calling them mid-playback causes severe audio interruption/silence when hardware rejects the sample rate.
        currentAudioFile = prepared.audioFile
        currentAudioURL = prepared.url
        baseConvertedBuffer = prepared.baseBuffer
        convertedBuffer = prepared.playbackBuffer
        convertedFormat = prepared.targetFormat
        signalDiagnostics = prepared.diagnostics
        automaticDSPProfile = prepared.automaticDSPProfile
        lastAutomaticDSPCacheHit = prepared.analysisCacheHit
        currentUpsamplingMode = prepared.upsamplingMode
        applyAutomaticDSPProfile(prepared.automaticDSPProfile)
        duration = prepared.duration
        estimatedPipelineLatencyFrames = effectPipeline.reduce(0) { $0 + $1.estimatedLatencyFrames }
        currentFormat = prepared.formatDescription
        apply(effectSettings: effectSettings)

        let adjustedResumeTime: TimeInterval
        if let evalTime = evaluationTime, wasPlaying {
            // Engine did NOT stop. Audio kept advancing. Add elapsed time to stay perfectly synced!
            let elapsed = Date().timeIntervalSince(evalTime)
            adjustedResumeTime = resumeTime + elapsed
        } else {
            adjustedResumeTime = resumeTime
        }

        oldNode.volume = 1.0
        newNode.volume = 0.0
        try schedulePreparedBuffer(prepared.playbackBuffer, from: adjustedResumeTime, on: newNode)
        // The replacement is already running before the old node is stopped.
        // A short gain crossfade prevents a click without creating silence.
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
            oldNode?.volume = 1.0 // Reset volume for next use
        }
        isUpgradePlayerNodeActive.toggle()
        playbackOffset = min(max(0, adjustedResumeTime), duration)
        playbackStartedAt = shouldResume ? Date() : nil
    }
    private func loadFastFile(
        url: URL,
        audioFile: AVAudioFile,
        effectSettings: [RealtimeAudioEffectSetting]
    ) throws {
        stop()

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
        apply(effectSettings: effectSettings)

        // As instructed by the user: "通常音質プレーヤーと高音質プレーヤーは、最初の通常音質再生時には両方用意しておいてください"
        // We schedule the audio on BOTH nodes and play them BOTH. This keeps the AudioUnit DSP graph HOT
        // for both nodes, avoiding any CoreAudio thread locks or silence when the high-quality node
        // is swapped in later.
        playerNode.volume = 1.0
        upgradePlayerNode.volume = 0.0
        isUpgradePlayerNodeActive = false

        scheduleBuffer(from: 0, autoplay: false)
    }
    private func scheduleBuffer(from time: TimeInterval, autoplay: Bool) {
        guard let audioFile = currentAudioFile else { return }

        let sampleRate = audioFile.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(time * sampleRate, Double(audioFile.length))))
        let framesToPlay = max(0, audioFile.length - startFrame)

        let oldNode = activePlayerNode
        let newNode = isUpgradePlayerNodeActive ? playerNode : upgradePlayerNode

        playbackGeneration &+= 1
        let generation = playbackGeneration

        newNode.stop()
        newNode.reset()
        newNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: AVAudioFrameCount(framesToPlay), at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.playbackStartedAt = nil
                self.playbackOffset = self.duration
                self.onPlaybackEnded?()
            }
        }
        
        // Also schedule on the inactive node to keep it HOT.
        oldNode.stop()
        oldNode.reset()
        oldNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: AVAudioFrameCount(framesToPlay), at: nil, completionHandler: nil)

        if autoplay {
            newNode.play()
            oldNode.play()
            playbackStartedAt = Date()
        }

        isUpgradePlayerNodeActive.toggle()
    }
    private func loadFastFile(
        url: URL,
        audioFile: AVAudioFile,
        effectSettings: [RealtimeAudioEffectSetting]
    ) throws {
        stop()

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
        apply(effectSettings: effectSettings)

        // As instructed by the user: "通常音質プレーヤーと高音質プレーヤーは、最初の通常音質再生時には両方用意しておいてください"
        // We prepare BOTH players from the very beginning. By keeping them both playing
        // (with the upgrade node muted), we ensure the CoreAudio graph remains HOT.
        // This avoids any sudden audio stops/underruns when the high-quality node is swapped in later.
        playerNode.volume = 1.0
        upgradePlayerNode.volume = 0.0
        isUpgradePlayerNodeActive = false

        scheduleFastFile(from: 0, autoplay: false)
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

        if startFrame == 0 {
            audioFile.framePosition = 0
            playbackOffset = 0
            node.scheduleFile(audioFile, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.playbackGeneration == generation else { return }
                    self.playbackStartedAt = nil
                    self.playbackOffset = self.duration
                    self.onPlaybackEnded?()
                }
            }
            // Keep inactive node hot
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
            node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.playbackGeneration == generation else { return }
                    self.playbackStartedAt = nil
                    self.playbackOffset = self.duration
                    self.onPlaybackEnded?()
                }
            }
            // Keep inactive node hot
            inactiveNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }

        if autoplay {
            node.play()
            inactiveNode.play()
            playbackStartedAt = Date()
        }
    }
    private func crossfadeToPreparedPlaybackData(
        _ prepared: PreparedPlaybackData,
        effectSettings: [RealtimeAudioEffectSetting],
        resumeTime: TimeInterval,
        evaluationTime: Date? = nil,
        shouldResume: Bool
    ) throws {
        let oldNode = activePlayerNode
        let newNode = isUpgradePlayerNodeActive ? playerNode : upgradePlayerNode
        let wasPlaying = oldNode.isPlaying

        // As instructed by the user: "高音質のデータが整い次第、再生中の場所からフェードインするだけです。
        // そしてそれに併せて通常音質版をフェードアウトさせるだけです。"
        // Do NOT reconfigure the engine mid-playback. Update state and schedule the buffer directly.
        currentAudioFile = prepared.audioFile
        currentAudioURL = prepared.url
        baseConvertedBuffer = prepared.baseBuffer
        convertedBuffer = prepared.playbackBuffer
        convertedFormat = prepared.targetFormat
        signalDiagnostics = prepared.diagnostics
        automaticDSPProfile = prepared.automaticDSPProfile
        lastAutomaticDSPCacheHit = prepared.analysisCacheHit
        currentUpsamplingMode = prepared.upsamplingMode
        applyAutomaticDSPProfile(prepared.automaticDSPProfile)
        duration = prepared.duration
        estimatedPipelineLatencyFrames = effectPipeline.reduce(0) { $0 + $1.estimatedLatencyFrames }
        currentFormat = prepared.formatDescription
        apply(effectSettings: effectSettings)

        let adjustedResumeTime: TimeInterval
        if let evalTime = evaluationTime, wasPlaying {
            let elapsed = Date().timeIntervalSince(evalTime)
            adjustedResumeTime = resumeTime + elapsed
        } else {
            adjustedResumeTime = resumeTime
        }

        oldNode.volume = 1.0
        newNode.volume = 0.0
        try schedulePreparedBuffer(prepared.playbackBuffer, from: adjustedResumeTime, on: newNode)

        if shouldResume {
            newNode.play()
        }

        // The replacement is already running before the old node is stopped.
        // A short gain crossfade prevents a click without creating silence.
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
            oldNode?.volume = 1.0 // Reset volume for next use
        }
        isUpgradePlayerNodeActive.toggle()
        playbackOffset = min(max(0, adjustedResumeTime), duration)
        playbackStartedAt = shouldResume ? Date() : nil
    }
