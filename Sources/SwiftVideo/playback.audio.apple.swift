#if os(macOS) || os(iOS) || os(tvOS)
import Foundation
import AudioToolbox

public class AppleAudioPlayback: Terminal<AudioSample> {
    public override init() {
        self.unit = nil
        self.samples = []
        self.pts = TimePoint(0, 1000)
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            guard sample.format() == .f32p else {
                return .error(EventError("playback.audio.apple", -1, "Currently only .f32p is supported"))
            }
            if strongSelf.unit == nil {
                var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sample.sampleRate()),
                                                       mFormatID: kAudioFormatLinearPCM,
                                                       mFormatFlags: kAudioFormatFlagIsPacked |
                                                            kAudioFormatFlagIsFloat |
                                                            kAudioFormatFlagIsNonInterleaved,
                                                       mBytesPerPacket: 4,
                                                       mFramesPerPacket: 1,
                                                       mBytesPerFrame: 4,
                                                       mChannelsPerFrame: UInt32(sample.numberChannels()),
                                                       mBitsPerChannel: 32,
                                                       mReserved: 0)

                var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                     componentSubType: kAudioUnitSubType_HALOutput,
                                                     componentManufacturer: kAudioUnitManufacturer_Apple,
                                                     componentFlags: 0,
                                                     componentFlagsMask: 0)
                var unit: AudioUnit?

                if let component = AudioComponentFindNext(nil, &desc),
                     AudioComponentInstanceNew(component, &unit) == noErr {
                    if let unit = unit {
                        strongSelf.pts = rescale(sample.pts(), Int64(sample.sampleRate()))
                        strongSelf.unit = unit
                        var callback = AURenderCallbackStruct(inputProc: ioProc, inputProcRefCon: bridge(strongSelf))
                        var flag: UInt32 = 1
                        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                            kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
                        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                            kAudioUnitScope_Output, 0, &flag, 4)
                        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                            kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
                        AudioUnitInitialize(unit)
                        AudioOutputUnitStart(unit)
                        AudioUnitSetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, 0.1, 0)
                    }
                }
            }
            if sample.pts() < strongSelf.pts {
                strongSelf.pts = rescale(sample.pts(), Int64(sample.sampleRate()))
                strongSelf.samples.removeAll(keepingCapacity: true)
                strongSelf.ptsOffset = nil
            }
            strongSelf.samples.append(sample)
            strongSelf.samples = strongSelf.samples.filter { ($0.pts() + $0.duration()) > strongSelf.pts }
            return .nothing(sample.info())
        }
    }
    deinit {
        if let unit = self.unit {
            AudioOutputUnitStop(unit)
        }
    }
    private var unit: AudioUnit?
    fileprivate var samples: [AudioSample]
    fileprivate var pts: TimePoint
    fileprivate var ptsOffset: TimePoint?
}

private func ioProc(inRefCon: UnsafeMutableRawPointer,
                    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                    audioTimestamp: UnsafePointer<AudioTimeStamp>,
                    inBusNumber: UInt32,
                    inNumberFrames: UInt32,
                    ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let buffers = UnsafeMutableAudioBufferListPointer(ioData) else {
        return -1
    }
    let this: AppleAudioPlayback = bridge(from: inRefCon)
    if this.ptsOffset == nil {
        this.ptsOffset =  this.pts - TimePoint(Int64(audioTimestamp.pointee.mSampleTime), this.pts.scale)
    }
    guard let ptsOffset = this.ptsOffset else {
        return -1
    }
    let windowStart = this.pts - ptsOffset
    let windowEnd = windowStart + TimePoint(Int64(inNumberFrames), windowStart.scale)
    buffers.forEach {
        guard let ptr = $0.mData else {
            return
        }
        memset(ptr, 0, Int($0.mDataByteSize))
    }
    let samples = Array(this.samples)
    samples.forEach { sample in
        let sampleStart = rescale(sample.pts(), this.pts.scale)
        let sampleEnd = sampleStart + TimePoint(Int64(sample.numberSamples()), this.pts.scale)
        if windowEnd > sampleStart && windowStart < sampleEnd {
            let readOffset = min(Int(max(windowStart.value - sampleStart.value, 0)), sample.sampleCount) * 4
            let writeOffset = min(Int(max(sampleStart.value - windowStart.value, 0)), Int(inNumberFrames)) * 4
            let writeCount = min(sample.sampleCount * 4 - readOffset, Int(inNumberFrames) * 4 - writeOffset)
            zip(buffers, sample.data()).forEach {
                guard let ptr = $0.0.mData else {
                    return
                }
                _ = $0.1.withUnsafeBytes {
                    guard let readPtr = $0.baseAddress else {
                        return
                    }
                    memcpy(ptr+writeOffset, readPtr+readOffset, writeCount)
                }
            }
        }
    }
    this.pts = windowEnd
    return noErr
}
#endif
