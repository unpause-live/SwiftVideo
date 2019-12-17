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

import VectorMath
import Foundation

// swiftlint:disable identifier_name

enum ComputeError: Error {
    case invalidPlatform
    case invalidDevice
    case invalidOperation
    case invalidValue
    case invalidProgram
    case invalidContext
    case deviceNotAvailable
    case outOfMemory
    case compilerNotAvailable
    case computeKernelNotFound(ComputeKernel)
    case badTarget
    case badInputData(description: String)
    case badContextState(description: String)
    case compilerError(description: String)
    case unknownError
    case notImplemented
}

public enum ComputeDeviceType {
    case GPU
    case CPU
    case Accelerator
    case Default
}

// operation_infmt_outfmt
enum ComputeKernel {
    // basic compositing and format conversion
    case img_nv12_nv12
    case img_bgra_nv12
    case img_rgba_nv12
    case img_bgra_bgra
    case img_y420p_y420p
    case img_y420p_nv12
    case img_clear_nv12 // clear the texture provided as target
    case img_clear_yuvs
    case img_clear_bgra
    case img_clear_y420p
    case img_clear_rgba
    case img_rgba_y420p
    case img_bgra_y420p

    // audio 

    case snd_s16i_s16i

    // motion estimation
    case me_fullsearch

    // user-defined
    case custom(name: String)
}

struct ImageUniforms {
    let transform: Matrix4
    let textureTransform: Matrix4
    let borderMatrix: Matrix4
    let fillColor: Vector4
    let inputSize: Vector2
    let outputSize: Vector2
    let opacity: Float
    let imageTime: Float
    let targetTime: Float
}

// Find a default compute kernel
// Throws ComputeError.invalidValue if not found
func defaultComputeKernelFromString(_ str: String) throws -> ComputeKernel {
    let kernelMap: [String: ComputeKernel] = [
        "img_nv12_nv12": .img_nv12_nv12,
        "img_bgra_nv12": .img_bgra_nv12,
        "img_rgba_nv12": .img_rgba_nv12,
        "img_bgra_bgra": .img_bgra_bgra,
        "img_y420p_y420p": .img_y420p_y420p,
        "img_y420p_nv12": .img_y420p_nv12,
        "img_clear_nv12": .img_clear_nv12,
        "img_clear_yuvs": .img_clear_yuvs,
        "img_clear_bgra": .img_clear_bgra,
        "img_clear_rgba": .img_clear_bgra,
        "img_rgba_y420p": .img_rgba_y420p,
        "img_bgra_y420p": .img_bgra_y420p,
        "img_clear_y420p": .img_clear_y420p
    ]
    guard let kernel = kernelMap[str] else {
        throw ComputeError.invalidValue
    }
    return kernel
}

public func hasAvailableComputeDevices(forType search: ComputeDeviceType) -> Bool {
    let allDevices = availableComputeDevices()
    dump(allDevices)
    let devices = allDevices.filter {
        guard let type = $0.deviceType, type == search && $0.available else {
            return false
        }
        return true
    }
    return devices.count > 0
}

public func makeComputeContext(forType search: ComputeDeviceType) throws -> ComputeContext {
    let devices = availableComputeDevices().filter { ($0.deviceType <??> { $0 == search } <|> false) && $0.available }
    if let device = devices.first,
       let context = try createComputeContext(device) {
        return context
    } else {
        throw ComputeError.deviceNotAvailable
    }
}

