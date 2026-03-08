import AVFoundation

/// Converts downloaded MP3 files to Core Audio Format (CAF) with uncompressed PCM,
/// trimming encoder delay and padding for true gapless playback.
///
/// PMS's universal transcode produces VBR MP3 files that cause AVPlayer issues
/// at gapless transition boundaries. MP3 encoding also inherently adds silence:
/// ~576 samples of encoder delay at the start and zero-padding to fill the last
/// frame at the end. Converting to CAF and trimming this silence gives AVPlayer
/// a clean PCM file with exact sample counts and no boundary artifacts.
enum AudioFormatConverter {

    /// Standard encoder delay for ffmpeg/libmp3lame (matches MP3VBRHeaderUtility).
    private static let encoderDelay = 576

    /// Convert an MP3 file to trimmed uncompressed CAF for gapless playback.
    ///
    /// The conversion:
    /// 1. Decodes MP3 to PCM (no quality loss)
    /// 2. Trims encoder delay (576 silent samples at start)
    /// 3. Trims padding silence at end (using metadata duration)
    /// 4. Writes exact audio content to CAF
    ///
    /// Returns the CAF file URL on success, or nil if conversion fails (caller
    /// should fall back to using the original MP3 with XING headers).
    ///
    /// - Parameters:
    ///   - mp3URL: Path to the downloaded MP3 file.
    ///   - metadataDurationSeconds: Source duration from Plex metadata, used to
    ///     calculate how many padding samples to trim from the end.
    static func convertToCAF(mp3URL: URL, metadataDurationSeconds: Double?) -> URL? {
        let cafURL = mp3URL.deletingPathExtension().appendingPathExtension("caf")

        // Remove stale CAF if it exists
        if FileManager.default.fileExists(atPath: cafURL.path) {
            try? FileManager.default.removeItem(at: cafURL)
        }

        do {
            let inputFile = try AVAudioFile(forReading: mp3URL)
            let processingFormat = inputFile.processingFormat
            let totalDecodedFrames = inputFile.length  // Total frames including delay+padding

            // Calculate trim points to remove encoder silence.
            // Encoder delay: ~576 silent samples at start (encoder warmup).
            // Padding: silent samples at end to fill the last MPEG frame.
            let sampleRate = processingFormat.sampleRate
            let skipFrames: AVAudioFramePosition
            let outputFrameCount: AVAudioFramePosition

            if let duration = metadataDurationSeconds, duration > 0 {
                let actualSamples = AVAudioFramePosition(round(duration * sampleRate))
                skipFrames = AVAudioFramePosition(encoderDelay)
                // Don't write more frames than the actual audio content
                outputFrameCount = min(actualSamples, totalDecodedFrames - skipFrames)
            } else {
                // No metadata duration — just trim encoder delay, keep the rest
                skipFrames = AVAudioFramePosition(encoderDelay)
                outputFrameCount = totalDecodedFrames - skipFrames
            }

            guard outputFrameCount > 0 else { return nil }

            // Write trimmed PCM to CAF container.
            // Use the input's exact processing format so a single buffer works
            // for both read() and write().
            let outputFile = try AVAudioFile(
                forWriting: cafURL,
                settings: processingFormat.settings,
                commonFormat: processingFormat.commonFormat,
                interleaved: processingFormat.isInterleaved
            )

            let bufferCapacity: AVAudioFrameCount = 8192
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: bufferCapacity
            ) else {
                return nil
            }

            // Skip encoder delay at the start
            if skipFrames > 0 {
                inputFile.framePosition = skipFrames
            }

            // Write only the actual audio frames (no padding at end)
            var framesWritten: AVAudioFramePosition = 0
            while framesWritten < outputFrameCount {
                let remaining = AVAudioFrameCount(outputFrameCount - framesWritten)
                let toRead = min(bufferCapacity, remaining)
                buffer.frameLength = 0  // Reset before read
                try inputFile.read(into: buffer, frameCount: toRead)
                if buffer.frameLength == 0 { break }  // EOF
                try outputFile.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
            }

            // Remove the source MP3 — we only need the CAF for playback
            try? FileManager.default.removeItem(at: mp3URL)

            #if DEBUG
            let cafSize = (try? FileManager.default.attributesOfItem(atPath: cafURL.path)[.size] as? Int) ?? 0
            let trimmedStart = skipFrames
            let trimmedEnd = totalDecodedFrames - skipFrames - outputFrameCount
            EnsembleLogger.debug(
                "🎵 Converted MP3→CAF: \(cafURL.lastPathComponent) "
                + "(\(cafSize / 1024)KB, \(framesWritten) samples, "
                + "trimmed start=\(trimmedStart) end=\(trimmedEnd))"
            )
            #endif

            return cafURL
        } catch {
            #if DEBUG
            EnsembleLogger.debug("⚠️ MP3→CAF conversion failed: \(error). Using original MP3.")
            #endif
            // Clean up partial CAF if conversion failed
            try? FileManager.default.removeItem(at: cafURL)
            return nil
        }
    }
}
