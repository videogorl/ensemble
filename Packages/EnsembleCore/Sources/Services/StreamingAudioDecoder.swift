import AudioToolbox
import AVFoundation
import Foundation

final class StreamingAudioDecoder {
    enum DecoderError: Error {
        case openFailed(OSStatus)
        case parseFailed(OSStatus)
        case missingFormat
    }

    var onFormatReady: ((AVAudioFormat) -> Void)?
    var onFirstPacket: (() -> Void)?
    var onFirstPCM: (() -> Void)?
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var streamID: AudioFileStreamID?
    private var inputFormatDescription: AudioStreamBasicDescription?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var maximumPacketSize: UInt32 = 0
    private let fileExtension: String
    private var pendingInitialData = Data()
    private struct RawPacketBatch {
        let data: Data
        let packetCount: UInt32
        let packetDescriptions: [AudioStreamPacketDescription]?
    }
    private var pendingPacketBatches: [RawPacketBatch] = []
    private var pendingInputBuffers: [AVAudioBuffer] = []
    private var hasReportedFirstPacket = false
    private var hasReportedFirstPCM = false
    /// The converter rejected at least one packet; that packet's audio is missing from the output.
    private(set) var conversionFailed = false
    private var isReadyForPackets = false

    init(fileExtension: String) throws {
        self.fileExtension = fileExtension.lowercased()
        var id: AudioFileStreamID?
        let status = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            Self.propertyListener,
            Self.packetListener,
            Self.fileTypeHint(forExtension: fileExtension),
            &id
        )
        guard status == noErr, let id else {
            throw DecoderError.openFailed(status)
        }
        streamID = id
    }

    deinit {
        if let streamID {
            AudioFileStreamClose(streamID)
        }
    }

    func append(_ data: Data) throws {
        if shouldBufferInitialData {
            pendingInitialData.append(data)
            guard pendingInitialData.count >= Self.minimumMP3InitialParseBytes else { return }
            let buffered = pendingInitialData
            pendingInitialData.removeAll(keepingCapacity: true)
            try parse(buffered)
            return
        }

        if !pendingInitialData.isEmpty {
            pendingInitialData.append(data)
            let buffered = pendingInitialData
            pendingInitialData.removeAll(keepingCapacity: true)
            try parse(buffered)
            return
        }

        try parse(data)
    }

    private var shouldBufferInitialData: Bool {
        fileExtension == "mp3" && !hasReportedFirstPacket && pendingInitialData.count < Self.minimumMP3InitialParseBytes
    }

    private static let minimumMP3InitialParseBytes = 16 * 1024

    private func parse(_ data: Data) throws {
        guard let streamID else { throw DecoderError.missingFormat }
        let status = data.withUnsafeBytes { bytes in
            AudioFileStreamParseBytes(
                streamID,
                UInt32(data.count),
                bytes.baseAddress,
                []
            )
        }
        guard status == noErr else {
            throw DecoderError.parseFailed(status)
        }
        configureConverterIfPossible()
        drainPendingPacketBatches()
        drainPendingInputBuffers()
    }

    private func handleProperty(_ propertyID: AudioFileStreamPropertyID) {
        guard let streamID else { return }

        switch propertyID {
        case kAudioFileStreamProperty_DataFormat:
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFileStreamGetProperty(streamID, propertyID, &size, &format) == noErr else { return }
            inputFormatDescription = format

        case kAudioFileStreamProperty_ReadyToProducePackets:
            isReadyForPackets = true

        case kAudioFileStreamProperty_MaximumPacketSize:
            var packetSize: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileStreamGetProperty(streamID, propertyID, &size, &packetSize) == noErr {
                maximumPacketSize = packetSize
            }

        default:
            break
        }
    }

    private func configureConverterIfPossible() {
        guard isReadyForPackets,
              converter == nil,
              var inputDescription = inputFormatDescription,
              let input = AVAudioFormat(streamDescription: &inputDescription) else {
            return
        }

        let channels = max(inputDescription.mChannelsPerFrame, 1)
        guard let output = AVAudioFormat(
            standardFormatWithSampleRate: inputDescription.mSampleRate,
            channels: channels
        ), let converter = AVAudioConverter(from: input, to: output) else {
            return
        }

        inputFormat = input
        outputFormat = output
        self.converter = converter
        onFormatReady?(output)
    }

    private func handlePackets(
        byteCount: UInt32,
        packetCount: UInt32,
        inputData: UnsafeRawPointer,
        packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard packetCount > 0 else { return }
        if !hasReportedFirstPacket {
            hasReportedFirstPacket = true
            onFirstPacket?()
        }

        let data = Data(bytes: inputData, count: Int(byteCount))
        let descriptions: [AudioStreamPacketDescription]? = packetDescriptions.map { pointer in
            (0 ..< Int(packetCount)).map { pointer[$0] }
        }
        pendingPacketBatches.append(RawPacketBatch(
            data: data,
            packetCount: packetCount,
            packetDescriptions: descriptions
        ))
    }

    private func drainPendingPacketBatches() {
        guard converter != nil, inputFormat != nil else { return }
        while !pendingPacketBatches.isEmpty {
            let batch = pendingPacketBatches.removeFirst()
            guard let inputBuffer = batch.data.withUnsafeBytes({ bytes in
                makeInputBuffer(
                    byteCount: UInt32(batch.data.count),
                    packetCount: batch.packetCount,
                    inputData: bytes.baseAddress!,
                    packetDescriptions: batch.packetDescriptions
                )
            }) else {
                continue
            }
            pendingInputBuffers.append(inputBuffer)
        }
    }

    /// Wraps one parsed packet batch in the buffer type the converter needs.
    /// Both compressed-buffer initializers raise for linear PCM, A-law, and µ-law;
    /// AVFAudio stores those in PCM buffers instead.
    private func makeInputBuffer(
        byteCount: UInt32,
        packetCount: UInt32,
        inputData: UnsafeRawPointer,
        packetDescriptions: [AudioStreamPacketDescription]?
    ) -> AVAudioBuffer? {
        guard let inputFormat else { return nil }
        let description = inputFormat.streamDescription.pointee
        if [kAudioFormatLinearPCM, kAudioFormatULaw, kAudioFormatALaw].contains(description.mFormatID) {
            return makePCMBuffer(format: inputFormat, byteCount: byteCount, inputData: inputData)
        }
        if description.mBytesPerPacket > 0 {
            return makeConstantBitrateBuffer(
                format: inputFormat,
                bytesPerPacket: description.mBytesPerPacket,
                byteCount: byteCount,
                inputData: inputData
            )
        }
        guard let packetDescriptions else {
            EnsembleLogger.debug("[StreamingAudioDecoder] dropped variable-bitrate packets without descriptions")
            return nil
        }
        return makeVariableBitrateBuffer(
            format: inputFormat,
            byteCount: byteCount,
            packetCount: packetCount,
            inputData: inputData,
            packetDescriptions: packetDescriptions
        )
    }

    private func makePCMBuffer(
        format: AVAudioFormat,
        byteCount: UInt32,
        inputData: UnsafeRawPointer
    ) -> AVAudioPCMBuffer? {
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = AVAudioFrameCount(byteCount / bytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        // Audio files store PCM interleaved, so the buffer holds a single audio buffer.
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard audioBuffers.count == 1, let target = audioBuffers[0].mData else { return nil }
        let copiedByteCount = Int(frameCount * bytesPerFrame)
        target.copyMemory(from: inputData, byteCount: copiedByteCount)
        audioBuffers[0].mDataByteSize = UInt32(copiedByteCount)
        buffer.frameLength = frameCount
        return buffer
    }

    private func makeConstantBitrateBuffer(
        format: AVAudioFormat,
        bytesPerPacket: UInt32,
        byteCount: UInt32,
        inputData: UnsafeRawPointer
    ) -> AVAudioCompressedBuffer? {
        let packetCount = AVAudioPacketCount(byteCount / bytesPerPacket)
        guard packetCount > 0 else { return nil }
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: packetCount)
        let copiedByteCount = packetCount * bytesPerPacket
        buffer.data.copyMemory(from: inputData, byteCount: Int(copiedByteCount))
        buffer.packetCount = packetCount
        buffer.byteLength = copiedByteCount
        return buffer
    }

    private func makeVariableBitrateBuffer(
        format: AVAudioFormat,
        byteCount: UInt32,
        packetCount: UInt32,
        inputData: UnsafeRawPointer,
        packetDescriptions: [AudioStreamPacketDescription]
    ) -> AVAudioCompressedBuffer? {
        let describedMaxPacketSize = packetDescriptions.map(\.mDataByteSize).max() ?? 0
        let maxPacketSize = maximumPacketSize > 0
            ? max(maximumPacketSize, describedMaxPacketSize, byteCount)
            : max(1, describedMaxPacketSize, byteCount / max(packetCount, 1))
        let buffer = AVAudioCompressedBuffer(
            format: format,
            packetCapacity: AVAudioPacketCount(packetCount),
            maximumPacketSize: Int(maxPacketSize)
        )

        let target = buffer.data.assumingMemoryBound(to: UInt8.self)
        var targetOffset = 0
        var outputPacketIndex = 0
        for sourceDescription in packetDescriptions.prefix(Int(packetCount)) {
            let packetSize = Int(sourceDescription.mDataByteSize)
            guard packetSize > 0 else { continue }
            let source = inputData
                .advanced(by: Int(sourceDescription.mStartOffset))
                .assumingMemoryBound(to: UInt8.self)
            target.advanced(by: targetOffset).update(from: source, count: packetSize)
            buffer.packetDescriptions![outputPacketIndex] = AudioStreamPacketDescription(
                mStartOffset: Int64(targetOffset),
                mVariableFramesInPacket: sourceDescription.mVariableFramesInPacket,
                mDataByteSize: UInt32(packetSize)
            )
            targetOffset += packetSize
            outputPacketIndex += 1
        }
        guard outputPacketIndex > 0 else { return nil }
        buffer.packetCount = AVAudioPacketCount(outputPacketIndex)
        buffer.byteLength = UInt32(targetOffset)
        return buffer
    }

    private func drainPendingInputBuffers() {
        while !pendingInputBuffers.isEmpty {
            let buffer = pendingInputBuffers.removeFirst()
            decode(buffer)
        }
    }

    private func decode(_ inputBuffer: AVAudioBuffer) {
        guard let converter, let outputFormat else { return }

        var didFeedInput = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else { return }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if didFeedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didFeedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if status == .error {
                conversionFailed = true
                EnsembleLogger.debug("[StreamingAudioDecoder] conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
                return
            }

            if output.frameLength > 0 {
                if !hasReportedFirstPCM {
                    hasReportedFirstPCM = true
                    onFirstPCM?()
                }
                onPCMBuffer?(output)
            }

            switch status {
            case .haveData:
                if output.frameLength == 0 {
                    return
                }
            case .inputRanDry, .endOfStream:
                return
            case .error:
                return
            @unknown default:
                return
            }
        }
    }

    private static let propertyListener: AudioFileStream_PropertyListenerProc = { clientData, _, propertyID, _ in
        let decoder = Unmanaged<StreamingAudioDecoder>
            .fromOpaque(clientData)
            .takeUnretainedValue()
        decoder.handleProperty(propertyID)
    }

    private static let packetListener: AudioFileStream_PacketsProc = {
        clientData,
        byteCount,
        packetCount,
        inputData,
        packetDescriptions
    in
        let decoder = Unmanaged<StreamingAudioDecoder>
            .fromOpaque(clientData)
            .takeUnretainedValue()
        decoder.handlePackets(
            byteCount: byteCount,
            packetCount: packetCount,
            inputData: inputData,
            packetDescriptions: packetDescriptions
        )
    }

    private static func fileTypeHint(forExtension ext: String) -> AudioFileTypeID {
        switch ext.lowercased() {
        case "mp3":
            return kAudioFileMP3Type
        case "m4a", "mp4", "alac":
            return kAudioFileM4AType
        case "aac":
            return kAudioFileAAC_ADTSType
        case "flac":
            return kAudioFileFLACType
        case "wav", "wave":
            return kAudioFileWAVEType
        case "aif", "aiff", "aifc":
            return kAudioFileAIFFType
        case "caf":
            return kAudioFileCAFType
        default:
            return 0
        }
    }
}
