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

import SwiftFFmpeg
import Foundation

enum FileError: Error {
    case unsupported
}

private struct StreamInfo {
    let format: MediaFormat
    let type: MediaType
    let timebase: TimePoint
    let startTime: TimePoint
    let extradata: Data?
}
public class FileSource: Source<CodedMediaSample> {
    public init(_ clock: Clock, url: String, assetId: String, workspaceId: String, workspaceToken: String? = nil, repeats: Bool = false) throws {
        let fmtCtx = try AVFormatContext(url: url)
        try fmtCtx.findStreamInfo()
        let streams: [Int: StreamInfo] = Dictionary(uniqueKeysWithValues: fmtCtx.streams.enumerated().compactMap { (idx, val) in
            let codecParams = val.codecParameters
            let timebase = TimePoint(Int64(val.timebase.num), Int64(val.timebase.den))
            let codecMap: [AVCodecID: MediaFormat] = [.H264: .avc, .HEVC: .hevc, .VP8: .vp8, .VP9: .vp9, .AAC: .aac, .OPUS: .opus, .PNG: .png]
            let typeMap: [AVMediaType: MediaType] = [.audio: .audio, .video: .video, .data: .data, .subtitle: .subtitle]
            let extradata: Data? = {
                guard let ptr = codecParams.extradata, codecParams.extradataSize > 0 else {
                    return nil
                }
                return Data(bytes: ptr, count: codecParams.extradataSize)
            }()
            guard let codec = codecMap[codecParams.codecId], let type = typeMap[val.mediaType] else {
                return nil
            }
            // to  be used with hls/dash sources
            //val.discard = .all
            let startTime = (val.startTime != AVTimestamp.noPTS) ? TimePoint(Int64(val.startTime), timebase.scale) : timebase
            return (idx, StreamInfo(format: codec, type: type, timebase: timebase, startTime: startTime, extradata: extradata))
            })
        if streams.count == 0 {
            throw FileError.unsupported
        }
        self.ctx = fmtCtx
        self.clock = clock
        self.epoch = clock.current()
        self.assetId = assetId
        self.workspaceId = workspaceId
        self.workspaceToken = workspaceToken
        self.streams = streams
        self.repeats = repeats
        super.init()
    }

    public func formats() -> [MediaFormat] {
        return streams.map {
            $0.1.format
        }
    }

    public func play() {
        self.parse()
    }

    private func parse() {
        let pkt = AVPacket()
        do {
            try ctx.readFrame(into: pkt)
            if let stream = streams[pkt.streamIndex] {
                let pts = (pkt.pts != AVTimestamp.noPTS) ? TimePoint(Int64(pkt.pts), stream.timebase.scale) : stream.timebase
                let dts = (pkt.dts != AVTimestamp.noPTS) ? TimePoint(Int64(pkt.dts), stream.timebase.scale) : pts
                let delta = dts - stream.startTime
                guard let data = pkt.data else {
                    throw AVError.tryAgain
                }
                let buffer = Data(bytes: data, count: pkt.size)
                let sideData: [String: Data]? = stream.extradata.map { return ["config": $0] }
                let outsample = CodedMediaSample(assetId,
                                          workspaceId,
                                          clock.current(),
                                          pts,
                                          dts,
                                          stream.type,
                                          stream.format,
                                          buffer,
                                          sideData,
                                          nil,
                                          workspaceToken: workspaceToken,
                                          eventInfo: nil)
                self.clock.schedule(epoch + delta) { [weak self] _ in
                    guard let strongSelf = self else {
                        return
                    }
                    let result = strongSelf.emit(outsample)
                    switch result {
                        case .nothing, .just, .error:
                            strongSelf.parse()
                        default: ()
                    }
                }
            }
        } catch let error as AVError where error == .eof {
            print("caught eof")
        } catch(let error) {
            print("caught error \(error)")
        }
    }
    fileprivate let streams: [Int: StreamInfo]
    let clock: Clock
    let epoch: TimePoint
    let ctx: AVFormatContext
    let assetId: String
    let workspaceId: String
    let workspaceToken: String?
    let repeats: Bool
}
