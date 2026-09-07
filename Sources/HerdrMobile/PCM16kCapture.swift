import AVFoundation
import Foundation

/// Microphone → 16-bit PCM, 16 kHz, mono (Gemini Live Transcribe input).
final class PCM16kCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var onChunk: ((Data) -> Void)?

    func start(onChunk: @escaping (Data) -> Void) throws {
        stop()
        self.onChunk = onChunk

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw GeminiLiveError.encoding
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw GeminiLiveError.encoding
        }
        converter = AVAudioConverter(from: inputFormat, to: target)

        let bufferSize: AVAudioFrameCount = 2_048
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer, target: target)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        onChunk = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return }
        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        converter.reset()
        guard error == nil, out.frameLength > 0, let channels = out.int16ChannelData else { return }
        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        onChunk?(Data(bytes: channels[0], count: byteCount))
    }
}
