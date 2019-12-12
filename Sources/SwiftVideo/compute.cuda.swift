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
        self.library = [:]
    }
    deinit {
        if ctx != nil {
            cuCtxDestroy_v2(ctx)
        }
    }
    fileprivate let ctx: CUcontext?
    fileprivate var library: [String: (CUmodule?, CUfunction?)]
}

public struct ComputeContext {
    init(ctx: CUcontext?, logger: Logger) {
        self.ctx = InternalContext(ctx: ctx)
        self.logger = logger
    }
    let logger: Logger
    fileprivate let ctx: InternalContext
}

public class ComputeBuffer {
    // fileprivate let mem: cl_mem
    // fileprivate let ctx: InternalContext
    // fileprivate let size: Int
    // fileprivate init(_ ctx: InternalContext, mem: cl_mem, size: Int) {
    //     self.mem = mem
    //     self.ctx = ctx
    //     self.size = size
    // }
    init() {
        self.mem = nil
    }
    deinit {

    }

    let mem: CUdeviceptr?
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
    default: throw ComputeError.unknownError
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
        throw ComputeError.compilerError(description: String(decoding: log, as: UTF8.self))
    default: throw ComputeError.unknownError
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
   //ComputeContext(device: ctx.device, ctx: ctx.context.ctx, logger: ctx.logger)
    ctx
}

func createComputeContext(_ device: ComputeDevice,
                          logger: Logger = Logger(label: "SwiftVideo")) throws -> ComputeContext? {
    //ComputeContext()
    var ctx: CUcontext?
    try check(cuCtxCreate_v2(&ctx, 0, device.device))

    return ComputeContext(ctx: ctx, logger: logger)
    /*let properties: [cl_context_properties] = [Int(CL_CONTEXT_PLATFORM), Int(bitPattern: device.platformId), 0, 0]
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
        } }*/
}

func destroyComputeContext( _ context: ComputeContext) throws {
    // no-op in cuda, context will be destroyed when last reference is released.
}

func buildComputeKernel(_ context: ComputeContext, name: String, source: String) throws -> ComputeContext {
    context.logger.info("buildComputeKernel")
    var program = try source.withCString { (cstr) -> nvrtcProgram? in
        var prog: nvrtcProgram?
        try check(nvrtcCreateProgram(&prog, cstr, name, 0, nil, nil))
        let opts: [String?] = ["--gpu-architecture=compute_50", "--fmad=false", nil]
        var cargs = opts.map { $0.flatMap { UnsafePointer<Int8>(strdup($0)) } }
        defer { cargs.forEach { ptr in free(UnsafeMutablePointer(mutating: ptr)) } }
        try check(nvrtcCompileProgram(prog, 2, &cargs), prog)
        return prog
    }
    defer { nvrtcDestroyProgram(&program) }
    var ptxSize: size_t =  0
    try check(nvrtcGetPTXSize(program, &ptxSize))
    context.logger.info("Built program \(name) ptx is \(ptxSize) bytes")
    var ptx = Data(count: ptxSize)
    context.ctx.library[name] = try ptx.withUnsafeMutableBytes { buf in
        guard let ptr = buf.baseAddress else { return (nil, nil) }
        try check(nvrtcGetPTX(program, ptr.bindMemory(to: Int8.self, capacity: ptxSize)))
        var module: CUmodule?
        var function: CUfunction?
        try check(cuModuleLoadDataEx(&module, ptr, 0, nil, nil))
        try check(cuModuleGetFunction(&function, module, name))
        return (module, function)
    }
    return context
    /*let (program, errcode) = source.withCString { (cstr: UnsafePointer<Int8>?) -> (cl_program?, cl_int) in
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
    }*/
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
    context
}

func beginComputePass(_ context: ComputeContext) -> ComputeContext {
    cuCtxPushCurrent_v2(context.ctx.ctx)
    return context
}

func endComputePass(_ context: ComputeContext, _ waitForCompletion: Bool) -> ComputeContext {
    if waitForCompletion {
        cuCtxSynchronize()
    }
    cuCtxPopCurrent_v2(nil)
    return context
}

func uploadComputePicture(_ ctx: ComputeContext, pict: PictureSample, maxPlanes: Int = 3) throws -> PictureSample {
    throw ComputeError.notImplemented
}

func downloadComputePicture(_ ctx: ComputeContext, pict: PictureSample) throws -> PictureSample {
    throw ComputeError.notImplemented
}
#endif
