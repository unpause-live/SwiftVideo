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

#if os(Linux) || (os(macOS) && GPGPU_OCL)
#if os(macOS)
#warning ("macOS support is deprecated, this is only for development. Use Metal for production.")
import OpenCL
import CoreVideo
#else
import CSwiftVideo
#endif
import Logging
import VectorMath
import Foundation

private struct Platform {
    let platformId: cl_platform_id
    let name: String?
    let vendor: String?
    let version: String?
}

struct ComputeDevice {
    let deviceId: cl_device_id
    let platformId: cl_platform_id
    let available: Bool
    let deviceType: ComputeDeviceType?
    let vendorId: Int?
    let vendorName: String?
    let supportsImages: Bool
}

public class ComputeBuffer {
    fileprivate let mem: cl_mem
    fileprivate let ctx: InternalContext
    fileprivate let size: Int
    fileprivate init(_ ctx: InternalContext, mem: cl_mem, size: Int) {
        self.mem = mem
        self.ctx = ctx
        self.size = size
    }
    deinit {
        _ = clReleaseMemObject(mem)
    }
}

private class InternalContext {
    init(_ ctx: cl_context) {
        self.ctx = ctx
        self.library = [:]
    }
    deinit {
        _ = clReleaseContext(self.ctx)
        library.forEach { (_, prog) in
            clReleaseProgram(prog.0)
            clReleaseKernel(prog.1)
        }
    }
    fileprivate let ctx: cl_context
    fileprivate var library: [String: (cl_program, cl_kernel)]
}
public struct ComputeContext {
    fileprivate init(device: ComputeDevice, ctx: cl_context, logger: Logger) {
        self.device = device
        self.context = InternalContext(ctx)
        self.commandQueue = clCreateCommandQueue(ctx, self.device.deviceId, 0, nil)
        self.logger = logger
    }
    fileprivate init(device: ComputeDevice, ctx: InternalContext, logger: Logger) {
        self.device = device
        self.context = ctx
        self.commandQueue = clCreateCommandQueue(ctx.ctx, self.device.deviceId, 0, nil)
        self.logger = logger
    }
    fileprivate init(other: ComputeContext, library: [String: (cl_program, cl_kernel)]) {
        self.device = other.device
        self.context = other.context
        self.context.library = library
        self.commandQueue = other.commandQueue
        self.logger = other.logger
    }
    func clContext() -> cl_context {
        return self.context.ctx
    }
    func library() -> [String: (cl_program, cl_kernel)] {
        return self.context.library
    }
    let device: ComputeDevice
    fileprivate let context: InternalContext
    let commandQueue: cl_command_queue?
    let logger: Logger
}

func availableComputeDevices() -> [ComputeDevice] {
    getPlatforms().flatMap(getDevices)
}

func createComputeContext(sharing ctx: ComputeContext) -> ComputeContext? {
    ComputeContext(device: ctx.device, ctx: ctx.context.ctx, logger: ctx.logger)
}

func createComputeContext(_ device: ComputeDevice,
                          logger: Logger = Logger(label: "SwiftVideo")) throws -> ComputeContext? {
    let properties: [cl_context_properties] = [Int(CL_CONTEXT_PLATFORM), Int(bitPattern: device.platformId), 0, 0]
    let deviceIds: [cl_device_id?] = [device.deviceId]
    var error: cl_int = 0
    let ctx = clCreateContext(properties, cl_uint(deviceIds.count), deviceIds, nil, nil, &error)
    logger.info("createComputeContext")
    if error != CL_SUCCESS {
        switch error {
        case CL_INVALID_PLATFORM:
            throw ComputeError.invalidPlatform
        case CL_INVALID_DEVICE:
            throw ComputeError.invalidDevice
        case CL_INVALID_VALUE:
            throw ComputeError.invalidValue
        case CL_DEVICE_NOT_AVAILABLE:
            throw ComputeError.deviceNotAvailable
        case CL_OUT_OF_HOST_MEMORY:
            throw ComputeError.outOfMemory
        default:
            throw ComputeError.unknownError
        }
    }

    return try ctx.map {
        try OpenCLKernel.allCases.reduce(ComputeContext(device: device, ctx: $0, logger: logger)) {
            try buildComputeKernel($0,
                                   name: String(describing: $1),
                                   source: kOpenCLKernelMatrixFuncs + "\n" + $1.rawValue)
        } }
}

