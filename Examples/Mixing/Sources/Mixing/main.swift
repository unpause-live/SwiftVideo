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

// This example is going to take advantage of the Composer class that will simplify positioning 
// audio and video samples in the mixers.  You can use the AudioMixer and VideoMixer directly if 
// you wish to manually set the transformation matrices and other properties of the samples.
// We will take a couple of file sources, compose them, and stream them out to an RTMP endpoint.

// This example requires GPU access.

import SwiftVideo
import Foundation
import NIO
import NIOExtras
import BrightFutures

let clock = WallClock()
let compute = try makeComputeContext(forType: .GPU)
let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
let fullyShutdownPromise: EventLoopPromise<Void> = group.next().makePromise()

let leftFile = "file:///Users/james/dev/test-data/movies/spring.mp4"
let rightFile = "file:///Users/james/dev/test-data/movies/bbc_audio_sync.mp4"
let rtmpDestination = "rtmp://localhost/app/playPath"

var rtmpPublisher: (Tx<AudioSample, [ResultEvent]>, Terminal<PictureSample>)?

// In order for the composer to bind elements to assets, it must be given access to a pool of samples that the
// elements can pull from and the result will be pushed to. This means that the sources you wish to use must feed 
// into these buses. This is not a requirement of the underlying mixers or animators, it is a requirement of this 
// particular implementation of a holistic composer that handles binding and rebinding assets to animators to mixers.
let pictureBus = Bus<PictureSample>(clock)
let audioBus = Bus<AudioSample>(clock)

let width = 1280
let height = 720

// The SwiftVideo composer as implemented requires a composition manifest to define its initial behavior.
// We will start with a simple composition that takes two inputs and stitches them together side-by-side.
let manifest = RpcMakeComposition.with { config in
    config.audio = RpcMixerAudioConfig.with {
        $0.channels = 2
        $0.sampleRate = 48000
    }
    config.video = RpcMixerVideoConfig.with {
        $0.frameDuration = TimePoint(1000, 30000)
        $0.width = Int32(width)
        $0.height = Int32(height)
    }
    config.composition = Composition.with {
        $0.initialScene = "scene1"
        $0.scenes = ["scene1": Scene.with {
            $0.elements = [
                "element1": Element.with {
                    $0.initialState = "state1"
                    $0.states = ["state1": ElementState.with {
                        $0.picAspect = .aspectFill
                        $0.audioGain = 1.0
                        $0.picOrigin = .originTopLeft
                        $0.picPos = Vec3.with { $0.x = 0; $0.y = 0; $0.z = 0 }
                        $0.transparency = 0.0
                        $0.size = Vec2.with { $0.x = Float(config.video.width/2); $0.y = Float(config.video.height) }
                        }]
                },
                "element2": Element.with {
                    $0.initialState = "state1"
                    $0.states = ["state1": ElementState.with {
                        $0.picAspect = .aspectFill
                        $0.audioGain = 1.0
                        $0.picOrigin = .originTopLeft
                        $0.picPos = Vec3.with { $0.x = Float(config.video.width/2); $0.y = 0; $0.z = 0 }
                        $0.transparency = 0.0
                        $0.size = Vec2.with { $0.x = Float(config.video.width/2); $0.y = Float(config.video.height) }
                        }]
                }]
        }]
    }
}

// Finally we create the composer.
let composer = Composer(clock,
    assetId: "composer",
    workspaceId: "sandbox",
    compute: compute,
    composition: manifest,
    audioBus: audioBus,
    pictureBus: pictureBus)

func makeFileSource(_ url: String, _ ident: String) throws -> (Terminal<CodedMediaSample>, Terminal<CodedMediaSample>) {
    let src = try FileSource(clock, url: url, assetId: ident, workspaceId: "sandbox")
    // Here we are composing transformations: taking the encoded media from the file source, decoding it, and 
    // preparing the samples in a useful format for the mixers.  In the case of audio samples, we are doing a sample
    // rate conversion to the format we specify in the manifest.  In the case of video samples, we are introducing
    // a GPU barrier to copy the texture onto the GPU.
    //
    // Note that the Composer class actually adds a GPU barrier on the upload side anyway, so it is not mandatory
    // to add an upload barrier when using it, but the upload barrier is idempotent so you won't upload the texture
    // twice if there are two used on the same sample.
    //
    // The result of one of the compositions below is a Tx<CodedMediaSample, ResultEvent> which contains all of the
    // transformation functions specified. Tx<CodedMediaSample, ResultEvent> is equivalent to Terminal<CodedMediaSample>
    return (src >>> mediaTypeFilter(.video) >>> FFmpegVideoDecoder() >>> GPUBarrierUpload(compute) >>> pictureBus,
            src >>> mediaTypeFilter(.audio) >>> FFmpegAudioDecoder() >>>
                    AudioSampleRateConversion(48000, 2, .s16i) >>> audioBus)
}

let onEnded: LiveOnEnded = { print("\($0) ended") ; rtmpPublisher = nil }

// RTMP connection established, here we create the encoders and compose the outputs.
let onConnection: LiveOnConnection = { pub, sub in
    if let pub = pub, let txn = pub as? Terminal<CodedMediaSample> {
        // Here we are pulling samples off of our audio and video buses that have been generated by the composer
        // There is a GPU barrier to download the textuure from the GPU introduced here.  This must be used
        // even if using the Composer class because the composer makes no assumptions about where you want 
        // the texture to live after it's finished with it.
        //
        // We must also filter the assets coming from the bus so that we only get the samples we want rather than
        // all of them.
        rtmpPublisher = (audioBus <<| assetFilter("composer") >>> FFmpegAudioEncoder(.aac, bitrate: 96000) |>> txn,
            pictureBus <<| assetFilter("composer") >>> GPUBarrierDownload(compute) >>> FFmpegVideoEncoder(.avc,
                bitrate: 3_000_000, frameDuration: manifest.video.frameDuration) >>> txn)
    }
    return Future { $0(.success(true)) }
}

let leftFs = try makeFileSource(leftFile, "left")
let rightFs = try makeFileSource(rightFile, "right")

// We need to bind the file assets to the on-screen elements
composer.bind("left", elementId: "element1")
composer.bind("right", elementId: "element2")

// Create an RTMP output
let rtmp = Rtmp(clock, onEnded: onEnded, onConnection: onConnection)

if let url = URL(string: rtmpDestination) {
    _ = rtmp.connect(url: url, publishToPeer: true, group: group, workspaceId: "sandbox")
}

try fullyShutdownPromise.futureResult.wait()
