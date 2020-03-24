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

#if os(iOS) || os(tvOS) || (os(macOS) && !GPGPU_OCL)

import Metal
import CoreVideo
import MetalPerformanceShaders
import CoreMedia
import VectorMath

public typealias ComputeBuffer = MTLTexture
// TODO: Support more than just the default device
#warning("TODO: Support more than just default device")
struct ComputeDevice {
    let deviceType: ComputeDeviceType? = .GPU
    let vendorName: String? = "Apple"
    let deviceId: Int = 1
    let available = true
}

public struct ComputeContext {
    init(device: MTLDevice) {
        self.device = device
        self.defaultLibrary = device.makeDefaultLibrary()
        self.commandQueue = device.makeCommandQueue()
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        self.textureCache = textureCache
        self.commandBuffer = nil
        self.customLibrary = nil
    }
    init(other: ComputeContext,
         commandBuffer: MTLCommandBuffer?) {
        self.device = other.device
        self.defaultLibrary = other.defaultLibrary
        self.commandQueue = other.commandQueue
        self.textureCache = other.textureCache
        self.commandBuffer = commandBuffer
        self.customLibrary = other.customLibrary
    }
    init(other: ComputeContext,
         customLibrary: [String: MTLLibrary]?) {
        self.device = other.device
        self.defaultLibrary = other.defaultLibrary
        self.commandQueue = other.commandQueue
        self.textureCache = other.textureCache
        self.commandBuffer = other.commandBuffer
        self.customLibrary = customLibrary
    }
    let device: MTLDevice
    let defaultLibrary: MTLLibrary?
    let customLibrary: [String: MTLLibrary]?
    let textureCache: CVMetalTextureCache?
    let commandQueue: MTLCommandQueue?
    let commandBuffer: MTLCommandBuffer?
}

func availableComputeDevices() -> [ComputeDevice] {
    return [ComputeDevice()]
}

func createComputeContext(sharing ctx: ComputeContext) -> ComputeContext? {
    return ComputeContext(other: ctx, commandBuffer: nil)
}
// Create a Compute Context
// Throws ComputeError:
// - deviceNotAvailable if the provided device is unavailable to create a context on
//
func createComputeContext(_ device: ComputeDevice) throws -> ComputeContext? {
    guard let def = MTLCreateSystemDefaultDevice() else {
        throw ComputeError.deviceNotAvailable
    }
    return ComputeContext(device: def)
}

func destroyComputeContext( _ context: ComputeContext) throws {
    // no-op on Metal platforms
}
// Throws errors from MTLDevice.makeLibrary
func buildComputeKernel(_ context: ComputeContext, name: String, source: String) throws -> ComputeContext {
    let library = try context.device.makeLibrary(source: source, options: nil)
    return ComputeContext(other: context,
                          customLibrary: (context.customLibrary ??
                            [String: MTLLibrary]()).merging([name: library]) { _, val in val })
}

// Creates a command buffer to be used for the current compute pass.
func beginComputePass( _ context: ComputeContext ) -> ComputeContext {
    let commandBuffer = context.commandQueue?.makeCommandBuffer()
    return ComputeContext(other: context,
                          commandBuffer: commandBuffer)
}

// Used for multiple input images and an output target.
// Useful for compute kernels such as motion estimation that
// take multiple inputs to generate output data
//
// Uniforms are a standard Swift struct.

// Throws ComputeError:
//  - badContextState
//  - computeKernelNotFound
//  - badInputData
//  - badTarget
func runComputeKernel(_ context: ComputeContext,
                      images: [PictureSample],
                      target: PictureSample,
                      kernel: ComputeKernel,
                      maxPlanes: Int = 3,
                      requiredMemory: Int? = nil) throws -> ComputeContext {
    return try runComputeKernel(context,
                                images: images,
                                target: target,
                                kernel: kernel,
                                maxPlanes: maxPlanes,
                                uniforms: Void?.none)
}

