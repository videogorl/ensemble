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

            // Write trimmed PCM to CAF container using Int16 format.
            // MP3 sources decode to 16-bit precision, so Int16 is lossless
            // and halves file size vs Float32 (~48MB vs ~95MB per 5-min track).
            let channelCount = processingFormat.channelCount
            let int16Format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: true
            )

            // Set up output file and converter for Int16 output
            let outputFile: AVAudioFile
            let int16Converter: AVAudioConverter?
            let useInt16: Bool

            if let fmt = int16Format,
               let converter = AVAudioConverter(from: processingFormat, to: fmt) {
                outputFile = try AVAudioFile(
                    forWriting: cafURL,
                    settings: fmt.settings,
                    commonFormat: .pcmFormatInt16,
                    interleaved: true
                )
                int16Converter = converter
                useInt16 = true
            } else {
                // Fallback: write Float32 if Int16 setup fails
                outputFile = try AVAudioFile(
                    forWriting: cafURL,
                    settings: processingFormat.settings,
                    commonFormat: processingFormat.commonFormat,
                    interleaved: processingFormat.isInterleaved
                )
                int16Converter = nil
                useInt16 = false
            }

            let bufferCapacity: AVAudioFrameCount = 8192
            guard let readBuffer = AVAudioPCMBuffer(
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
                readBuffer.frameLength = 0  // Reset before read
                try inputFile.read(into: readBuffer, frameCount: toRead)
                if readBuffer.frameLength == 0 { break }  // EOF

                if useInt16, let converter = int16Converter, let fmt = int16Format {
                    // Convert Float32 -> Int16 before writing
                    guard let int16Buffer = AVAudioPCMBuffer(
                        pcmFormat: fmt,
                        frameCapacity: readBuffer.frameLength
                    ) else { break }
                    try converter.convert(to: int16Buffer, from: readBuffer)
                    try outputFile.write(from: int16Buffer)
                } else {
                    try outputFile.write(from: readBuffer)
                }
                framesWritten += AVAudioFramePosition(readBuffer.frameLength)
            }

            // Remove the source MP3 — we only need the CAF for playback
            try? FileManager.default.removeItem(at: mp3URL)

            #if DEBUG
            let cafSize = (try? FileManager.default.attributesOfItem(atPath: cafURL.path)[.size] as? Int) ?? 0
            let trimmedStart = skipFrames
            let trimmedEnd = totalDecodedFrames - skipFrames - outputFrameCount
            let formatLabel = useInt16 ? "Int16" : "Float32"
            EnsembleLogger.debug(
                "🎵 Converted MP3→CAF (\(formatLabel)): \(cafURL.lastPathComponent) "
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
