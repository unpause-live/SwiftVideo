#if os(macOS) || os(iOS) || os(tvOS)
import Foundation
import AudioToolbox
import VectorMath
import CSwiftVideo

public class AppleAudioDecoder : Tx<CodedMediaSample, AudioSample> {
    public override init() {
        self.converter = nil
        self.asbdOut = nil
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            guard sample.mediaType() == .audio else {
                return .error(EventError("dec.sound.apple", -1, "Only audio samples are supported", assetId: sample.assetId()))
            }
            strongSelf.configure(sample)
            return strongSelf.handle(sample)
        }
    }
    
    private func handle(_ sample: CodedMediaSample) -> EventBox<AudioSample> {
        guard let converter = self.converter, let asbd = self.asbdOut else {
            return .error(EventError("dec.sound.apple", -2, "No converter found", assetId: sample.assetId()))
        }
        let dataLength = Int(asbd.mBytesPerPacket * asbd.mChannelsPerFrame) * self.samplesPerPacket
        guard dataLength > 0 else {
            return .error(EventError("dec.sound.apple", -3, "Invalid decoder state", assetId: sample.assetId()))
        }
        
        var data = Data(count: dataLength)
        
        let result = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> OSStatus in
            var sampleBuffer = sample.data()
            return sampleBuffer.withUnsafeMutableBytes {
                guard let baseAddress = buffer.baseAddress else {
                    return -1
                }
                var packet = PacketData(buffer: $0,
                                        bufferSize: $0.count,
                                        channelCount: asbd.mChannelsPerFrame,
                                        packetDesc: [AudioStreamPacketDescription(mStartOffset: 0,
                                                                                  mVariableFramesInPacket: 0,
                                                                                  mDataByteSize: UInt32(sample.data().count))])
                var packetSize = UInt32(self.samplesPerPacket)
                let audioBufferList = AudioBufferList.allocate(maximumBuffers: Int(asbd.mChannelsPerFrame))
                for i in 0..<Int(asbd.mChannelsPerFrame) {
                    audioBufferList[i] = AudioBuffer(mNumberChannels: 1,
                                                     mDataByteSize: UInt32(dataLength/Int(asbd.mChannelsPerFrame)),
                                                     mData: baseAddress+(i*self.samplesPerPacket*Int(asbd.mBytesPerPacket)))
                }
                return AudioConverterFillComplexBuffer(converter, ioProc, &packet, &packetSize, audioBufferList.unsafeMutablePointer, nil)
            }
        }
        if result == noErr {
            let pts = self.pts ?? rescale(sample.pts(), Int64(asbd.mSampleRate))
            let dur = TimePoint(Int64(self.samplesPerPacket), Int64(asbd.mSampleRate))
            self.pts = pts + dur
            let bufferSize = self.samplesPerPacket*Int(asbd.mBytesPerPacket)
            let buffers = (0..<Int(asbd.mChannelsPerFrame)).map { idx in
                data[idx*bufferSize..<idx*bufferSize+bufferSize]
            }
            let output = AudioSample(buffers,
                                     frequency: Int(asbd.mSampleRate),
                                     channels: Int(asbd.mChannelsPerFrame),
                                     format: .f32p,
                                     sampleCount: self.samplesPerPacket,
                                     time: sample.time(),
                                     pts: pts,
                                     assetId: sample.assetId(),
                                     workspaceId: sample.workspaceId(),
                                     workspaceToken: sample.workspaceToken(),
                                     eventInfo: sample.info())
            return .just(output)
        }
        return .error(EventError("dec.sound.apple", -4, "Decoder error: \(result)", assetId: sample.assetId()))
    }
    
    private func configure(_ sample: CodedMediaSample) {
        guard converter == nil else {
            return
        }
        switch sample.mediaFormat() {
        case .aac:
            do {
                if case .audio(let desc) = try basicMediaDescription(sample) {
                    self.samplesPerPacket = desc.samplesPerPacket
                    var asbdIn = AudioStreamBasicDescription(mSampleRate: Float64(desc.sampleRate),
                                                             mFormatID: kAudioFormatMPEG4AAC,
                                                             mFormatFlags: 0,
                                                             mBytesPerPacket: 0,
                                                             mFramesPerPacket: UInt32(desc.samplesPerPacket),
                                                             mBytesPerFrame: 0,
                                                             mChannelsPerFrame: UInt32(desc.channelCount),
                                                             mBitsPerChannel: 0,
                                                             mReserved: 0)
                    var asbdOut = AudioStreamBasicDescription(mSampleRate: Float64(desc.sampleRate),
                                                              mFormatID: kAudioFormatLinearPCM,
                                                              mFormatFlags: kAudioFormatFlagIsPacked | kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
                                                              mBytesPerPacket: 4,
                                                              mFramesPerPacket: 1,
                                                              mBytesPerFrame: 4,
                                                              mChannelsPerFrame: UInt32(desc.channelCount),
                                                              mBitsPerChannel: 32,
                                                              mReserved: 0)
                    self.asbdOut = asbdOut
                    var requiredCodecs = AudioClassDescription(mType: kAudioDecoderComponentType,
                                                               mSubType: kAudioFormatMPEG4AAC,
                                                               mManufacturer: kAudioUnitManufacturer_Apple)
                    var converter: AudioConverterRef? = nil
                    let result = AudioConverterNewSpecific(&asbdIn, &asbdOut, 1, &requiredCodecs, &converter)
                    print("AudioConverterNewSpecific: \(result)")
                    self.converter = converter
                }
            } catch {}
        case .opus:
            // TODO.
            ()
        default: ()
        }
        
    }
    var pts: TimePoint?
    var samplesPerPacket: Int = 0
    var asbdOut: AudioStreamBasicDescription?
    var converter: AudioConverterRef?
}

fileprivate struct PacketData {
    var buffer: UnsafeMutableRawBufferPointer?
    var bufferSize: Int
    let channelCount: UInt32
    var packetDesc: [AudioStreamPacketDescription]
}

fileprivate func ioProc(_ converter: AudioConverterRef,
                   _ ioNumDataPackets: UnsafeMutablePointer<UInt32>,
                   _ ioData: UnsafeMutablePointer<AudioBufferList>,
                   _ ioPacketDesc: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                   _ inUserData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = inUserData else {
        ioNumDataPackets.pointee = 0
        return -1
    }
    let packet = userData.bindMemory(to: PacketData.self, capacity: MemoryLayout<PacketData>.size)
    guard let buf = packet.pointee.buffer else {
        ioNumDataPackets.pointee = 0
        return -1
    }
    
    ioNumDataPackets.pointee = 1
    ioData.pointee.mNumberBuffers = 1
    let dataSize = buf.count
    let channelCount = packet.pointee.channelCount
    packet.pointee.packetDesc.withUnsafeMutableBytes {
        ioPacketDesc?.pointee = $0.baseAddress?.bindMemory(to: AudioStreamPacketDescription.self, capacity: $0.count)
    }
    let buffers = UnsafeMutableBufferPointer<AudioBuffer>(start: &ioData.pointee.mBuffers, count: 1)
    buffers[0] = AudioBuffer(mNumberChannels: channelCount,
                     mDataByteSize: UInt32(dataSize),
                     mData: buf.baseAddress)
    packet.pointee.buffer = nil
    return noErr;
}
#endif