// applyComputeImage is a convenience function used for typical image compositing operations and
// format conversion.  This has a standard set of useful uniforms for those
// operations.  If you want to do something more custom, use runComputeKernel instead.
// Throws ComputeError:
//  - badContextState
//  - computeKernelNotFound
//  - badInputData
//  - badTarget
// Can throw additional errors from MTLDevice.makeComputePipelineState
func applyComputeImage(_ context: ComputeContext,
                       image: PictureSample,
                       target: PictureSample,
                       kernel: ComputeKernel) throws -> ComputeContext {
    let inputSize = Vector2([image.size().x, image.size().y])
    let outputSize = Vector2([target.size().x, target.size().y])
    let matrix = image.matrix().inverse.transpose
    let textureMatrix = image.textureMatrix().inverse.transpose
    let uniforms = ImageUniforms(transform: matrix,
                                 textureTransform: textureMatrix,
                                 borderMatrix: image.borderMatrix().inverse.transpose,
                                 fillColor: image.fillColor(),
                                 inputSize: inputSize,
                                 outputSize: outputSize,
                                 opacity: image.opacity(),
                                 imageTime: seconds(image.time()),
                                 targetTime: seconds(target.time()))

    return try runComputeKernel(context,
                                images: [image],
                                target: target,
                                kernel: kernel,
                                maxPlanes: 3,
                                uniforms: uniforms,
                                blends: true)
}

//
//  Place in a pipeline to upload textures to the GPU
//
public class GPUBarrierUpload: Tx<PictureSample, PictureSample> {
    public init(_ context: ComputeContext) {
        self.context = createComputeContext(sharing: context)
        super.init()
        super.set { [weak self] in
            guard let strongSelf = self, let context = strongSelf.context else {
                return .gone
            }
            if $0.bufferType() == .cpu {
                do {
                    $0.info()?.startTimer("gpu.upload")
                    let sample = try uploadComputePicture(context, pict: $0)
                    $0.info()?.endTimer("gpu.upload")
                    return .just(sample)
                } catch let error {
                    return .error(EventError("barrier.upload", -1, "\(error)", assetId: $0.assetId()))
                }
            } else {
                return .just($0)
            }
        }
    }
    let context: ComputeContext?
}

/*
public class GPUBarrierAudioUpload: Tx<AudioSample, AudioSample> {
    public init(_ context: ComputeContext) {
        self.context = createComputeContext(sharing: context)
        self.peak = 0
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self,
                  let context = strongSelf.context else {
                return .gone
            }
            if sample.bufferType() == .cpu {
                do {
                    let buffers = try sample.data().enumerated().map { (idx, element) in
                        return try uploadComputeBuffer(context, src: element, dst: sample.computeData()[safe: idx])
                    }
                    return .just(AudioSample(sample, bufferType: .gpu, computeBuffers: buffers))
                } catch (let error) {
                    print("caught download error \(error)")
                    return .error(EventError("barrier.upload", -1, "\(error)"))
                }
            }
            return .just(sample)
        }
    }
    let context: ComputeContext?
    var peak: Double
}*/

//
//  Place in a pipeline to download textures from the GPU
//
public class GPUBarrierDownload: Tx<PictureSample, PictureSample> {
    public init(_ context: ComputeContext) {
        self.context = createComputeContext(sharing: context)
        super.init()
        super.set { [weak self] in
            guard let strongSelf = self, let context = strongSelf.context else {
                return .gone
            }
            if $0.bufferType() == .gpu {
                do {
                    $0.info()?.startTimer("gpu.download")
                    let sample = try downloadComputePicture(context, pict: $0)
                    $0.info()?.endTimer("gpu.download")
                    return .just(sample)
                } catch let error {
                    return .error(EventError("barrier.download", -1, "\(error)", assetId: $0.assetId()))
                }
            } else {
                return .just($0)
            }
        }
    }
    let context: ComputeContext?
}
/*
public class GPUBarrierAudioDownload: Tx<AudioSample, AudioSample> {
    public init(_ context: ComputeContext) {
        self.context = createComputeContext(sharing: context)
        self.peak = 0
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self,
                  let context = strongSelf.context else {
                return .gone
            }
            if sample.bufferType() == .cpu {
                do {
                    let buffers = try sample.computeData().enumerated().map { (idx, element) in
                        return try downloadComputeBuffer(context, src: element, dst: sample.data()[safe: idx])
                    }
                    return .just(AudioSample(sample, bufferType: .cpu, buffers: buffers))
                } catch (let error) {
                    return .error(EventError("barrier.download", -1, "\(error)"))
                }
            }
            return .just(sample)
        }
    }
    let context: ComputeContext?
    var peak: Double
}*/