func runComputeKernel<T>(_ context: ComputeContext,
                         images: [PictureSample],
                         target: PictureSample,
                         kernel: ComputeKernel,
                         maxPlanes: Int = 3,
                         requiredMemory: Int? = nil,
                         uniforms: T? = nil,
                         blends: Bool = false) throws -> ComputeContext {
    let kernelFunction = try getComputeKernel(context, kernel)
    let inputs = try images.reduce([MTLTexture?]()) {
        guard let image = $1.imageBuffer() else {
            throw ComputeError.badInputData(description: "Bad input image")
        }
        let result = try $0 + createTexture(context, image, maxPlanes)
        return result
    }
    guard let outputImage = target.imageBuffer() else {
        throw ComputeError.badTarget
    }
    let outputs = try createTexture(context, outputImage)
    if outputs.count == 0 {
        throw ComputeError.badTarget
    }
    let pipelineState = try context.device.makeComputePipelineState(function: kernelFunction)
    guard let commandEncoder = context.commandBuffer?.makeComputeCommandEncoder() else {
        throw ComputeError.badContextState(description: "Unable to create Metal command encoder")
    }
    let (threadCount, threadgroupSize) = makeThreadgroup(pipelineState, MTLSize(width: Int(target.size().x),
                                                                                height: Int(target.size().y),
                                                                                depth: 1),
                                                         requiredStaticMemory: requiredMemory)
    setUniforms(context, commandEncoder, uniforms, 0)
    commandEncoder.setComputePipelineState(pipelineState)
    commandEncoder.setTextures(outputs, range: 0..<outputs.count)
    commandEncoder.setTextures(inputs, range: outputs.count..<outputs.count+inputs.count)
    commandEncoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadgroupSize)
    commandEncoder.endEncoding()
    return context
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
/*func applyComputeImage(_ context: ComputeContext,
                       image: PictureSample,
                       target: PictureSample,
                       kernel: ComputeKernel) throws -> ComputeContext {

    let inputSize = Vector2([image.size().x, image.size().y])
    let outputSize = Vector2([target.size().x, target.size().y])

    // since our coordinates are operating on the output rather than the input
    // as we normally would with vertex and fragment shaders we need to
    // invert the matrix.
    let uniforms = ImageUniforms(transform: image.matrix().inverse.transpose,
                                 textureTransform: image.textureMatrix().inverse.transpose,
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
                                uniforms: uniforms)
}*/

// Completes the pass and waits for synchronization.
// Destroys the command buffer previously created.
func endComputePass( _ context: ComputeContext, _ waitForCompletion: Bool ) -> ComputeContext {
    context.commandBuffer?.commit()
    if waitForCompletion {
        context.commandBuffer?.waitUntilCompleted()
    }
    if let textureCache = context.textureCache {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
    return ComputeContext(other: context,
                          commandBuffer: nil)
}

func uploadComputeBuffer(_ ctx: ComputeContext, src: Data, dst: ComputeBuffer?) throws -> ComputeBuffer {

    /*let buffer = try dst ?? createBuffer(ctx, src.count)

    guard buffer.size >= src.count else {
        throw ComputeError.badInputData(description: "Compute buffer needs to be >= to data.count")
    }
    var src = src
    let count = src.count
    let result = src.withUnsafeMutableBytes {
        clEnqueueWriteBuffer(ctx.commandQueue, 
                             buffer.mem, 
                             cl_bool(CL_TRUE), 
                             0, count, 
                             $0, 0, nil, nil)
    }
    try checkCLError(result)*/
    //return buffer

    throw ComputeError.notImplemented
}

func downloadComputeBuffer(_ ctx: ComputeContext, src: ComputeBuffer, dst: Data?) throws -> Data {
    /*var dst = dst ?? Data(capacity: src.size)
    guard dst.count >= src.size else {
        throw ComputeError.badInputData(description: "Destination data buffer must be >= buffer.size")
    }
    let result = dst.withUnsafeMutableBytes {
        clEnqueueReadBuffer(ctx.commandQueue, 
                            src.mem, 
                            cl_bool(CL_TRUE), 0, 
                            src.size, $0, 
                            0, nil, nil)
    }
    try checkCLError(result)*/
    //return dst
    throw ComputeError.notImplemented
}

func uploadComputePicture(_ ctx: ComputeContext,
                          pict: PictureSample,
                          maxPlanes: Int = 3,
                          retainCpuBuffer: Bool = true) throws -> PictureSample {
    guard 3 >= maxPlanes else {
        throw ComputeError.badInputData(description: "Input images must have 3 planes or fewer")
    }
    guard let imageBuffer = pict.imageBuffer() else {
        throw ComputeError.badInputData(description: "Missing image buffer")
    }
    let textures = try createTexture(ctx, imageBuffer, maxPlanes).compactMap { $0 }
    let image = ImageBuffer(imageBuffer,
                            computeTextures: textures)
    return PictureSample(pict, img: image)
}

func downloadComputePicture(_ ctx: ComputeContext,
                            pict: PictureSample,
                            maxPlanes: Int = 3,
                            retainGpuBuffer: Bool = true) throws -> PictureSample {
    guard 3 >= maxPlanes else {
        throw ComputeError.badInputData(description: "Input images must have 3 planes or fewer")
    }
    return pict
}

// Creates a series of MTLTextures based on an ImageBuffer (one for each plane in the format)
// Can throw ComputeError
// - badContextState
// - badInputData
private func createTexture(_ ctx: ComputeContext, _ image: ImageBuffer, _ maxPlanes: Int = 3) throws -> [MTLTexture?] {
    guard let textureCache = ctx.textureCache else {
        throw ComputeError.badContextState(description: "No texture cache")
    }
    let planeCount = CVPixelBufferIsPlanar(image.pixelBuffer) ? CVPixelBufferGetPlaneCount(image.pixelBuffer) : 1
    guard 3 >= planeCount else {
        throw ComputeError.badInputData(description: "Input images must have 3 planes or fewer")
    }
    return try (0..<min(planeCount, maxPlanes) as CountableRange).map { idx in
        let pixelFormat: MTLPixelFormat = {
            if planeCount == 3 {
                return .r8Unorm
            } else if planeCount == 2 && idx == 0 {
                return .r8Unorm
            } else if planeCount == 2 && idx == 1 {
                return .rg8Unorm
            }
            return .rgba8Unorm
        }()
        var texture: CVMetalTexture?
        let ret = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                            textureCache,
                                                            image.pixelBuffer,
                                                            nil,
                                                            pixelFormat,
                                                            CVPixelBufferGetWidthOfPlane(image.pixelBuffer, idx),
                                                            CVPixelBufferGetHeightOfPlane(image.pixelBuffer, idx),
                                                            idx,
                                                            &texture)
        guard kCVReturnSuccess == ret else {
            throw ComputeError.badContextState(description: "Could not create texture \(ret)")
        }

        return texture <??> { CVMetalTextureGetTexture($0) } <|> nil
    }
}

