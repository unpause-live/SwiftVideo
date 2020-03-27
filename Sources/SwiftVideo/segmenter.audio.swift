import Foundation

public class AudioPacketSegmenter: Tx<AudioSample, [AudioSample]> {

    public init(_ duration: TimePoint) {
        self.incoming = []
        self.pts = nil
        self.duration = duration
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            strongSelf.incoming.append(sample)
            let pts = strongSelf.pts ?? sample.pts()
            let result = audioSampleSplit(strongSelf.duration, pts: pts, inSamples: strongSelf.incoming)
            strongSelf.pts = result.0
            strongSelf.incoming = result.1
            //print("result=\(result.2)")
            return .just(result.2)
        }
    }

    var pts: TimePoint?
    var incoming: [AudioSample]
    let duration: TimePoint
}
private typealias SplitResult = (TimePoint, [AudioSample], [AudioSample]) // final pts, remaining samples, new samples
private func audioSampleSplit(_ duration: TimePoint,
                              pts: TimePoint,
                              inSamples: [AudioSample],
                              outSamples: [AudioSample] = []) -> SplitResult {
        guard inSamples.count > 0 else {
            return (pts, [], outSamples)
        }

        // we are going to try to extract a single segment from the buffer we have built up.
        let totalDuration = inSamples.reduce(TimePoint(0)) { $0 + $1.duration() } - (pts - inSamples[0].pts())
        //print("inSamples=\(inSamples) totalDuration=\(totalDuration.toString()) duration=\(duration.toString())")
        guard totalDuration >= duration else {
            return (pts, inSamples, outSamples)
        }
        let sampleCount = rescale(duration, Int64(inSamples[0].sampleRate())).value
        let sampleBytes = bytesPerSample(inSamples[0].format(), inSamples[0].numberChannels())
        let bufferLength = Int(sampleCount) * sampleBytes
        var buffers = (0..<numberOfBuffers(inSamples[0].format(), inSamples[0].numberChannels())).map { _ in
            Data(count: bufferLength)
        }
        //print("made buffers of length=\(bufferLength) \(buffers)")
        let sample = AudioSample(inSamples[0],
                                 buffers: buffers,
                                 sampleCount: Int(sampleCount),
                                 pts: pts)
        let nextPts = pts + duration
        let remaining = inSamples.filter { ($0.pts() + $0.duration()) > nextPts }
        let toCopy = inSamples.filter { $0.pts() <= nextPts }

        toCopy.forEach {
            let inOffset = sample.pts() - $0.pts()
            let inStartBytes = max(Int(rescale(inOffset, Int64($0.sampleRate())).value) * sampleBytes, 0)
            let outOffset = $0.pts() - sample.pts()
            let outStartBytes = max(Int(rescale(outOffset, Int64($0.sampleRate())).value) * sampleBytes, 0)
            let bytesToCopy = min(bufferLength - outStartBytes, $0.data()[0].count - inStartBytes)
            let outEndBytes = outStartBytes + bytesToCopy
            let inEndBytes = inStartBytes + bytesToCopy
            print("bufferLength = \(bufferLength) data.count = \($0.data()[0].count)")
            print("bytesToCopy = \(bytesToCopy)")
            print("inOffset=\(inOffset.toString()) outOffset=\(outOffset.toString())")
            print("outStartBytes=\(outStartBytes) inStartBytes=\(inStartBytes)")
            print("inPts=\($0.pts().toString())")
            if bytesToCopy > 0 {
                $0.data().enumerated().forEach {
                    let idx = $0.offset
                    var inBuf = $0.element
                    inBuf.withUnsafeMutableBytes { src in
                        guard let src = src.baseAddress else { return }
                        buffers[idx].withUnsafeMutableBytes { dst in
                            guard let dst = dst.baseAddress else { return }
                            memcpy(dst+outStartBytes, src+inStartBytes, bytesToCopy)
                        }
                    }
                }
            }
        }
        return audioSampleSplit(duration, pts: pts + duration, inSamples: remaining, outSamples: outSamples + [sample])
    }
