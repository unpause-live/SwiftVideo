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
// swiftlint:disable file_length
#if GPGPU_CUDA
import CCUDA
import VectorMath
import Foundation
import Logging

struct ComputeDevice {
    let device: CUdevice
    let available: Bool
    let deviceType: ComputeDeviceType?
    let vendorId: Int?
    let vendorName: String?
    let supportsImages: Bool
}

private class InternalContext {
    init(ctx: CUcontext?) {
        self.ctx = ctx
    }
    deinit {
        if ctx != nil {
            cuCtxDestroy_v2(ctx)
        }
    }
    fileprivate let ctx: CUcontext?
}

private class CUDAProgram {
    let module: CUmodule?
    let function: CUfunction?
    let ptx: Data
    fileprivate init(module: CUmodule?, function: CUfunction?, ptx: Data) {
        self.module = module
        self.function = function
        self.ptx = ptx
    }
    deinit {
        if let module = module {
            cuModuleUnload(module)
        }
    }
}

public struct ComputeContext {
    init(_ ctx: CUcontext?, logger: Logger) {
        self.ctx = InternalContext(ctx: ctx)
        self.logger = logger
        self.library = [:]
    }
    fileprivate init(_ other: ComputeContext, library: [String: CUDAProgram]? = nil) {
        self.ctx = other.ctx
        self.logger = other.logger
        self.library = library ?? [:]
    }
    let logger: Logger
    fileprivate let ctx: InternalContext
    fileprivate let library: [String: CUDAProgram]
}

public class ComputeBuffer {
    fileprivate init(_ ptr: CUdeviceptr, size: Int, ctx: InternalContext) {
        self.mem = ptr
        self.size = size
        self.ctx = ctx
    }
    deinit {
        if mem > 0 {
            cuCtxPushCurrent_v2(ctx.ctx)
            cuMemFree_v2(mem)
            cuCtxPopCurrent_v2(nil)
        }
    }
    fileprivate let size: Int
    fileprivate var mem: CUdeviceptr // var so we can take the address to pass to the CUDA api.
    fileprivate let ctx: InternalContext
}

private var sInited = false
private func initCuda() {
    if !sInited {
        cuInit(0)
        sInited = true
    }
}

private func check(_ result: CUresult) throws {
    switch result {
    case CUDA_SUCCESS: ()
    case CUDA_ERROR_INVALID_VALUE: throw ComputeError.invalidValue
    case CUDA_ERROR_OUT_OF_MEMORY: throw ComputeError.outOfMemory
    case CUDA_ERROR_INVALID_CONTEXT: throw ComputeError.invalidContext
    case CUDA_ERROR_ILLEGAL_ADDRESS: throw ComputeError.badContextState(description: "Illegal address access")
    case CUDA_ERROR_NOT_FOUND: throw ComputeError.badInputData(description: "Symbol not found")
    default: print("Error \(result)"); throw ComputeError.unknownError
    }
}

private func check(_ result: nvrtcResult, _ prog: nvrtcProgram? = nil) throws {
    switch result {
    case NVRTC_SUCCESS: ()
    case NVRTC_ERROR_INVALID_INPUT: throw ComputeError.invalidValue
    case NVRTC_ERROR_COMPILATION:
        var logSize: size_t = 0
        try check(nvrtcGetProgramLogSize(prog, &logSize))
        var log = Data(count: logSize)
        try log.withUnsafeMutableBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            try check(nvrtcGetProgramLog(prog, ptr.bindMemory(to: Int8.self, capacity: logSize)))
        }
        print("compiler error \( String(decoding: log, as: UTF8.self))")
        throw ComputeError.compilerError(description: String(decoding: log, as: UTF8.self))
    default: print("Error \(result)"); throw ComputeError.unknownError
    }
}

func availableComputeDevices() -> [ComputeDevice] {
    do {
        initCuda()
        var deviceCount: Int32 = 0
        try check(cuDeviceGetCount(&deviceCount))
        return try (0..<deviceCount).map { idx in
            var device: CUdevice = 0
            var computeMode: Int32 = 0
            try check(cuDeviceGet(&device, idx))
            try check(cuDeviceGetAttribute(&computeMode, CU_DEVICE_ATTRIBUTE_COMPUTE_MODE, device))
            return ComputeDevice(device: device,
                available: computeMode == Int32(CU_COMPUTEMODE_DEFAULT.rawValue),
                deviceType: .GPU,
                vendorId: nil,
                vendorName: nil,
                supportsImages: true)
        }
    } catch {
        print("caught error \(error)")
        return []
    }
}

func createComputeContext(sharing ctx: ComputeContext) -> ComputeContext? {
    ComputeContext(ctx)
}