func destroyComputeContext( _ context: ComputeContext) throws {
    if let queue = context.commandQueue {
        clReleaseCommandQueue(queue)
    }
}

func buildComputeKernel(_ context: ComputeContext, name: String, source: String) throws -> ComputeContext {
    context.logger.info("buildComputeKernel")
    let (program, errcode) = source.withCString { (cstr: UnsafePointer<Int8>?) -> (cl_program?, cl_int) in
        var errcode: cl_int = 0
        var mutStr: UnsafePointer<Int8>? = UnsafePointer(cstr)
        let pid = clCreateProgramWithSource(context.clContext(), 1, &mutStr, [source.count], &errcode)
        return (pid, errcode)
    }

    try checkCLError(errcode)

    var deviceIds: cl_device_id? = context.device.deviceId
    if let program = program {
        var error = clBuildProgram(program, 1,
                       &deviceIds,
                       nil,
                       nil,
                       nil)
        guard CL_SUCCESS == error else {
            var val = [UInt8](repeating: 0, count: 10240)
            var len: Int = 0
            clGetProgramBuildInfo(program,
                                  deviceIds,
                                  cl_program_build_info(CL_PROGRAM_BUILD_LOG),
                                  val.count,
                                  &val, &len)
            let log = String(bytes: val.prefix(through: len), encoding: .utf8)
            if let log = log {
                context.logger.info("Build log:\n\(log)")
            }
            throw ComputeError.badInputData(description: "Unable to create kernel named \(name) \(error)")
        }
        let kernel = clCreateKernel(program, name, &error)
        guard let krn = kernel else {
            throw ComputeError.badInputData(description: "Unable to create kernel named \(name) \(error)")
        }
        return ComputeContext(other: context, library: context.library().merging([name: (program, krn)]) {
            clReleaseProgram($0.0)
            clReleaseKernel($0.1)
            return $1
        })
    } else {
        throw ComputeError.unknownError
    }
}

private func maybeBuildKernel( _ context: ComputeContext, _ kernel: ComputeKernel) throws -> ComputeContext {
    let name: String = {
        if case .custom(let name) = kernel {
            return name
        }
        return String(describing: kernel)
    }()
    guard context.library()[name] == nil else {
        return context
    }
    let defaultKernel = OpenCLKernel.allCases.first { String(describing: $0) == name }
    guard let source = defaultKernel?.rawValue else {
        throw ComputeError.computeKernelNotFound(kernel)
    }
    return try buildComputeKernel(context, name: name, source: kOpenCLKernelMatrixFuncs + "\n" + source)
}

// Retrieve a predefined or custom kernel from the library
// Can throw ComputError.computeKernelNotFound
//
private func getComputeKernel( _ context: ComputeContext, _ kernel: ComputeKernel) throws -> (cl_program, cl_kernel) {
    var function: (cl_program, cl_kernel)?
    switch kernel {
    case .custom(let name):
        function = context.library()[name]
    default:
        let name = String(describing: kernel)
        function = context.library()[name]
    }
    guard let kernelFunction = function else {
        throw ComputeError.computeKernelNotFound(kernel)
    }
    return kernelFunction
}

