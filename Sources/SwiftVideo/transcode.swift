/*
   SwiftVideo, Copyright 2019 Unpause SAS

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

#if !EXCLUDE_FFMPEG // Requires ffmpeg for now

// swiftlint:disable force_cast

public protocol Renameable: Event {
    static func make(_ other: Renameable,
                     assetId: String,
                     constituents: [MediaConstituent],
                     eventInfo: EventInfo?) -> Renameable
    func pts() -> TimePoint
    func dts() -> TimePoint
    func constituents() -> [MediaConstituent]?
}

private class AssetRenamer<T>: Tx<T, T> where T: Renameable {
    public init(_ assetId: String) {
        self.statsReport = nil
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            if strongSelf.statsReport == nil {
                strongSelf.statsReport = (sample.info() <??> {
                    StatsReport(assetId: assetId, other: $0) } <|> StatsReport(assetId: assetId))
            }
            return .just(T.make(sample,
                                assetId: assetId,
                                constituents: [MediaConstituent.with { $0.idAsset = sample.assetId()
                                    $0.pts = sample.pts()
                                    $0.dts = sample.dts()
                                    $0.constituents = sample.constituents() ?? [MediaConstituent]() }],
                                eventInfo: strongSelf.statsReport) as! T)
        }
    }

    private var statsReport: StatsReport?
}

extension CodedMediaSample: Renameable {
    public static func make(_ other: Renameable,
                            assetId: String,
                            constituents: [MediaConstituent],
                            eventInfo: EventInfo?) -> Renameable {
        return CodedMediaSample(other as! CodedMediaSample,
            assetId: assetId, constituents: constituents, eventInfo: eventInfo)
    }
}

extension AudioSample: Renameable {
    public static func make(_ other: Renameable,
                            assetId: String,
                            constituents: [MediaConstituent],
                            eventInfo: EventInfo?) -> Renameable {
        return AudioSample(other as! AudioSample, assetId: assetId, constituents: constituents, eventInfo: eventInfo)
    }
    public func dts() -> TimePoint {
        return pts()
    }
}

extension PictureSample: Renameable {
    public static func make(_ other: Renameable,
                            assetId: String,
                            constituents: [MediaConstituent],
                            eventInfo: EventInfo?) -> Renameable {
        return PictureSample(other as! PictureSample,
            assetId: assetId, constituents: constituents, eventInfo: eventInfo)
    }
    public func dts() -> TimePoint {
        return pts()
    }
}

public func assetRename<T>(_ assetId: String) -> Tx<T, T> where T: Renameable {
    return AssetRenamer(assetId)
}

public func makeVideoTranscoder(_ fmt: MediaFormat,
                                bitrate: Int,
                                keyframeInterval: TimePoint,
                                newAssetId: String,
                                settings: EncoderSpecificSettings? = nil) throws
        -> Tx<CodedMediaSample, CodedMediaSample> {
    guard [.avc, .hevc, .vp8, .vp9, .av1].contains(where: { $0 == fmt }) else {
        throw EncodeError.invalidMediaFormat
    }

    if bitrate > 0 {
        return assetRename(newAssetId) >>> FFmpegVideoDecoder() >>> FFmpegVideoEncoder(fmt,
            bitrate: bitrate,
            keyframeInterval: keyframeInterval,
            settings: settings)
    } else {
        return assetRename(newAssetId)
    }
}

public func makeAudioTranscoder(_ fmt: MediaFormat,
                                bitrate: Int,
                                sampleRate: Int,
                                newAssetId: String) throws -> Tx<CodedMediaSample, [CodedMediaSample]> {
    guard [.aac, .opus].contains(where: { $0 == fmt }) else {
        throw EncodeError.invalidMediaFormat
    }
    if bitrate > 0 {
        return assetRename(newAssetId) >>> FFmpegAudioDecoder() >>>
            AudioSampleRateConversion(sampleRate, 2, .s16i) >>> FFmpegAudioEncoder(fmt, bitrate: bitrate)
    } else {
        return Tx { .just([$0]) } |>> assetRename(newAssetId)
    }
}

public class TranscodeContainer: AsyncTx<CodedMediaSample, CodedMediaSample> {
    public init(_ videoTranscodes: [Tx<CodedMediaSample, CodedMediaSample>],
                _ audioTranscodes: [Tx<CodedMediaSample, [CodedMediaSample]>], _ bus: Bus<CodedMediaSample>) {
        self.videoTranscoders = [Tx<CodedMediaSample, CodedMediaSample>]()
        self.audioTranscoders = [Tx<CodedMediaSample, [CodedMediaSample]>]()
        super.init()
        self.videoTranscoders = videoTranscodes.map {
            return bus <<| ($0 >>> Tx { [weak self] in
                guard let strongSelf = self else {
                    return .gone
                }
                return (strongSelf.emit($0).value() as? CodedMediaSample) <??> { .just($0) } <|> .nothing($0.info())
            })
        }
        self.audioTranscoders = audioTranscodes.map {
            return bus <<| ($0 >>> Tx { [weak self] samples in
                guard let strongSelf = self else {
                    return .gone
                }
                let results = samples.map {
                    strongSelf.emit($0)
                }
                return .just(results.compactMap { $0.value() as? CodedMediaSample })
            })
        }
    }
    var videoTranscoders: [Tx<CodedMediaSample, CodedMediaSample>]
    var audioTranscoders: [Tx<CodedMediaSample, [CodedMediaSample]>]
}

#endif // !EXCLUDE_FFMPEG