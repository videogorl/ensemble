import Foundation

/// Injects a XING VBR header into MP3 files that lack one.
///
/// PMS's universal transcode produces VBR MP3 files without XING/LAME headers.
/// AVPlayer can't determine the true duration or frame layout, causing:
/// - FigFilePlayer err=-12864 at file boundaries (corrupted gapless transitions)
/// - Duration overestimation (warped scrubber position)
/// - Broken gapless playback between tracks
///
/// The XING header is a standard mechanism for storing VBR metadata in a silent
/// MPEG frame at the start of the file. It contains the total frame count and
/// audio byte count, which AVPlayer uses for accurate duration and seeking.
public enum MP3VBRHeaderUtility {

    // MARK: - Public

    /// Inject a XING VBR header into an MP3 file if it lacks one.
    /// Rewrites the file in place. No-op if the file already has a XING/Info header.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the MP3 file.
    ///   - metadataDurationSeconds: Optional source duration from Plex metadata. When provided,
    ///     LAME gapless info (encoder delay + padding) is embedded so AVPlayer can trim
    ///     silence at track boundaries for seamless gapless playback.
    public static func injectXingHeaderIfNeeded(
        at fileURL: URL,
        metadataDurationSeconds: Double? = nil
    ) throws {
        let data = try Data(contentsOf: fileURL)

        // Skip ID3v2 tag if present
        let audioOffset = id3v2TagSize(in: data)

        // Check if XING/Info header already exists
        if hasXingHeader(data: data, audioOffset: audioOffset) {
            return
        }

        // Parse first MPEG frame to get stream parameters
        guard let frameInfo = parseFirstMPEGFrame(data: data, offset: audioOffset) else {
            return
        }

        // Count all frames and measure total audio bytes
        let stats = countFrames(data: data, offset: audioOffset)
        guard stats.frameCount > 0 else { return }

        // Calculate LAME gapless metadata if we have the source duration.
        // MP3 encoding adds silence: encoder delay at the start (~576 samples for
        // ffmpeg/libmp3lame) and zero-padding at the end to fill the last frame.
        // Without this info, AVPlayer plays the padding, causing ~50-100ms gaps.
        var gaplessInfo: LAMEGaplessInfo?
        if let metadataDuration = metadataDurationSeconds, metadataDuration > 0 {
            let totalSamples = stats.frameCount * frameInfo.samplesPerFrame
            let actualSamples = Int(round(metadataDuration * Double(frameInfo.sampleRate)))
            let delay = encoderDelay
            let padding = max(0, totalSamples - actualSamples - delay)
            gaplessInfo = LAMEGaplessInfo(delay: delay, padding: padding)

            #if DEBUG
            EnsembleLogger.debug(
                "🎵 LAME gapless: delay=\(delay), padding=\(padding), "
                + "totalSamples=\(totalSamples), actualSamples=\(actualSamples)"
            )
            #endif
        }

        // Build the XING header frame (includes LAME extension when gapless info is available)
        guard let xingFrame = buildXingFrame(
            frameInfo: frameInfo,
            totalFrames: stats.frameCount,
            totalAudioBytes: stats.totalBytes,
            gaplessInfo: gaplessInfo
        ) else {
            return
        }

        // Write new file: ID3v2 tag + XING frame + original audio frames
        var output = Data(capacity: data.count + xingFrame.count)
        if audioOffset > 0 {
            output.append(data[0..<audioOffset])
        }
        output.append(xingFrame)
        output.append(data[audioOffset...])

        try output.write(to: fileURL, options: .atomic)

        #if DEBUG
        EnsembleLogger.debug(
            "🎵 Injected XING header: \(stats.frameCount) frames, \(stats.totalBytes) audio bytes"
            + (gaplessInfo != nil ? " [LAME gapless: delay=\(gaplessInfo!.delay), padding=\(gaplessInfo!.padding)]" : "")
        )
        #endif
    }

    // MARK: - Constants

    /// Standard encoder delay for ffmpeg's libmp3lame (576 samples).
    /// PMS uses ffmpeg for its universal transcode pipeline.
    static let encoderDelay = 576

    /// Encoder delay and padding for LAME gapless playback.
    struct LAMEGaplessInfo {
        let delay: Int   // Samples to skip at start (typically 576)
        let padding: Int // Samples to skip at end (fills last frame)
    }

    // MARK: - ID3v2 Parsing

