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
// swiftlint:disable identifier_name
// swiftlint:disable line_length
// swiftlint:disable type_body_length

#if GPGPU_CUDA
import Foundation

let kCUDAKernelMatrixFuncs =
"""
#define vecmat4(__vec__, __mat__) (make_float4(dot(__vec__, __mat__[0]), dot(__vec__, __mat__[1]), dot(__vec__, __mat__[2]), dot(__vec__, __mat__[3])))
#define clamp(__x__, __min__, __max__) min((__max__), max((__min__), (__x__)))
#define blend(__x__, __y__, __a__) (((1.f - (__a__)) * (__x__)) + ((__a__)*(__y__)))

#define PRELUDE extern \"C\" __global__

typedef struct {
    float4 transform[4];
    float4 textureTx[4];
    float4 borderMatrix[4];
    float4 fillColor;
    float2 inSize;
    float2 outSize;
    float opacity;
    float sampleTime;
    float targetTime;
} ImageUniforms;

__device__ float dot(float4 a, float4 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}

__device__ void transpose(float4 out[4], const float4 in[4]) {
    out[0] = make_float4(in[0].x, in[1].x, in[2].x, in[3].x);
    out[1] = make_float4(in[0].y, in[1].y, in[2].y, in[3].y);
    out[2] = make_float4(in[0].z, in[1].z, in[2].z, in[3].z);
    out[3] = make_float4(in[0].w, in[1].w, in[2].w, in[3].w);
}
__device__ void write_imagef(unsigned char* buf, const int2 gid, const float value, const int stride) {
    const int offset = gid.y * stride + gid.x;
    buf[offset] = (unsigned char)(value * 255.f);
}

__device__ float read_imagef(const unsigned char* buf, const int2 gid, const int stride) {
    const int offset = gid.y * stride + gid.x;
    const unsigned char val = buf[offset];
    return (float)val / 255.f;
}

__device__ float read_imagef_bilinear(const unsigned char* buf, const int2 gid, const int2 size, const int stride) {
    #define clamp_x(__x__) clamp((__x__), 0, size.x-1)
    #define clamp_y(__y__) clamp((__y__), 0, size.y-1)

    float4 samples = make_float4(read_imagef(buf, gid, stride),
        read_imagef(buf, make_int2(clamp_x(gid.x+1), gid.y), stride),
        read_imagef(buf, make_int2(gid.x, clamp_y(gid.y+1)), stride),
        read_imagef(buf, make_int2(clamp_x(gid.x+1), clamp_y(gid.y+1)), stride));

    float2 pos = make_float2((float)gid.x/(float)size.x, (float)gid.y/(float)size.y);
    float2 wx = make_float2(1.f - (pos.x - floorf(pos.x)), pos.x - floorf(pos.x));
    float2 wy = make_float2(1.f - (pos.y - floorf(pos.y)), pos.y - floorf(pos.y));
    float4 weights = make_float4(wx.x*wy.x, wx.y*wy.x, wx.x*wy.y, wx.y*wy.y);

    #undef clamp_x
    #undef clamp_y
    return dot(samples, weights);
}

__device__ float4 read_image4f(const unsigned char* buf, const int2 gid, const int stride) {
    const int offset = gid.y * stride + gid.x*4;
    const unsigned char x = buf[offset];
    const unsigned char y = buf[offset+1];
    const unsigned char z = buf[offset+2];
    const unsigned char w = buf[offset+3];
    return make_float4((float)x/255.f, (float)y/255.f, (float)z/255.f, (float)w/255.f);
}

__device__ float4 read_image4f_bilinear(const unsigned char* buf, const int2 gid, const int2 size, const int stride) {
    #define clamp_x(__x__) clamp((__x__), 0, size.x-1)
    #define clamp_y(__y__) clamp((__y__), 0, size.y-1)

    float4 samples[4] = {
        read_image4f(buf, gid, stride),
        read_image4f(buf, make_int2(clamp_x(gid.x+1), gid.y), stride),
        read_image4f(buf, make_int2(gid.x, clamp_y(gid.y+1)), stride),
        read_image4f(buf, make_int2(clamp_x(gid.x+1), clamp_y(gid.y+1)), stride)
    };
    float2 pos = make_float2((float)gid.x/(float)size.x, (float)gid.y/(float)size.y);
    float2 wx = make_float2(1.f - (pos.x - floorf(pos.x)), pos.x - floorf(pos.x));
    float2 wy = make_float2(1.f - (pos.y - floorf(pos.y)), pos.y - floorf(pos.y));
    float4 weights = make_float4(wx.x*wy.x, wx.y*wy.x, wx.x*wy.y, wx.y*wy.y);
    float4 out[4];
    transpose(out, samples);

    #undef clamp_x
    #undef clamp_y
    return vecmat4(weights, out);
}

__device__ int2 div(int2 lhs, int rhs) {
    return make_int2(lhs.x / rhs, lhs.y / rhs);
}

#define DECLARE_RGB2YUV const float4 RGB2YUV[4] = { make_float4(0.299f, 0.587f, 0.113f, 0.f), \\
  make_float4(-0.169f, -0.331f, 0.5f, 0.5f), \\
  make_float4(0.5f, -0.419f, -0.081f, 0.5f), \\
  make_float4(0.f, 0.f, 0.f, 1.f) };
"""
enum CUDAKernel: String, CaseIterable {
  case img_clear_y420p =
    """
    PRELUDE void img_clear_y420p(unsigned char* outLuma,
                                 unsigned char* outChromaU,
                                 unsigned char* outChromaV) {
      int2 gid = make_int2(blockIdx.x * blockDim.x + threadIdx.x, blockIdx.y * blockDim.y + threadIdx.y);
      const int2 chromaPos = div(gid, 2);
      const int stride = blockDim.x * gridDim.x;
      const int chromaStride = stride / 2;
      const float luma = (float)gid.y / (float)(blockDim.y * gridDim.y);
      const float chroma = (float)gid.x / (float)(blockDim.x * gridDim.x);
      write_imagef(outLuma, gid, luma, stride);
      write_imagef(outChromaU, chromaPos, chroma, chromaStride);
      write_imagef(outChromaV, chromaPos, 1.f - chroma, chromaStride);
    }
    """
  case img_bgra_y420p =
    """
    PRELUDE void img_bgra_y420p(unsigned char*  outLuma,
                                 unsigned char*  outChromaU,
                                 unsigned char*  outChromaV,
                                 const unsigned char*  inPixels,
                                 const ImageUniforms* uniforms,
                                 const int* inStride) {
        DECLARE_RGB2YUV;
        const int outStride = gridDim.x*blockDim.x;
        const int2 inSize = make_int2(uniforms->inSize.x, uniforms->inSize.y);
        int2 gid = make_int2(blockIdx.x * blockDim.x + threadIdx.x, blockIdx.y * blockDim.y + threadIdx.y);
        float2 size = make_float2(gridDim.x*blockDim.x, gridDim.y*blockDim.y);
        const float2 out_uv = make_float2((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = make_float4(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f &&  border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float curY = read_imagef(outLuma, gid, outStride);
            float curU;
            float curV;
            if(handleChroma) {
                curU = read_imagef(outChromaU, div(gid, 2), outStride/2);
                curV = read_imagef(outChromaV, div(gid, 2), outStride/2);
            }
            float alpha = uniforms->opacity * uniforms->fillColor.w;
            float4 fillColor = vecmat4(make_float4(uniforms->fillColor.x * alpha, uniforms->fillColor.y * alpha, uniforms->fillColor.z * alpha, 1.0), RGB2YUV);
            float3 result;
            result.x = blend(curY, fillColor.x, alpha);
            result.y = clamp(blend(curU, fillColor.y, alpha), -1.f, 1.f);
            result.z = clamp(blend(curV, fillColor.z, alpha), -1.f, 1.f);
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0 &&
               uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                int2 pos = make_int2(uv.x * uniforms->inSize.x, uv.y * uniforms->inSize.y);
                float4 bgra = read_image4f_bilinear(inPixels, pos, inSize, inStride[0]);
                float4 rgba = make_float4(bgra.z, bgra.y, bgra.x, bgra.w);
                float alpha = rgba.w * uniforms->opacity;
                float4 yuv = vecmat4(make_float4(rgba.x * alpha, rgba.y * alpha, rgba.z * alpha, 1.0), RGB2YUV);
                result.x = blend(result.x, yuv.x, alpha);
                result.y = blend(result.y, yuv.y, alpha);
                result.z = blend(result.z, yuv.z, alpha);
            }
            write_imagef(outLuma, gid, result.x, outStride);
            if(handleChroma) {
                write_imagef(outChromaU, div(gid, 2), result.y, outStride/2);
                write_imagef(outChromaV, div(gid, 2), result.z, outStride/2);
            }
        }
    }
    """
  case img_y420p_y420p =
    """
    PRELUDE void img_y420p_y420p(unsigned char* outLuma,
                                 unsigned char* outChromaU,
                                 unsigned char* outChromaV,
                                 const unsigned char* inLuma,
                                 const unsigned char* inChromaU,
                                 const unsigned char* inChromaV,
                                 const ImageUniforms* uniforms,
                                 const int* inStride) {
        DECLARE_RGB2YUV;
        const int outStride = gridDim.x*blockDim.x;
        int2 gid = make_int2(blockIdx.x * blockDim.x + threadIdx.x, blockIdx.y * blockDim.y + threadIdx.y);
        float2 size = make_float2(gridDim.x*blockDim.x, gridDim.y*blockDim.y);
        const float2 out_uv = make_float2((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = make_float4(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f && border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float curY = read_imagef(outLuma, gid, outStride);
            float curU = 0.f;
            float curV = 0.f;
            if(handleChroma) {
                curU = read_imagef(outChromaU, div(gid, 2), outStride/2);
                curV = read_imagef(outChromaV, div(gid, 2), outStride/2);
            }
            float alpha = uniforms->opacity * uniforms->fillColor.w;
            float4 fillColor = vecmat4(make_float4(uniforms->fillColor.x * alpha, uniforms->fillColor.y * alpha, uniforms->fillColor.z * alpha, 1.0), RGB2YUV);
            float3 result;
            result.x = blend(curY, fillColor.x, alpha);
            result.y = clamp(blend(curU, fillColor.y, alpha), -1.f, 1.f);
            result.z = clamp(blend(curV, fillColor.z, alpha), -1.f, 1.f);
            alpha = uniforms->opacity;
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0 &&
               uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                const int2 inSize = make_int2(uniforms->inSize.x, uniforms->inSize.y);
                const int2 pos = make_int2(uv.x * uniforms->inSize.x, uv.y * uniforms->inSize.y);
                float luma = read_imagef_bilinear(inLuma, pos, inSize, inStride[0]);
                result.x = blend(result.x, luma, alpha);
                if(handleChroma) {
                    float cb = read_imagef_bilinear(inChromaU, div(pos, 2), div(inSize, 2), inStride[1]);
                    float cr = read_imagef_bilinear(inChromaV, div(pos, 2), div(inSize, 2), inStride[2]);
                    result.y = blend(result.y, cb, alpha);
                    result.z = blend(result.z, cr, alpha);
                }
            }
            write_imagef(outLuma, gid, result.x, outStride);
            if(handleChroma) {
                write_imagef(outChromaU, div(gid, 2), result.y, outStride/2);
                write_imagef(outChromaV, div(gid, 2), result.z, outStride/2);
            }
        }
    }
    """
}

#endif