func beginComputePass(_ context: ComputeContext) -> ComputeContext {
    // no-op on OpenCL
    context
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
    let context = try maybeBuildKernel(context, kernel)
    let kernelFunction = try getComputeKernel(context, kernel)
    guard let commandQueue = context.commandQueue else {
        throw ComputeError.badContextState(description: "No command queue")
    }
    guard let targetImageBuffer = target.imageBuffer() else {
        throw ComputeError.badTarget
    }
    let inputs = try images.reduce([ComputeBuffer]()) {
        guard let image = $1.imageBuffer() else {
            throw ComputeError.badInputData(description: "Bad input image")
        }
        let result = try $0 + createTexture(context, image, maxPlanes)
        return result
    }

    let outputs = targetImageBuffer.computeTextures

    // writeable output
    try outputs.enumerated().forEach {
        var mem = $0.element.mem
        let result = clSetKernelArg(kernelFunction.1,
                                    UInt32($0.offset),
                                    MemoryLayout<cl_mem>.size,
                                    &mem)
        if result != CL_SUCCESS {
            throw ComputeError.badContextState(description: "OpenCL error \(result) binding output texture")
        }
    }
    if blends {
        // read-only current samples
        try outputs.enumerated().forEach {
            var mem = $0.element.mem
            let result = clSetKernelArg(kernelFunction.1,
                                        UInt32($0.offset + outputs.count),
                                        MemoryLayout<cl_mem>.size,
                                        &mem)
            if result != CL_SUCCESS {
                throw ComputeError.badContextState(description: "OpenCL error \(result) binding output texture")
            }
        }
    }
    let outputArgCount = blends ? outputs.count * 2 : outputs.count
    // read-only input samples
    try inputs.enumerated().forEach {
        var mem = $0.element.mem
        let result = clSetKernelArg(kernelFunction.1,
                       UInt32($0.offset + outputArgCount),
                       MemoryLayout<cl_mem>.size,
                       &mem)
        if result != CL_SUCCESS {
            throw ComputeError.badContextState(description: "OpenCL error \(result) binding input texture")
        }
    }

    let uniformBuf = setUniforms(context, kernelFunction.1, uniforms, inputs.count + outputArgCount)

    var workSize: [Int] = [Int(target.size().x), Int(target.size().y)]
    let res = clEnqueueNDRangeKernel(commandQueue,
                               kernelFunction.1,
                               UInt32(workSize.count),
                               nil,
                               &workSize,
                               nil, 0, nil, nil)

    _ = uniformBuf.map { clReleaseMemObject($0) }

    guard CL_SUCCESS == res else {
        throw ComputeError.badContextState(description: "OpenCL error running kernel named \(kernel) \(res)")
    }

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

func endComputePass( _ context: ComputeContext, _ waitForCompletion: Bool ) -> ComputeContext {
    guard let queue = context.commandQueue else {
        return context
    }
    #if !os(macOS)
    // clEnqueueReadImage
    #endif
    if waitForCompletion {
        clFinish(queue)
    } else {
        clFlush(queue)
    }
    return context
}

func uploadComputeBuffer(_ ctx: ComputeContext, src: Data, dst: ComputeBuffer?) throws -> ComputeBuffer {

    let buffer = try dst ?? createBuffer(ctx, src.count)

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
                             $0.baseAddress, 0, nil, nil)
    }
    try checkCLError(result)
    return buffer
}

func downloadComputeBuffer(_ ctx: ComputeContext, src: ComputeBuffer, dst: Data?) throws -> Data {
    var dst = dst ?? Data(capacity: src.size)
    guard dst.count >= src.size else {
        throw ComputeError.badInputData(description: "Destination data buffer must be >= buffer.size")
    }
    let result = dst.withUnsafeMutableBytes {
        clEnqueueReadBuffer(ctx.commandQueue,
                            src.mem,
                            cl_bool(CL_TRUE), 0,
                            src.size, $0.baseAddress,
                            0, nil, nil)
    }
    try checkCLError(result)
    return dst
}

