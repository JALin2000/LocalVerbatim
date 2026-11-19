// Concatenated with the actual AudioCapture.swift by run_swift_tests.sh,
// so private audio conversion/recording helpers can be tested offline.
@main struct CaptureUnitChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("localverbatim-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = try CaptureTrack(source: "microphone", directory: directory, chunks: directory)
        var chunks: [AudioChunk] = []
        for block in 0..<92 {
            let offset = block * 4000
            let samples = (0..<4000).map { Float(sin(Double(offset + $0) * 2 * .pi * 440 / 16000)) * 0.25 }
            try track.append(samples, at: Double(offset) / 16000, onChunk: { chunks.append($0) })
        }
        try track.finish(onChunk: { chunks.append($0) })
        precondition(chunks.count == 2, "expected overlapping full and partial chunks")
        precondition(chunks[0].start == 0 && chunks[0].end == 18)
        precondition(chunks[1].start == 17.25 && chunks[1].end == 23)
        let silence = try CaptureTrack(source: "system", directory: directory, chunks: directory)
        var silentChunks = 0
        try silence.pad(to: 368000, onChunk: { _ in silentChunks += 1 })
        try silence.finish(onChunk: { _ in silentChunks += 1 })
        precondition(silentChunks == 0)
        let microphoneData = try Data(contentsOf: directory.appendingPathComponent("microphone.wav"))
        let systemData = try Data(contentsOf: directory.appendingPathComponent("system.wav"))
        precondition(microphoneData.count == 44 + 368000 * 2)
        precondition(systemData.count == microphoneData.count)
        precondition(systemData.dropFirst(44).allSatisfy { $0 == 0 })
        var blocked = false
        do { _ = try PCM16WaveWriter(url: directory.appendingPathComponent("microphone.wav")) }
        catch { blocked = true }
        let retained = try Data(contentsOf: directory.appendingPathComponent("microphone.wav"))
        precondition(blocked && retained == microphoneData, "exclusive creation must preserve prior audio")

        var pause = [Float](repeating: 0.12, count: AudioWindowing.maximumFrames)
        let gapStart = 204_160 // 12.76 seconds
        let gapEnd = 218_880 // 13.68 seconds; not the midpoint of the pause
        pause.replaceSubrange(gapStart..<gapEnd, with: repeatElement(Float(0), count: gapEnd - gapStart))
        let cut = AudioWindowing.boundary(pcm16: AudioWindowing.pcm16(pause))
        precondition(cut.frames == gapEnd && cut.overlap == 12_000)
        precondition(cut.advance >= gapStart, "overlap must remain inside the pause")
        var shorter = [Float](repeating: 0.12, count: AudioWindowing.maximumFrames)
        shorter.replaceSubrange(160_000..<170_400, with: repeatElement(Float(0), count: 10_400))
        let shortCut = AudioWindowing.boundary(pcm16: AudioWindowing.pcm16(shorter))
        precondition(shortCut.frames == 170_400 && shortCut.overlap == 9_360)
        precondition(shortCut.advance > 160_000)
        let adaptive = try CaptureTrack(source: "adaptive", directory: directory, chunks: directory)
        var adaptiveChunks: [AudioChunk] = []
        try adaptive.append(pause, at: 0, onChunk: { adaptiveChunks.append($0) })
        try adaptive.finish(onChunk: { adaptiveChunks.append($0) })
        precondition(adaptiveChunks.count == 2)
        precondition(adaptiveChunks[0].end == 13.68 && adaptiveChunks[1].start == 12.93)
        // Optional real English/Mandarin recording, supplied explicitly by the
        // caller. It stays outside the source tree and is not copied or played.
        if let path = ProcessInfo.processInfo.environment["LOCALVERBATIM_BOUNDARY_FIXTURE"] {
            let fixture = try Data(contentsOf: URL(fileURLWithPath: path))
            let offset = Int(ProcessInfo.processInfo.environment["LOCALVERBATIM_BOUNDARY_OFFSET_FRAMES"] ?? "0") ?? 0
            let pcm = Data(fixture.dropFirst(44 + offset * 2).prefix(AudioWindowing.maximumFrames * 2))
            let actual = AudioWindowing.boundary(pcm16: pcm)
            let expected = Double(ProcessInfo.processInfo.environment["LOCALVERBATIM_BOUNDARY_EXPECTED_END"] ?? "13.68") ?? 13.68
            precondition(abs(Double(actual.frames) / 16000 - expected) <= 0.03, "real bilingual pause boundary: \(Double(actual.frames) / 16000)")
            print("PASS: real English/Mandarin pause ends at \(Double(actual.frames) / 16000) s; overlap stays in silence")
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        pcm.frameLength = 4800
        for channel in 0..<2 {
            for i in 0..<4800 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.25 }
        }
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 4800, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        precondition(CMSampleBufferMakeDataReady(sample!) == noErr)
        let converterTrack = try CaptureTrack(source: "convert", directory: directory, chunks: directory)
        let converted = try converterTrack.convert(sample!)
        precondition(converted.count >= 1100 && converted.count <= 1650, "unexpected resample length: \(converted.count)")
        precondition(converted.allSatisfy { $0.isFinite })
        precondition(converted.max()! > 0.20 && converted.max()! < 0.30)
        try converterTrack.append(converted + [.nan, .infinity, 100], at: 0, onChunk: { _ in })
        try converterTrack.finish(onChunk: { _ in })
        print("PASS: conversion; archive integrity; fixed/adaptive pause-end boundaries; overlap within silence; partial tails; exclusive creation; nonfinite clipping")
    }
}