// Retrieve a predefined or custom kernel from the library
// Can throw ComputError.computeKernelNotFound
//
private func getComputeKernel( _ context: ComputeContext, _ kernel: ComputeKernel) throws -> MTLFunction {
    var function: MTLFunction?
    switch kernel {
    case .custom(let name):
        function = (context.customLibrary <??> { $0[name]?.makeFunction(name: name) } <|> nil)
    default:
        let name = String(describing: kernel)
        function = context.defaultLibrary?.makeFunction(name: name)
    }
    guard let kernelFunction = function else {
        throw ComputeError.computeKernelNotFound(kernel)
    }
    return kernelFunction
}

// Returns (threadCount, threadgroupSize)
// requiredStaticMemory is a hint for the required memory per thread.
private func makeThreadgroup(_ pipelineState: MTLComputePipelineState,
                             _ bufferSize: MTLSize,
                             requiredStaticMemory: Int? = nil) -> (MTLSize, MTLSize) {
    if let mem = requiredStaticMemory {
        let threadCount = bufferSize
        let maxMem = pipelineState.device.maxThreadgroupMemoryLength
        let threads = maxMem / mem
        let width = sqrt(Double(threads))
        let threadgroupSize = MTLSize(width: Int(floor(width)), height: Int(floor(width)), depth: 1)
        return (threadCount, threadgroupSize)
    } else {
        let threadgroupWidth = pipelineState.threadExecutionWidth
        let threadgroupHeight = pipelineState.maxTotalThreadsPerThreadgroup / threadgroupWidth
        let threadgroupSize = MTLSize(width: threadgroupWidth, height: threadgroupHeight, depth: 1)
        let threadCount = bufferSize
        return (threadCount, threadgroupSize)
    }
}

// Set uniforms at an index
//
private func setUniforms<T>(_ context: ComputeContext,
                            _ commandEncoder: MTLComputeCommandEncoder,
                            _ uniforms: T?,
                            _ index: Int) {

    if var uniforms = uniforms {
        // Workaround for a weird compile error when using `uniforms` directly as the bytes parameter.
        let uniformBuffer = {
            (ptr: UnsafeRawPointer) -> MTLBuffer? in
            context.device.makeBuffer(bytes: ptr, length: MemoryLayout<T>.size, options: [])
        }(&uniforms)
        commandEncoder.setBuffer(uniformBuffer, offset: 0, index: index)
    }
}
#endif