#if os(macOS)
func uploadComputePicture(_ ctx: ComputeContext, pict: PictureSample, maxPlanes: Int = 3) throws -> PictureSample {
    guard 3 >= maxPlanes else {
        throw ComputeError.badInputData(description: "Input images must have 3 planes or fewer")
    }
    guard let imageBuffer = pict.imageBuffer() else {
        throw ComputeError.badInputData(description: "Missing image buffer")
    }
    let textures = try createTexture(ctx, imageBuffer, maxPlanes)
    let image = ImageBuffer(imageBuffer, computeTextures: textures)
    return PictureSample(pict, img: image)
}

func downloadComputePicture(_ ctx: ComputeContext, pict: PictureSample, maxPlanes: Int = 3) throws -> PictureSample {
    guard 3 >= maxPlanes else {
        throw ComputeError.badInputData(description: "Input images must have 3 planes or fewer")
    }
    return pict
}

#endif

#if os(Linux)
// Creates a PictureSample that exists on the GPU
func uploadComputePicture(_ ctx: ComputeContext, pict: PictureSample, maxPlanes: Int = 3) throws -> PictureSample {
    guard pict.bufferType() == .cpu else {
        return pict
    }
    guard let imageBuffer = pict.imageBuffer() else {
        throw ComputeError.badInputData(description: "Missing image buffer")
    }

    let textures = try createTexture(ctx, imageBuffer, maxPlanes)
    _  = beginComputePass(ctx)
    try ((0..<textures.count) as CountableRange).forEach { idx in
        let texture = textures[idx]
        let buffer = imageBuffer.buffers[idx]
        let plane = imageBuffer.planes[idx]
        let origin = [0, 0, 0]
        let region = [Int(plane.size.x), Int(plane.size.y), 1]
        let result = buffer.withUnsafeBytes {
            clEnqueueWriteImage(ctx.commandQueue,
                                 texture.mem,
                                 cl_bool(CL_TRUE),
                                 origin,
                                 region,
                                 plane.stride,
                                 0,
                                 $0.baseAddress,
                                 0, nil, nil)
        }
        try checkCLError(result)
    }
    _ = endComputePass(ctx, true)
    let image = ImageBuffer(imageBuffer, computeTextures: textures, bufferType: .gpu)
    return PictureSample(pict, img: image)
}

func downloadComputePicture(_ ctx: ComputeContext, pict: PictureSample) throws -> PictureSample {
    guard pict.bufferType() == .gpu else {
        return pict
    }
    guard let imageBuffer = pict.imageBuffer() else {
        throw ComputeError.badInputData(description: "Missing image buffer")
    }
    _ = beginComputePass(ctx)
    let buffers = try ((0..<imageBuffer.computeTextures.count) as CountableRange).map { idx -> Data in
        let plane = imageBuffer.planes[idx]
        var buffer = imageBuffer.buffers[safe: idx] ?? Data(count: Int(plane.size.y) * plane.stride)
        let texture = imageBuffer.computeTextures[idx]
        let origin = [0, 0, 0]
        let region = [Int(plane.size.x), Int(plane.size.y), 1]

        let result = buffer.withUnsafeMutableBytes {
            clEnqueueReadImage(ctx.commandQueue,
                               texture.mem,
                               cl_bool(CL_TRUE),
                               origin,
                               region,
                               plane.stride,
                               0,
                               $0.baseAddress,
                               0, nil, nil)
        }
        try checkCLError(result)
        return buffer
    }
    _ = endComputePass(ctx, true)
    let image = ImageBuffer(imageBuffer, buffers: buffers, bufferType: .cpu)
    return PictureSample(pict, img: image)
}
#endif

private func setUniforms<T>(_ context: ComputeContext,
                            _ kernel: cl_kernel,
                            _ uniforms: T?,
                            _ index: Int) -> cl_mem? {

    if var uniforms = uniforms {
        var err: cl_int = 0
        var buf = clCreateBuffer(context.clContext(),
                       cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR),
                       MemoryLayout<T>.size,
                       &uniforms,
                       &err)
        clSetKernelArg(kernel,
                       cl_uint(index),
                       MemoryLayout<cl_mem>.size,
                       &buf)
        return buf
    }
    return nil
}

