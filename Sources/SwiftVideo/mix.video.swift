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

import Dispatch
import Foundation
import VectorMath

public class VideoMixer: Source<PictureSample> {
    public init(_ clock: Clock,
                workspaceId: String,
                frameDuration: TimePoint,
                outputSize: Vector2,
                outputFormat: PixelFormat = .nv12,
                computeContext: ComputeContext? = nil,
                assetId: String? = nil,
                statsReport: StatsReport? = nil,
                epoch: Int64? = nil) {

        if let computeContext = computeContext {
            self.clContext = createComputeContext(sharing: computeContext)
        } else {
            do {
                self.clContext = try makeComputeContext(forType: .GPU)
            } catch {
                print("Error making compute context!")
            }
        }

        self.clock = clock
        self.result = .nothing(nil)
        self.samples = Array(repeating: [String: PictureSample](), count: 2)
        self.frameDuration = frameDuration
        let now = clock.current()
        self.epoch = rescale(epoch.map { clock.fromUnixTime($0) } ?? now, frameDuration.scale)
        self.backing = [PictureSample]()
        self.backingSize = outputSize
        self.backingFormat = outputFormat
        self.idWorkspace = workspaceId
        let idAsset = assetId ?? UUID().uuidString
        self.idAsset = idAsset
        self.statsReport = statsReport ?? StatsReport(assetId: idAsset, clock: clock)
        self.queue = DispatchQueue(label: "mix.video.\(idAsset)")
        super.init()
        super.set { [weak self] pic -> EventBox<PictureSample> in
            guard let strongSelf = self else {
                return .gone
            }
            guard strongSelf.clContext != nil else {
                return .error(EventError("mix.video", -1, "No Compute Context",
                                         pic.time(),
                                         assetId: strongSelf.idAsset))
            }
            if pic.assetId() != strongSelf.assetId() {
                strongSelf.queue.async { [weak self] in
                    self?.samples[0][pic.revision()] = pic
                }
                return .nothing(pic.info())
            } else {
                return .just(pic)
            }

        }
        clock.schedule(now + frameDuration) { [weak self] in self?.mix(at: $0) }
    }

    public func assetId() -> String {
        return idAsset
    }

    public func workspaceId() -> String {
        return idWorkspace
    }

    public func computeContext() -> ComputeContext? {
        return self.clContext
    }

    deinit {
        if let context = self.clContext {
            do {
                try destroyComputeContext(context)
            } catch {}
            self.clContext = nil
        }
    }

    func mix(at: ClockTickEvent) {
        let next = at.time() + frameDuration
        let pts = at.time() - epoch
        clock.schedule(next) { [weak self] in self?.mix(at: $0) }
        queue.async { [weak self] in
            guard let strongSelf = self else {
                return
            }
            guard var ctx = strongSelf.clContext else {
                return
            }
            var result: EventBox<PictureSample> = .nothing(nil)
            do {
                strongSelf.statsReport.endTimer("mix.video.delta")
                strongSelf.statsReport.startTimer("mix.video.delta")
                strongSelf.statsReport.startTimer("mix.video.compose")
                let backing = try strongSelf.getBacking()
                ctx = beginComputePass(ctx)
                let clearKernel = try strongSelf.findKernel(nil, backing)
                // clear the target image
                ctx = try runComputeKernel(ctx, images: [PictureSample](), target: backing, kernel: clearKernel)
                // sort images by z-index so lowest is drawn first
                let images = strongSelf.samples.reduce([String: PictureSample]()) { acc, next in
                        acc.merging(next) { lhs, _ in lhs }
                    }.values.sorted { $0.zIndex() < $1.zIndex() }
                strongSelf.samples[1] = strongSelf.samples[0]
                strongSelf.samples[0].removeAll(keepingCapacity: true)
                // draw images
                try images.forEach {
                    ctx = try applyComputeImage(ctx,
                                                image: $0,
                                                target: backing,
                                                kernel: strongSelf.findKernel($0, backing))
                }
                // end compositing and wait for kernels to complete running
                ctx = endComputePass(ctx, true)

                strongSelf.clContext = ctx
                strongSelf.statsReport.endTimer("mix.video.compose")
                let sample = PictureSample(backing,
                                           pts: pts,
                                           time: at.time(),
                                           eventInfo: strongSelf.statsReport)
                _ = strongSelf.emit(sample)
                result = .nothing(strongSelf.statsReport)
            } catch let error {
                print("[mix] caught error \(String(describing: error))")
                result = .error(EventError("mix.video", -2, "Compute error \(error)",
                                           at.time(),
                                           assetId: strongSelf.idAsset))
            }
            strongSelf.result = result

        }
    }

    private func findKernel(_ image: PictureSample?, _ target: PictureSample) throws -> ComputeKernel {
        let inp = image <??> { String(describing: $0.pixelFormat()).lowercased() } <|> "clear"
        let outp = String(describing: target.pixelFormat()).lowercased()
        return try defaultComputeKernelFromString("img_\(inp)_\(outp)")
    }

    private func getBacking() throws -> PictureSample {
        guard let ctx = clContext else {
            throw ComputeError.badContextState(description: "No context")
        }
        if backing.count < numberBackingImages {
            let image = try createPictureSample(self.backingSize,
                                                backingFormat,
                                                assetId: self.assetId(),
                                                workspaceId: self.workspaceId())
            let gpuImage = try uploadComputePicture(ctx, pict: image)
            backing.append(gpuImage)
            return gpuImage
        } else {
            let image = backing[currentBacking]
            currentBacking = (currentBacking + 1) % backing.count
            return image
        }
    }
    private let numberBackingImages = 10
    private let statsReport: StatsReport

    private var backing: [PictureSample]
    private var currentBacking = 0
    private let backingFormat: PixelFormat
    private let backingSize: Vector2

    public let frameDuration: TimePoint
    private let clock: Clock
    private let epoch: TimePoint
    internal let queue: DispatchQueue
    private var clContext: ComputeContext?
    private var result: EventBox<PictureSample>
    private var samples: [[String: PictureSample]]
   // private var pts : TimePoint
    private let idAsset: String
    private let idWorkspace: String
}
