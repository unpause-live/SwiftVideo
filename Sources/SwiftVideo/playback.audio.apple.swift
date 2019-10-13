#if os(macOS) || os(iOS) || os(tvOS)
import Foundation
import AudioToolbox

class AppleAudioPlayback : Terminal<AudioSample> {
    public override init() {
        self.component = nil
        self.unit = nil
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            if strongSelf.unit == nil {
                let asbd = AudioStreamBasicDescription(mSampleRate: Float64(sample.sampleRate()),
                                                       mFormatID: kAudioFormatLinearPCM,
                                                       mFormatFlags: 12,
                                                       mBytesPerPacket: 4,
                                                       mFramesPerPacket: 1,
                                                       mBytesPerFrame: 2,
                                                       mChannelsPerFrame: UInt32(sample.numberChannels()),
                                                       mBitsPerChannel: 16,
                                                       mReserved: 0)
            }
            return .nothing(sample.info())
        }
    }
    
    private var unit: AudioUnit?
    private var component: AudioComponent?
}
#endif
