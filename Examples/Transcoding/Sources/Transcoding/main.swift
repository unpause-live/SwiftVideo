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

// This example is going to use the Transcode class to transcode a file and output it to an RTMP endpoint.

import SwiftVideo
import Foundation
import NIO
import NIOExtras
import BrightFutures

let clock = WallClock()
let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
let fullyShutdownPromise: EventLoopPromise<Void> = group.next().makePromise()
let codedBus = Bus<CodedMediaSample>(clock)

let inputFile = "file:///Users/james/dev/test-data/movies/spring.mp4"
let rtmpDestination = "rtmp://localhost/app/playPath"

var fileSource: Terminal<CodedMediaSample>?
var videoTranscoder: Terminal<CodedMediaSample>?
var audioTranscoder: Tx<CodedMediaSample, [ResultEvent]>?

let onEnded: LiveOnEnded = {
    print("\($0) ended")
    fileSource = nil
    videoTranscoder = nil
    audioTranscoder = nil
}

// RTMP connection established, here we create the encoders and compose the outputs.
let onConnection: LiveOnConnection = { pub, sub in
    if let pub = pub,
       let txn = pub as? Terminal<CodedMediaSample> {
        do {
            let src = try FileSource(clock, url: inputFile, assetId: "file", workspaceId: "sandbox")
            videoTranscoder = try codedBus <<| mediaTypeFilter(.video) >>> makeVideoTranscoder(.avc,
                bitrate: 3_000_000, keyframeInterval: TimePoint(2000, 1000), newAssetId: "new") >>> txn
            audioTranscoder = try codedBus <<| mediaTypeFilter(.audio) >>>
                    makeAudioTranscoder(.aac, bitrate: 96_000, sampleRate: 48000, newAssetId: "new") |>> txn
            fileSource = src >>> codedBus
        } catch {
            print("Exception loading file \(error)")
        }
    }
    return Future { $0(.success(true)) }
}

// Create an RTMP output
let rtmp = Rtmp(clock, onEnded: onEnded, onConnection: onConnection)

if let url = URL(string: rtmpDestination) {
    _ = rtmp.connect(url: url, publishToPeer: true, group: group, workspaceId: "sandbox")
}

try fullyShutdownPromise.futureResult.wait()
