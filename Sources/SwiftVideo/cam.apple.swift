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

#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import CoreMedia
import AVFoundation

public class AppleCamera: Source<PictureSample> {
    private let session: AVCaptureSession
    private let frameDuration: TimePoint
    private let clock: Clock
    private let queue: DispatchQueue
    private var captureDevice: AVCaptureDevice?
    private var sampleBufferDel: SampleBufferDel?
    private let idAsset: String

    private class SampleBufferDel: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let callback: (CMSampleBuffer) -> Void
        init(callback: @escaping (CMSampleBuffer) -> Void) {
            self.callback = callback
        }
        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            self.callback(sampleBuffer)
        }
    }

    public init(pos: AVCaptureDevice.Position, clock: Clock = WallClock(), frameDuration: TimePoint) {
        self.session = AVCaptureSession()
        self.frameDuration = frameDuration
        self.clock = clock
        let assetId = UUID().uuidString
        self.queue = DispatchQueue.init(label: "cam.apple.\(assetId)")
        self.idAsset = assetId
        super.init()

        self.sampleBufferDel = SampleBufferDel { [weak self] in
            if let strongSelf = self {
                strongSelf.push($0)
            }
        }

        let permission: (Bool) -> Void = {
            [weak self] (granted) in

            guard let strongSelf = self else {
                return
            }

            if granted && strongSelf.setDevice(pos: pos) {
                let output = AVCaptureVideoDataOutput()
                strongSelf.session.beginConfiguration()
                output.alwaysDiscardsLateVideoFrames = true

                output.videoSettings =
                    [kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     kCVPixelBufferIOSurfacePropertiesKey as String:
                        [kCVPixelBufferMetalCompatibilityKey as String: true],
                     kCVPixelBufferOpenGLCompatibilityKey as String: true]

                output.setSampleBufferDelegate(strongSelf.sampleBufferDel, queue: strongSelf.queue)
                strongSelf.session.addOutput(output)
                strongSelf.session.commitConfiguration()
                strongSelf.session.startRunning()
            }
        }
        // swiftlint:disable deployment_target
        if #available(iOS 7.0, macOS 10.14, *) {
            let access = AVCaptureDevice.authorizationStatus(for: .video)

            if access == .authorized {
                permission(true)
            } else if access == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video, completionHandler: permission)
            }
        } else {
            permission(true)
        }
    }

    @discardableResult
    public func setDevice(pos: AVCaptureDevice.Position) -> Bool {
        if let device = { () -> AVCaptureDevice? in
            #if os(iOS)
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos)
            #else
            return AVCaptureDevice.default(for: .video)
            #endif
            }()  {
            self.session.beginConfiguration()
            self.captureDevice = device

            let currentInput = self.session.inputs.first

            if let cur = currentInput {
                self.session.removeInput(cur)
            }
            do {
                try device.lockForConfiguration()
                // find the closest frame duration to the requested duration
                let frameDuration = device.activeFormat.videoSupportedFrameRateRanges.reduce(CMTime.positiveInfinity) {
                    Float64(seconds(self.frameDuration)).distance(
                        to: CMTimeGetSeconds($1.maxFrameDuration)) < CMTimeGetSeconds($0) ? $1.maxFrameDuration : $0
                }

                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
                try self.session.addInput(AVCaptureDeviceInput(device: device))
            } catch {
                if let cur = currentInput {
                    self.session.addInput(cur)
                }
                return false
            }

            device.unlockForConfiguration()
            self.session.commitConfiguration()
            return true
        }
        return false
    }

    public func assetId() -> String {
        return idAsset
    }

    private func push(_ buf: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buf)
        let sample = PictureSample(buf,
                                   assetId: self.idAsset,
                                   workspaceId: "cam.apple",
                                   time: self.clock.current(),
                                   pts: TimePoint(pts.value, Int64(pts.timescale)))
        _ = self.emit(sample)
    }
}
#endif