private func createBuffer(_ ctx: ComputeContext, _ size: Int) throws -> ComputeBuffer {
    var error: cl_int = 0
    let mem = clCreateBuffer(ctx.clContext(), UInt64(CL_MEM_READ_WRITE), Int(size), nil, &error)
    guard let buffer = mem, CL_SUCCESS == error else {
        throw ComputeError.badContextState(description: "Could not create OpenCL buffer \(error)")
    }
    return ComputeBuffer(ctx.context, mem: buffer, size: size)
}

#if os(Linux)
private func createTexture(_ ctx: ComputeContext,
                           _ image: ImageBuffer,
                           _ maxPlanes: Int = 3) throws -> [ComputeBuffer] {
    let planeCount = image.planes.count
    guard 3 >= planeCount &&  0 < planeCount else {
        throw ComputeError.badInputData(description: "Input image must have 1, 2, or 3 planes")
    }
    guard planeCount == image.buffers.count else {
        throw ComputeError.badInputData(description: "Input image must have the same number of buffers as planes")
    }
    guard min(planeCount, maxPlanes) != image.computeTextures.count else {
        return image.computeTextures
    }
    return try (0..<min(planeCount, maxPlanes) as CountableRange).map { idx in
        let plane = image.planes[idx]
        let components = plane.components.count
        var pixelFormat: cl_image_format = {
            switch components {
            case 1: return cl_image_format(image_channel_order: cl_uint(CL_R),
                                           image_channel_data_type: cl_uint(CL_UNORM_INT8))
            case 2: return cl_image_format(image_channel_order: cl_uint(CL_RG),
                                           image_channel_data_type: cl_uint(CL_UNORM_INT8))
            case 3: return cl_image_format(image_channel_order: cl_uint(CL_RGB),
                                           image_channel_data_type: cl_uint(CL_UNORM_INT8))
            default: return cl_image_format(image_channel_order: cl_uint(CL_RGBA),
                                            image_channel_data_type: cl_uint(CL_UNORM_INT8))
        } }()
        var imgDesc = cl_image_desc(image_type: cl_uint(CL_MEM_OBJECT_IMAGE2D),
                                     image_width: Int(plane.size.x),
                                     image_height: Int(plane.size.y),
                                     image_depth: 1,
                                     image_array_size: 0,
                                     image_row_pitch: 0,
                                     image_slice_pitch: 0,
                                     num_mip_levels: 0,
                                     num_samples: 0,
                                     .init(buffer: nil))
        var error: cl_int = 0
        let texture = clCreateImage(ctx.clContext(),
                                    cl_mem_flags(bitPattern: Int64(CL_MEM_READ_WRITE)),
                                    &pixelFormat,
                                    &imgDesc,
                                    nil,
                                    &error)
        guard let tex = texture, CL_SUCCESS == error else {
            throw ComputeError.badContextState(description: "Could not create OpenCL image \(error)")
        }
        return ComputeBuffer(ctx.context, mem: tex, size: Int(plane.size.x) * Int(plane.size.y) * components)
    }
}

#endif