func createComputeContext(_ device: ComputeDevice,
                          logger: Logger = Logger(label: "SwiftVideo")) throws -> ComputeContext? {
    var ctx: CUcontext?
    try check(cuCtxCreate_v2(&ctx, 0, device.device))

    return ComputeContext(ctx, logger: logger)
}

func destroyComputeContext( _ context: ComputeContext) throws {
    // no-op in cuda, context will be destroyed when last reference is released.
}

func buildComputeKernel(_ context: ComputeContext, name: String, source: String) throws -> ComputeContext {
    context.logger.info("buildComputeKernel")
    print("building \(name)")
    var program = try source.withCString { (cstr) -> nvrtcProgram? in
        var prog: nvrtcProgram?
        try check(nvrtcCreateProgram(&prog, cstr, name, 0, nil, nil))
        let opts: [String?] = ["--gpu-architecture=compute_30", "--fmad=false", nil]
        var cargs = opts.map { $0.flatMap { UnsafePointer<Int8>(strdup($0)) } }
        defer { cargs.forEach { ptr in free(UnsafeMutablePointer(mutating: ptr)) } }
        try check(nvrtcCompileProgram(prog, Int32(opts.count)-1, &cargs), prog)
        return prog
    }
    defer { nvrtcDestroyProgram(&program) }
    var ptxSize: size_t =  0
    try check(nvrtcGetPTXSize(program, &ptxSize))
    context.logger.info("Built program \(name) ptx is \(ptxSize) bytes")
    print("Built program \(name) ptx is \(ptxSize) bytes")
    var ptx = Data(count: ptxSize)
    let result: (CUmodule?, CUfunction?) = try ptx.withUnsafeMutableBytes { buf in
        guard let ptr = buf.baseAddress else { throw ComputeError.invalidValue }
        try check(nvrtcGetPTX(program, ptr.bindMemory(to: Int8.self, capacity: ptxSize)))
        var module: CUmodule?
        var function: CUfunction?
        try check(cuModuleLoadData(&module, ptr))
        try check(cuModuleGetFunction(&function, module, name))
        return (module, function)
    }
    let kernel = CUDAProgram(module: result.0, function: result.1, ptx: ptx)
    print("ptx=\(String(decoding: ptx, as: UTF8.self))")
    print("done \(kernel)")
    return ComputeContext(context, library: context.library.merging([name: kernel]) { $1 })
}

private func maybeBuildKernel( _ context: ComputeContext, _ kernel: ComputeKernel) throws -> ComputeContext {
    let name: String = {
        if case .custom(let name) = kernel {
            return name
        }
        return String(describing: kernel)
    }()
    guard context.library[name] == nil else {
        return context
    }
    let defaultKernel = CUDAKernel.allCases.first { String(describing: $0) == name }
    guard let source = defaultKernel?.rawValue else {
        throw ComputeError.computeKernelNotFound(kernel)
    }
    return try buildComputeKernel(context, name: name, source: kCUDAKernelMatrixFuncs + "\n" + source)
}

