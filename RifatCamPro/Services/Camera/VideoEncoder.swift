import Foundation
import VideoToolbox
import CoreMedia
import Combine

@Observable
final class VideoEncoder {
    var isEncoding = false
    var currentBitrate: Int = 4_000_000
    var adaptiveBitrateEnabled = true

    private var compressionSession: VTCompressionSession?
    private let sessionLock = NSLock()
    private var frameCount: Int64 = 0
    private var lastEncodeTime: CFAbsoluteTime = 0
    private var consecutiveDrops: Int = 0
    private var bitrateAdjustTimer: DispatchSource?
    private var bitrateHistory: [BitrateSample] = []
    private var sessionWidth: Int = 1920
    private var sessionHeight: Int = 1080
    private var sessionFrameRate: Int = 30
    private var sessionCodec: StreamingCodec = .h264

    private let encoderQueue = DispatchQueue(label: "com.rifatcam.videoencoder", qos: .userInteractive)
    private let callbackQueue = DispatchQueue(label: "com.rifatcam.videoencoder.callback")

    var onEncodedFrame: ((EncodedFrame) -> Void)?

    // MARK: - Lifecycle

    func startSession(
        width: Int,
        height: Int,
        bitrate: Int,
        frameRate: Int,
        codec: StreamingCodec
    ) throws {
        stopSession()

        sessionWidth = width
        sessionHeight = height
        currentBitrate = bitrate
        sessionFrameRate = frameRate
        sessionCodec = codec
        frameCount = 0
        consecutiveDrops = 0
        bitrateHistory.removeAll()

        let encoderSpecification: [String: Any]
        if codec == .hevc {
            encoderSpecification = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                kVTVideoEncoderSpecification_RealTime as String: true,
                kVTVideoEncoderSpecification_EncoderID as String: "com.apple.videotoolbox.videoencoder.hevc"
            ]
        } else {
            encoderSpecification = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                kVTVideoEncoderSpecification_RealTime as String: true,
                kVTVideoEncoderSpecification_EncoderID as String: "com.apple.videotoolbox.videoencoder.h264"
            ]
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: videoEncoderCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw AppError.encodingError("Failed to create compression session (status: \(status))")
        }

        self.compressionSession = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel(for: codec))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: frameRate * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: frameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowLongTermTemporalReferenceFrames, value: kCFBooleanFalse)

        if adaptiveBitrateEnabled {
            let dataRateLimit = bitrate * 15 / 100
            let dataRateLimitBytes = NSNumber(value: dataRateLimit / 8)
            let dataRateLimitDuration = NSNumber(value: 1)
            let dataRateLimits = [dataRateLimitBytes, dataRateLimitDuration] as CFArray
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        isEncoding = true
        startBitrateMonitoring()
    }

    func stopSession() {
        bitrateAdjustTimer?.cancel()
        bitrateAdjustTimer = nil

        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard let session = compressionSession else { return }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        compressionSession = nil
        isEncoding = false
        frameCount = 0
        consecutiveDrops = 0
    }

    // MARK: - Encoding

    func encode(sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        guard isEncoding else { return nil }

        sessionLock.lock()
        guard let session = compressionSession else {
            sessionLock.unlock()
            return nil
        }
        sessionLock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        frameCount += 1

        var flags: VTEncodeInfoFlags = []
        var status: OSStatus = noErr

        status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )

        if status != noErr {
            consecutiveDrops += 1
            if adaptiveBitrateEnabled {
                handleAdaptiveBitrate(dropped: true)
            }
            return nil
        }

        consecutiveDrops = 0
        return nil
    }

    func encodeSynchronous(sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        guard isEncoding else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var resultFrame: EncodedFrame?

        let callback: @Sendable (EncodedFrame) -> Void = { frame in
            resultFrame = frame
            semaphore.signal()
        }

        sessionLock.lock()
        guard let session = compressionSession else {
            sessionLock.unlock()
            return nil
        }
        sessionLock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        frameCount += 1

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: Unmanaged.passRetained(CallbackBox(callback: callback)).toOpaque(),
            infoFlagsOut: &flags
        )

        if status == noErr {
            _ = semaphore.wait(timeout: .now() + 1.0)
            return resultFrame
        }

        return nil
    }

    // MARK: - Bitrate Management

    func adjustBitrate(to bitrate: Int) {
        let clampedBitrate = max(500_000, min(bitrate, 50_000_000))
        currentBitrate = clampedBitrate

        sessionLock.lock()
        guard let session = compressionSession else {
            sessionLock.unlock()
            return
        }
        sessionLock.unlock()

        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: clampedBitrate)
        )

        if adaptiveBitrateEnabled {
            let dataRateLimit = clampedBitrate * 15 / 100
            let dataRateLimitBytes = NSNumber(value: dataRateLimit / 8)
            let dataRateLimitDuration = NSNumber(value: 1)
            let dataRateLimits = [dataRateLimitBytes, dataRateLimitDuration] as CFArray
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                value: dataRateLimits
            )
        }
    }

    func handleAdaptiveBitrate(dropped: Bool) {
        guard adaptiveBitrateEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        bitrateHistory.append(BitrateSample(dropped: dropped, timestamp: now))
        bitrateHistory.removeAll { now - $0.timestamp > 5.0 }

        let recentDrops = bitrateHistory.filter { $0.dropped }.count
        let recentTotal = bitrateHistory.count
        guard recentTotal >= 10 else { return }

        let dropRate = Double(recentDrops) / Double(recentTotal)

        if dropRate > 0.15 {
            let newBitrate = Int(Double(currentBitrate) * 0.75)
            adjustBitrate(to: newBitrate)
            bitrateHistory.removeAll()
        } else if dropRate < 0.01 {
            let newBitrate = Int(Double(currentBitrate) * 1.1)
            let maxBitrate = baseBitrateForResolution() * 150 / 100
            adjustBitrate(to: min(newBitrate, maxBitrate))
        }
    }

    func resetBitrate() {
        adjustBitrate(to: baseBitrateForResolution())
        bitrateHistory.removeAll()
        consecutiveDrops = 0
    }

    // MARK: - Private Helpers

    private func profileLevel(for codec: StreamingCodec) -> String {
        switch codec {
        case .h264:
            if sessionWidth >= 1920 {
                return kVTProfileLevel_H264_High_AutoLevel as String
            } else if sessionWidth >= 1280 {
                return kVTProfileLevel_H264_Main_AutoLevel as String
            } else {
                return kVTProfileLevel_H264_Baseline_AutoLevel as String
            }
        case .hevc:
            return kVTProfileLevel_HEVC_Main_AutoLevel as String
        default:
            return kVTProfileLevel_H264_High_AutoLevel as String
        }
    }

    private func baseBitrateForResolution() -> Int {
        switch (sessionWidth, sessionFrameRate) {
        case (3840, _): return 12_000_000
        case (1920, 60): return 8_000_000
        case (1920, _): return 4_000_000
        case (1280, 60): return 4_000_000
        case (1280, _): return 2_000_000
        case (640, _): return 1_000_000
        default: return 4_000_000
        }
    }

    private func startBitrateMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: encoderQueue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isEncoding else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastEncodeTime > 5.0 && self.frameCount > 0 && !self.adaptiveBitrateEnabled {
                self.adjustBitrate(to: self.baseBitrateForResolution())
            }
        }
        timer.resume()
        bitrateAdjustTimer = timer
    }
}