#if os(macOS)
// Creates a series of OpenGL Textures based on a CVPixelBuffer (one for each plane in the format)
// Can throw ComputeError
// - badContextState
// - badInputData
private func createTexture(_ ctx: ComputeContext,
                           _ image: ImageBuffer,
                           _ maxPlanes: Int = 3) throws -> [ComputeBuffer] {

    let planeCount = CVPixelBufferIsPlanar(image.pixelBuffer) ? CVPixelBufferGetPlaneCount(image.pixelBuffer) : 1
    guard 3 >= planeCount else {
        throw ComputeError.badInputData(description: "Input images must have 3 planes or fewer")
    }
    guard let ioSurface = CVPixelBufferGetIOSurface(image.pixelBuffer) else {
        throw ComputeError.badInputData(description: "Image must be an IOSurface")
    }
    return try (0..<min(planeCount, maxPlanes) as CountableRange).map { idx in
        var pixelFormat: cl_image_format = {
            if planeCount == 3 {
                return cl_image_format(image_channel_order: cl_uint(CL_R),
                                       image_channel_data_type: cl_uint(CL_UNORM_INT8))
            } else if planeCount == 2 && idx == 0 {
                return cl_image_format(image_channel_order: cl_uint(CL_R),
                                       image_channel_data_type: cl_uint(CL_UNORM_INT8))
            } else if planeCount == 2 && idx == 1 {
                return cl_image_format(image_channel_order: cl_uint(CL_RG),
                                       image_channel_data_type: cl_uint(CL_UNORM_INT8))
            }
            return cl_image_format(image_channel_order: cl_uint(CL_BGRA),
                                   image_channel_data_type: cl_uint(CL_UNORM_INT8))
        }()
        var imgDesc = cl_image_desc(image_type: cl_uint(CL_MEM_OBJECT_IMAGE2D),
                                     image_width: CVPixelBufferGetWidthOfPlane(image.pixelBuffer, idx),
                                     image_height: CVPixelBufferGetHeightOfPlane(image.pixelBuffer, idx),
                                     image_depth: 1,
                                     image_array_size: 0,
                                     image_row_pitch: CVPixelBufferGetBytesPerRowOfPlane(image.pixelBuffer, idx),
                                     image_slice_pitch: 0,
                                     num_mip_levels: 0,
                                     num_samples: 0,
                                     buffer: nil)
        let surfRef = intptr_t(bitPattern: ioSurface.toOpaque())
        var ioProps: [cl_iosurface_properties_APPLE] = [Int(CL_IOSURFACE_REF_APPLE),
                                                         surfRef,
                                                         Int(CL_IOSURFACE_PLANE_APPLE), idx, 0]
        var error: cl_int = 0
        let texture = clCreateImageFromIOSurfaceWithPropertiesAPPLE(ctx.clContext(),
                                                      cl_mem_flags(bitPattern: Int64(CL_MEM_READ_WRITE)),
                                                      &pixelFormat,
                                                      &imgDesc,
                                                      &ioProps,
                                                      &error)

        guard let tex = texture else {
            throw ComputeError.badContextState(description: "Could not create OpenCL image \(error)")
        }
        return ComputeBuffer(ctx.context, mem: tex, size: 0)
    }
}
#endif

private func getPlatformInfo(_ platformId: cl_platform_id, _ info: Int32) -> String? {
    var size: Int = 0
    let param = cl_platform_info(info)
    guard 0 == clGetPlatformInfo(platformId, param, 0, nil, &size) else {
        return nil
    }
    var val = [UInt8](repeating: 0, count: size)

    if 0 == clGetPlatformInfo(platformId, param, size, &val, nil) {
        return String(bytes: val.prefix(through: val.count-2), encoding: .utf8)
    }
    return nil
}

private func getPlatforms() -> [Platform] {
    var platformCt: cl_uint = 0

    guard 0 == clGetPlatformIDs(0, nil, &platformCt) else {
        return [Platform]()
    }

    var platformIds = [cl_platform_id?](repeating: nil, count: Int(platformCt))

    guard 0 == clGetPlatformIDs(platformCt, &platformIds, nil) else {
        return [Platform]()
    }

    return platformIds.reduce([Platform]()) { acc, val in val <??> {
        let platform = Platform(
            platformId: $0,
            name: getPlatformInfo($0, CL_PLATFORM_NAME),
            vendor: getPlatformInfo($0, CL_PLATFORM_VENDOR),
            version: getPlatformInfo($0, CL_PLATFORM_VERSION))
        return acc + [platform]
        } <|> acc }
}