    /// Returns the size of the ID3v2 tag (header + body), or 0 if none.
    private static func id3v2TagSize(in data: Data) -> Int {
        // ID3v2 header: "ID3" + 2 version bytes + 1 flags byte + 4 syncsafe size bytes
        guard data.count >= 10,
              data[0] == 0x49, // 'I'
              data[1] == 0x44, // 'D'
              data[2] == 0x33  // '3'
        else { return 0 }

        // Synchsafe integer: 4 bytes, 7 bits each (MSB is always 0)
        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14)
                 | (Int(data[8]) << 7)  | Int(data[9])
        return 10 + size
    }

    // MARK: - XING Detection

    /// Check if the audio data already contains a XING or Info header.
    private static func hasXingHeader(data: Data, audioOffset: Int) -> Bool {
        guard audioOffset + 4 <= data.count else { return false }

        // Parse first frame to find XING offset within the frame
        guard let frameInfo = parseFirstMPEGFrame(data: data, offset: audioOffset) else {
            return false
        }

        let xingOffset = audioOffset + frameInfo.xingDataOffset
        guard xingOffset + 4 <= data.count else { return false }

        let tag = data[xingOffset..<(xingOffset + 4)]
        // "Xing" = 0x58696E67, "Info" = 0x496E666F
        return tag.elementsEqual([0x58, 0x69, 0x6E, 0x67])
            || tag.elementsEqual([0x49, 0x6E, 0x66, 0x6F])
    }

    // MARK: - MPEG Frame Parsing

    /// Key parameters parsed from an MPEG frame header.
    private struct MPEGFrameInfo {
        let mpegVersion: Int    // 1, 2, or 25 (for MPEG 2.5)
        let layer: Int          // 1, 2, or 3
        let sampleRate: Int     // e.g., 44100
        let channels: Int       // 1 (mono) or 2 (stereo/joint/dual)
        let headerBytes: [UInt8] // Raw 4-byte header for reuse in XING frame
        let frameSize: Int      // Size of this frame in bytes
        let xingDataOffset: Int // Byte offset where XING data should start within frame
        let samplesPerFrame: Int
    }

    /// Parse the MPEG frame header at the given offset.
    private static func parseFirstMPEGFrame(data: Data, offset: Int) -> MPEGFrameInfo? {
        // Scan for frame sync (0xFFE0 mask) in case there's junk between ID3 and audio
        var pos = offset
        while pos + 4 <= data.count {
            if data[pos] == 0xFF && (data[pos + 1] & 0xE0) == 0xE0 {
                if let info = parseMPEGHeader(data: data, offset: pos) {
                    return info
                }
            }
            pos += 1
        }
        return nil
    }

    private static func parseMPEGHeader(data: Data, offset: Int) -> MPEGFrameInfo? {
        guard offset + 4 <= data.count else { return nil }

        let b0 = data[offset]
        let b1 = data[offset + 1]
        let b2 = data[offset + 2]
        let b3 = data[offset + 3]

        // Frame sync check
        guard b0 == 0xFF && (b1 & 0xE0) == 0xE0 else { return nil }

        // MPEG version: bits 4-3 of byte 1
        let versionBits = (b1 >> 3) & 0x03
        let mpegVersion: Int
        switch versionBits {
        case 0: mpegVersion = 25  // MPEG 2.5
        case 2: mpegVersion = 2   // MPEG 2
        case 3: mpegVersion = 1   // MPEG 1
        default: return nil       // Reserved
        }

        // Layer: bits 2-1 of byte 1
        let layerBits = (b1 >> 1) & 0x03
        let layer: Int
        switch layerBits {
        case 1: layer = 3
        case 2: layer = 2
        case 3: layer = 1
        default: return nil  // Reserved
        }

        // Bitrate: bits 7-4 of byte 2
        let bitrateIndex = Int((b2 >> 4) & 0x0F)
        guard bitrateIndex > 0, bitrateIndex < 15 else { return nil }  // 0=free, 15=bad
        let bitrate = bitrateTable(version: mpegVersion, layer: layer, index: bitrateIndex)
        guard bitrate > 0 else { return nil }

        // Sample rate: bits 3-2 of byte 2
        let srIndex = Int((b2 >> 2) & 0x03)
        guard srIndex < 3 else { return nil }  // 3 = reserved
        let sampleRate = sampleRateTable(version: mpegVersion, index: srIndex)
        guard sampleRate > 0 else { return nil }

        // Padding: bit 1 of byte 2
        let padding = Int((b2 >> 1) & 0x01)

        // Channel mode: bits 7-6 of byte 3
        let channelMode = Int((b3 >> 6) & 0x03)
        let channels = channelMode == 3 ? 1 : 2  // 3 = mono

        // Samples per frame
        let samplesPerFrame: Int
        if layer == 1 {
            samplesPerFrame = 384
        } else if mpegVersion == 1 {
            samplesPerFrame = 1152
        } else {
            samplesPerFrame = 576
        }

        // Frame size calculation
        let frameSize: Int
        if layer == 1 {
            frameSize = (12 * bitrate * 1000 / sampleRate + padding) * 4
        } else {
            let slotSize = layer == 3 ? 1 : 1
            frameSize = samplesPerFrame / 8 * bitrate * 1000 / sampleRate + padding * slotSize
        }

        guard frameSize > 0 else { return nil }

        // XING header offset within the frame (after header + side info)
        let xingDataOffset: Int
        if mpegVersion == 1 {
            xingDataOffset = channels == 1 ? 21 : 36
        } else {
            xingDataOffset = channels == 1 ? 13 : 21
        }

        return MPEGFrameInfo(
            mpegVersion: mpegVersion,
            layer: layer,
            sampleRate: sampleRate,
            channels: channels,
            headerBytes: [b0, b1, b2, b3],
            frameSize: frameSize,
            xingDataOffset: xingDataOffset,
            samplesPerFrame: samplesPerFrame
        )
    }

    // MARK: - Frame Counting

    private struct FrameStats {
        let frameCount: Int
        let totalBytes: Int
    }

    /// Walk the file counting MPEG frames and total audio data size.
    private static func countFrames(data: Data, offset: Int) -> FrameStats {
        var pos = offset
        var frameCount = 0
        let dataCount = data.count

        // Find the first valid frame to get baseline parameters
        guard let firstFrame = parseFirstMPEGFrame(data: data, offset: offset) else {
            return FrameStats(frameCount: 0, totalBytes: 0)
        }

        // Advance pos to the first frame sync we actually found
        while pos + 4 <= dataCount {
            if data[pos] == 0xFF && (data[pos + 1] & 0xE0) == 0xE0 {
                if parseMPEGHeader(data: data, offset: pos) != nil {
                    break
                }
            }
            pos += 1
        }

        let audioStart = pos

        // Walk through frames
        while pos + 4 <= dataCount {
            guard data[pos] == 0xFF && (data[pos + 1] & 0xE0) == 0xE0 else {
                // Lost sync — try to find next frame
                pos += 1
                continue
            }

            guard let frame = parseMPEGHeader(data: data, offset: pos) else {
                pos += 1
                continue
            }

            // Validate frame parameters match the first frame
            guard frame.sampleRate == firstFrame.sampleRate,
                  frame.layer == firstFrame.layer,
                  frame.mpegVersion == firstFrame.mpegVersion else {
                pos += 1
                continue
            }

            frameCount += 1
            pos += frame.frameSize
        }

        let totalBytes = dataCount - audioStart
        return FrameStats(frameCount: frameCount, totalBytes: totalBytes)
    }

    // MARK: - XING Frame Construction

    /// Build a complete MPEG frame containing a XING VBR header.
    /// The frame uses the lowest valid bitrate to keep it small,
    /// and is filled with silence so it doesn't produce audible output.
    /// When gapless info is provided, a LAME extension with encoder delay/padding
    /// is appended so AVPlayer can trim silence at track boundaries.
    private static func buildXingFrame(
        frameInfo: MPEGFrameInfo,
        totalFrames: Int,
        totalAudioBytes: Int,
        gaplessInfo: LAMEGaplessInfo? = nil
    ) -> Data? {
        // XING payload: 4 (tag) + 4 (flags) + 4 (frames) + 4 (bytes) = 16 bytes
        // LAME extension: 36 bytes (version, delay/padding, CRC, etc.)
        let xingPayloadSize = 16
        let lameExtensionSize = gaplessInfo != nil ? 36 : 0
        let requiredContentSize = frameInfo.xingDataOffset + xingPayloadSize + lameExtensionSize

        // Find a bitrate that produces a frame large enough for the payload.
        // Start with minimum bitrate; step up if frame is too small for LAME extension.
        let bitrate = findBitrateForFrameSize(
            version: frameInfo.mpegVersion,
            layer: frameInfo.layer,
            sampleRate: frameInfo.sampleRate,
            samplesPerFrame: frameInfo.samplesPerFrame,
            minimumSize: requiredContentSize
        )
        guard bitrate > 0 else { return nil }

        // Calculate frame size at chosen bitrate (no padding)
        let frameSize: Int
        if frameInfo.layer == 1 {
            frameSize = (12 * bitrate * 1000 / frameInfo.sampleRate) * 4
        } else {
            frameSize = frameInfo.samplesPerFrame / 8 * bitrate * 1000 / frameInfo.sampleRate
        }
        guard frameSize >= requiredContentSize else { return nil }

        // Build the 4-byte MPEG header for the XING frame
        let header = buildMPEGHeader(
            version: frameInfo.mpegVersion,
            layer: frameInfo.layer,
            bitrate: bitrate,
            sampleRate: frameInfo.sampleRate,
            channels: frameInfo.channels,
            padding: false
        )
        guard header.count == 4 else { return nil }

        // Create frame filled with zeros (silence)
        var frame = Data(count: frameSize)
        frame[0] = header[0]
        frame[1] = header[1]
        frame[2] = header[2]
        frame[3] = header[3]

        // Write XING header at the correct offset (after side information)
        var offset = frameInfo.xingDataOffset

        // "Xing" identifier
        frame[offset] = 0x58; frame[offset+1] = 0x69
        frame[offset+2] = 0x6E; frame[offset+3] = 0x67
        offset += 4

        // Flags: frames present (bit 0) + bytes present (bit 1) = 0x03
        frame[offset] = 0x00; frame[offset+1] = 0x00
        frame[offset+2] = 0x00; frame[offset+3] = 0x03
        offset += 4

        // Total frames (big-endian 32-bit)
        frame[offset]   = UInt8((totalFrames >> 24) & 0xFF)
        frame[offset+1] = UInt8((totalFrames >> 16) & 0xFF)
        frame[offset+2] = UInt8((totalFrames >> 8) & 0xFF)
        frame[offset+3] = UInt8(totalFrames & 0xFF)
        offset += 4

        // Total audio bytes (big-endian 32-bit)
        frame[offset]   = UInt8((totalAudioBytes >> 24) & 0xFF)
        frame[offset+1] = UInt8((totalAudioBytes >> 16) & 0xFF)
        frame[offset+2] = UInt8((totalAudioBytes >> 8) & 0xFF)
        frame[offset+3] = UInt8(totalAudioBytes & 0xFF)
        offset += 4

        // LAME extension — encoder delay and padding for gapless playback.
        // Layout (36 bytes total):
        //   0-8: encoder version string (9 bytes, e.g. "LAVC60.3\0")
        //   9:   info tag revision (4 bits) + VBR method (4 bits)
        //  10:   lowpass frequency / 100
        //  11-18: replay gain (8 bytes)
        //  19:  encoding flags (4 bits) + ATH type (4 bits)
        //  20:  minimum bitrate
        //  21-23: encoder delay (12 bits) + padding (12 bits) ← KEY for gapless
        //  24:  misc
        //  25:  MP3 gain
        //  26-27: preset / surround info
        //  28-31: music length (total file size)
        //  32-33: music CRC
        //  34-35: info tag CRC
        if let gapless = gaplessInfo {
            let lameStart = offset

            // Encoder version: "Lavf" (PMS uses ffmpeg/libavformat)
            let versionBytes: [UInt8] = [0x4C, 0x61, 0x76, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00]
            for (i, b) in versionBytes.enumerated() {
                frame[lameStart + i] = b
            }

            // Delay (12 bits) + padding (12 bits) packed into 3 bytes at offset 21
            let delayClamp = min(gapless.delay, 0xFFF)
            let paddingClamp = min(gapless.padding, 0xFFF)
            frame[lameStart + 21] = UInt8((delayClamp >> 4) & 0xFF)
            frame[lameStart + 22] = UInt8(((delayClamp & 0x0F) << 4) | ((paddingClamp >> 8) & 0x0F))
            frame[lameStart + 23] = UInt8(paddingClamp & 0xFF)

            // Music length: total file bytes (XING frame + original audio)
            let musicLength = frameSize + totalAudioBytes
            frame[lameStart + 28] = UInt8((musicLength >> 24) & 0xFF)
            frame[lameStart + 29] = UInt8((musicLength >> 16) & 0xFF)
            frame[lameStart + 30] = UInt8((musicLength >> 8) & 0xFF)
            frame[lameStart + 31] = UInt8(musicLength & 0xFF)
        }

        return frame
    }

    /// Find the smallest standard bitrate that produces a frame large enough.
    private static func findBitrateForFrameSize(
        version: Int, layer: Int, sampleRate: Int,
        samplesPerFrame: Int, minimumSize: Int
    ) -> Int {
        for index in 1..<15 {
            let br = bitrateTable(version: version, layer: layer, index: index)
            guard br > 0 else { continue }
            let size: Int
            if layer == 1 {
                size = (12 * br * 1000 / sampleRate) * 4
            } else {
                size = samplesPerFrame / 8 * br * 1000 / sampleRate
            }
            if size >= minimumSize {
                return br
            }
        }
        return 0
    }

    /// Build a 4-byte MPEG audio frame header.
    private static func buildMPEGHeader(
        version: Int, layer: Int, bitrate: Int,
        sampleRate: Int, channels: Int, padding: Bool
    ) -> Data {
        // Byte 0: 0xFF (sync)
        // Byte 1: sync(3) + version(2) + layer(2) + protection(1)
        let versionBits: UInt8
        switch version {
        case 1: versionBits = 0x03
        case 2: versionBits = 0x02
        case 25: versionBits = 0x00
        default: return Data()
        }

        let layerBits: UInt8
        switch layer {
        case 1: layerBits = 0x03
        case 2: layerBits = 0x02
        case 3: layerBits = 0x01
        default: return Data()
        }

        let b1: UInt8 = 0xE0 | (versionBits << 3) | (layerBits << 1) | 0x01 // no CRC

        // Byte 2: bitrate(4) + samplerate(2) + padding(1) + private(1)
        let bitrateIndex = bitrateIndex(version: version, layer: layer, bitrate: bitrate)
        guard bitrateIndex > 0 else { return Data() }

        let srIndex = sampleRateIndex(version: version, sampleRate: sampleRate)
        guard srIndex >= 0 else { return Data() }

        let paddingBit: UInt8 = padding ? 0x02 : 0x00
        let b2: UInt8 = (UInt8(bitrateIndex) << 4) | (UInt8(srIndex) << 2) | paddingBit

        // Byte 3: channel mode(2) + mode ext(2) + copyright(1) + original(1) + emphasis(2)
        let channelMode: UInt8 = channels == 1 ? 0xC0 : 0x00  // mono : stereo
        let b3: UInt8 = channelMode

        return Data([0xFF, b1, b2, b3])
    }

    // MARK: - Lookup Tables

    /// MPEG bitrate table (kbps). Indexed by [version][layer][bitrateIndex].
    private static func bitrateTable(version: Int, layer: Int, index: Int) -> Int {
        // MPEG1 Layer III bitrates
        let v1l3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        // MPEG1 Layer II bitrates
        let v1l2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
        // MPEG1 Layer I bitrates
        let v1l1 = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
        // MPEG2/2.5 Layer III bitrates
        let v2l3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        // MPEG2/2.5 Layer II bitrates
        let v2l2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        // MPEG2/2.5 Layer I bitrates
        let v2l1 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]

        guard index >= 0 && index < 15 else { return 0 }

        if version == 1 {
            switch layer {
            case 1: return v1l1[index]
            case 2: return v1l2[index]
            case 3: return v1l3[index]
            default: return 0
            }
        } else {
            switch layer {
            case 1: return v2l1[index]
            case 2: return v2l2[index]
            case 3: return v2l3[index]
            default: return 0
            }
        }
    }

    /// Sample rate table (Hz).
    private static func sampleRateTable(version: Int, index: Int) -> Int {
        switch version {
        case 1:  return [44100, 48000, 32000][index]
        case 2:  return [22050, 24000, 16000][index]
        case 25: return [11025, 12000, 8000][index]
        default: return 0
        }
    }

    /// Minimum valid bitrate for a given MPEG version/layer.
    private static func minimumBitrate(version: Int, layer: Int) -> Int {
        if version == 1 {
            return 32  // MPEG1 all layers start at 32 kbps
        } else {
            return layer == 1 ? 32 : 8  // MPEG2/2.5 Layer I = 32, Layer II/III = 8
        }
    }

    /// Reverse lookup: find the bitrate index for a given bitrate.
    private static func bitrateIndex(version: Int, layer: Int, bitrate: Int) -> Int {
        for i in 1..<15 {
            if bitrateTable(version: version, layer: layer, index: i) == bitrate {
                return i
            }
        }
        return 0
    }

    /// Reverse lookup: find the sample rate index for a given sample rate.
    private static func sampleRateIndex(version: Int, sampleRate: Int) -> Int {
        let rates: [Int]
        switch version {
        case 1:  rates = [44100, 48000, 32000]
        case 2:  rates = [22050, 24000, 16000]
        case 25: rates = [11025, 12000, 8000]
        default: return -1
        }
        return rates.firstIndex(of: sampleRate) ?? -1
    }
}