// MARK: - Callback

private func videoEncoderCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let sampleBuffer else { return }

    if let refcon = sourceFrameRefCon {
        let unmanaged = Unmanaged<CallbackBox>.fromOpaque(refcon)
        let callbackBox = unmanaged.takeRetainedValue()
        let frame = EncodedFrame(
            data: encodeSampleBufferToData(sampleBuffer),
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            isKeyFrame: isKeyFrame(sampleBuffer),
            frameType: isKeyFrame(sampleBuffer) ? "I" : "P"
        )
        callbackBox.callback(frame)
        return
    }

    if let encoderRefcon = outputCallbackRefCon {
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(encoderRefcon).takeUnretainedValue()
        let frame = EncodedFrame(
            data: encodeSampleBufferToData(sampleBuffer),
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            isKeyFrame: isKeyFrame(sampleBuffer),
            frameType: isKeyFrame(sampleBuffer) ? "I" : "P"
        )
        encoder.callbackQueue.async {
            encoder.onEncodedFrame?(frame)
        }
    }
}

private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) else {
        return false
    }
    let count = CFArrayGetCount(attachments)
    guard count > 0 else { return false }

    let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
    guard let notSync = CFDictionaryGetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) else {
        return true
    }
    let notSyncValue = unsafeBitCast(notSync, to: CFBoolean.self)
    return !CFBooleanGetValue(notSyncValue)
}

private func encodeSampleBufferToData(_ sampleBuffer: CMSampleBuffer) -> Data {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return Data()
    }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard status == noErr, let pointer = dataPointer, totalLength > 0 else {
        return Data()
    }
    return Data(bytes: pointer, count: totalLength)
}

// MARK: - Callback Box

private final class CallbackBox {
    let callback: @Sendable (EncodedFrame) -> Void
    init(callback: @escaping @Sendable (EncodedFrame) -> Void) {
        self.callback = callback
    }
}

// MARK: - Models

struct EncodedFrame: Sendable {
    let data: Data
    let timestamp: CMTime
    let isKeyFrame: Bool
    let frameType: String

    var timestampSeconds: Double {
        CMTimeGetSeconds(timestamp)
    }
}

struct BitrateSample: Sendable {
    let dropped: Bool
    let timestamp: CFAbsoluteTime
}