private func checkCLError(_ errcode: Int32) throws {
    guard CL_SUCCESS == errcode else {
        switch errcode {
        case CL_INVALID_PROGRAM:
            throw ComputeError.invalidProgram
        case CL_INVALID_VALUE:
            throw ComputeError.invalidValue
        case CL_INVALID_DEVICE:
            throw ComputeError.invalidDevice
        case CL_INVALID_BINARY:
            throw ComputeError.unknownError
        case CL_INVALID_BUILD_OPTIONS:
            throw ComputeError.unknownError
        case CL_INVALID_OPERATION:
            throw ComputeError.invalidOperation
        case CL_COMPILER_NOT_AVAILABLE:
            throw ComputeError.compilerNotAvailable
        case CL_BUILD_PROGRAM_FAILURE:
            throw ComputeError.unknownError
        case CL_OUT_OF_HOST_MEMORY:
            throw ComputeError.outOfMemory
        default:
            throw ComputeError.unknownError
        }
    }
}
private func getDeviceInfo<T>(_ deviceId: cl_device_id, _ info: Int32) -> T? where T: BinaryInteger {
    var val: T = 0
    let res = clGetDeviceInfo(deviceId, cl_device_info(info), MemoryLayout<T>.size, &val, nil)
    guard 0 == res else {
        return nil
    }
    return val
}

private func getDeviceInfo(_ deviceId: cl_device_id, _ info: Int32) -> String? {
    var size: Int = 0
    let param = cl_device_info(info)
    guard 0 == clGetDeviceInfo(deviceId, param, 0, nil, &size) else {
        return nil
    }
    var val = [UInt8](repeating: 0, count: size)

    if 0 == clGetDeviceInfo(deviceId, param, size, &val, nil) {
        return String(bytes: val.prefix(through: val.count-2), encoding: .utf8)
    }
    return nil
}

private func getDeviceInfo(_ deviceId: cl_device_id, _ info: Int32) -> Bool {
    let val: UInt32? = getDeviceInfo(deviceId, info)
    return val <??> { $0 > 0 } <|> false
}

private func getDeviceType(_ deviceId: cl_device_id) -> ComputeDeviceType? {
    let type: cl_device_type? = getDeviceInfo(deviceId, CL_DEVICE_TYPE)
    if let sgType = type {
        switch sgType {
        case UInt64(CL_DEVICE_TYPE_GPU):
            return .GPU
        case UInt64(CL_DEVICE_TYPE_CPU):
            return .CPU
        case UInt64(CL_DEVICE_TYPE_ACCELERATOR):
            return .Accelerator
        default:
            return .Default
        }
    }
    return nil
}

private func getDeviceVendorId(_ deviceId: cl_device_id) -> Int? {
    return getDeviceInfo(deviceId, CL_DEVICE_VENDOR_ID).map { (val: cl_uint) in Int(val) }
}

private func getDevices(_ platform: Platform) -> [ComputeDevice] {
    var deviceCt: cl_uint = 0
    guard 0 == clGetDeviceIDs(platform.platformId, cl_device_type(CL_DEVICE_TYPE_ALL), 0, nil, &deviceCt) else {
        return [ComputeDevice]()
    }
    var deviceIds = [cl_device_id?](repeating: nil, count: Int(deviceCt))
    guard 0 == clGetDeviceIDs(platform.platformId, cl_device_type(CL_DEVICE_TYPE_ALL), deviceCt, &deviceIds, nil) else {
        return [ComputeDevice]()
    }

    return deviceIds.reduce([ComputeDevice]()) { acc, val in val <??> {
        let device = ComputeDevice(deviceId: $0,
                                   platformId: platform.platformId,
                                   available: getDeviceInfo($0, CL_DEVICE_AVAILABLE),
                                   deviceType: getDeviceType($0),
                                   vendorId: getDeviceVendorId($0),
                                   vendorName: getDeviceInfo($0, CL_DEVICE_VENDOR),
                                   supportsImages: getDeviceInfo($0, CL_DEVICE_IMAGE_SUPPORT))
        dump(device)
        return acc + [device]
        } <|> acc }
}

#endif