private func getComputeKernel( _ context: ComputeContext, _ kernel: ComputeKernel) throws -> CUDAProgram {
    var function: CUDAProgram?
    switch kernel {
    case .custom(let name):
        function = context.library[name]
    default:
        let name = String(describing: kernel)
        function = context.library[name]
    }
    guard let kernelFunction = function else {
        throw ComputeError.computeKernelNotFound(kernel)
    }
    return kernelFunction
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
    try runComputeKernel(context,
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
    guard images.allSatisfy({ $0.bufferType() == .gpu }) else {
        throw ComputeError.badInputData(description: "Input images must be uploaded to GPU")
    }
    guard let targetImageBuffer = target.imageBuffer() else {
        throw ComputeError.badTarget
    }
    let context = try maybeBuildKernel(context, kernel)
    let kernelFunction = try getComputeKernel(context, kernel)
    let inputs = images.compactMap { $0.imageBuffer()?.computeTextures }.flatMap { $0 }
    let outputs = targetImageBuffer.computeTextures
    let uniformBuffer = try uniforms.map {
        try withUnsafePointer(to: $0) {
            try [uploadComputeBuffer(context, src: $0, dst: nil, size: MemoryLayout<T>.size)]
        }
    }
    let inputStride: [Int32] = images.compactMap { $0.imageBuffer()?.planes }.flatMap { $0.map { Int32($0.stride) } }

    let inputStrideBuffer = try inputStride.withUnsafeBufferPointer { buf -> [ComputeBuffer]? in
        guard buf.count > 0 else { return nil }
        return try [uploadComputeBuffer(context, src: buf.baseAddress!, dst: nil,
            size: buf.count * MemoryLayout<Int32>.size)]
    }
    let blockSizeX: UInt32 = gcd(UInt32(target.size().x), 16)
    let blockSizeY: UInt32 = gcd(UInt32(target.size().y), 16)
    let blockCountX = UInt32(target.size().x) / blockSizeX
    let blockCountY = UInt32(target.size().y) / blockSizeY
    var args: [UnsafeMutableRawPointer?] = [outputs, inputs, uniformBuffer, inputStrideBuffer]
                                                .compactMap { $0 }
                                                .flatMap { $0 }
                                                .map { UnsafeMutableRawPointer(&$0.mem) }
    if let function = kernelFunction.function {
        try check(cuLaunchKernel(function,
                    blockCountX, blockCountY, 1, // grid size (x, y, z) in blocks
                    blockSizeX, blockSizeY, 1, // block size (x, y, z) in "pixels" (as defined here)
                    0, // shared mem between threadgroups
                    nil, &args, nil))
    }
    return context
}

func beginComputePass(_ context: ComputeContext) -> ComputeContext {
    cuCtxPushCurrent_v2(context.ctx.ctx)
    return context
}

func endComputePass(_ context: ComputeContext, _ waitForCompletion: Bool = false) -> ComputeContext {
    if waitForCompletion {
        let result = cuCtxSynchronize()
    }
    cuCtxPopCurrent_v2(nil)
    return context
}

func uploadComputeBuffer(_ ctx: ComputeContext, src: Data, dst: ComputeBuffer?) throws -> ComputeBuffer {
    try src.withUnsafeBytes {
        guard let ptr = $0.baseAddress else {
            throw ComputeError.invalidValue
        }
        return try uploadComputeBuffer(ctx, src: ptr, dst: dst, size: src.count)
    }
}

private func uploadComputeBuffer(_ ctx: ComputeContext,
                                 src: UnsafeRawPointer,
                                 dst: ComputeBuffer?,
                                 size: Int) throws -> ComputeBuffer {
    let buffer = try dst ?? createBuffer(ctx, size)
    guard buffer.size >= size else {
        throw ComputeError.badInputData(description: "Compute buffer needs to be >= to data.count")
    }
    _ = beginComputePass(ctx)
    try check(cuMemcpyHtoD_v2(buffer.mem, src, size))
    _ = endComputePass(ctx)
    return buffer
}

func downloadComputeBuffer(_ ctx: ComputeContext, src: ComputeBuffer, dst: Data?) throws -> Data {
    let size = src.size
    var dst = dst ?? Data(capacity: size)
    guard dst.count >= size else {
        throw ComputeError.badInputData(description: "Destination data buffer must be >= buffer.size")
    }
    _ = beginComputePass(ctx)
    try dst.withUnsafeMutableBytes {
        guard let ptr = $0.baseAddress else { return }
        try check(cuMemcpyDtoH_v2(ptr, src.mem, size))
    }
    _ = endComputePass(ctx)
    return dst
}

func uploadComputePicture(_ ctx: ComputeContext, pict: PictureSample, maxPlanes: Int = 3) throws -> PictureSample {
    guard pict.bufferType() == .cpu else {
        return pict
    }
    guard let imageBuffer = pict.imageBuffer() else {
        throw ComputeError.badInputData(description: "Missing image buffer")
    }

    let textures = try createTexture(ctx, imageBuffer, maxPlanes)
    _  = beginComputePass(ctx)
    try zip(textures, imageBuffer.buffers).forEach {
        _ = try uploadComputeBuffer(ctx, src: $0.1, dst: $0.0)
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
    let buffers = try zip(imageBuffer.computeTextures, imageBuffer.buffers).map {
        try downloadComputeBuffer(ctx, src: $0.0, dst: $0.1)
    }
    _ = endComputePass(ctx, true)
    let image = ImageBuffer(imageBuffer, buffers: buffers, bufferType: .cpu)
    return PictureSample(pict, img: image)
}

private func createBuffer(_ ctx: ComputeContext, _ size: Int) throws -> ComputeBuffer {
    var buf: CUdeviceptr = 0
    _ = beginComputePass(ctx)
    try check(cuMemAlloc_v2(&buf, size))
    _ = endComputePass(ctx)
    return ComputeBuffer(buf, size: size, ctx: ctx.ctx)
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
        let size = Int(plane.size.y) * plane.stride
        return try createBuffer(ctx, size)
    }
}
#else
private func createTexture(_ ctx: ComputeContext,
                           _ image: ImageBuffer,
                           _ maxPlanes: Int = 3) throws -> [ComputeBuffer] {
    throw ComputeError.notImplemented
}
#endif

#endif
