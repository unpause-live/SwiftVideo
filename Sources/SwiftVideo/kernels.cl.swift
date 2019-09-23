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
import Foundation

let kOpenCLKernelMatrixFuncs = 
"""
#define vecmat4(__vec__, __mat__) ((float4)(dot(__vec__, __mat__[0]), dot(__vec__, __mat__[1]), dot(__vec__, __mat__[2]), dot(__vec__, __mat__[3])))

inline void transpose(float4 out[4], const float4 in[4]) {
    out[0] = (float4)(in[0].x, in[1].x, in[2].x, in[3].x);
    out[1] = (float4)(in[0].y, in[1].y, in[2].y, in[3].y);
    out[2] = (float4)(in[0].z, in[1].z, in[2].z, in[3].z);
    out[3] = (float4)(in[0].w, in[1].w, in[2].w, in[3].w);
}
inline void multmat4(float4 out[4], const float4 lhs[4], const float4 rhs[4]) {
    float4 tmp[4];
    transpose(tmp, lhs);
    out[0] = dot(tmp[0], rhs[0]);
    out[1] = dot(tmp[1], rhs[1]);
    out[2] = dot(tmp[2], rhs[2]);
    out[3] = dot(tmp[3], rhs[3]);
}
"""

enum OpenCLKernel : String, CaseIterable {
    case img_clear_nv12 =
    """
    __kernel void img_clear_nv12(__write_only image2d_t out1,
                            __write_only image2d_t out2) {
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        write_imagef(out1, gid, (float4)(0.0, 0.0, 0.0, 1.0));
        write_imagef(out2, gid/2, (float4)(0.5, 0.5, 0.5, 1.0));
    }
    """
    case img_nv12_nv12 =
    """
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
    
    __constant sampler_t sampler = CLK_NORMALIZED_COORDS_TRUE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_LINEAR;
    __constant sampler_t curSampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;
    __kernel void img_nv12_nv12(__write_only image2d_t  outLuma,
                                __write_only image2d_t  outChroma,
                                __read_only  image2d_t  curLuma,
                                __read_only  image2d_t  curChroma,
                                __read_only  image2d_t  inLuma,
                                __read_only  image2d_t  inChroma,
                                __constant ImageUniforms* uniforms) {
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        const float2 out_uv = (float2)((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = (float4)(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f &&  border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float4 curY = read_imagef(curLuma, curSampler, gid);
            float4 curUV;
            if(handleChroma) {
                curUV = read_imagef(curChroma, curSampler, gid/2);
            }
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0) {
                if(uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                    float4 luma = read_imagef(inLuma, sampler, (float2)(uv.x, uv.y));
                    float alpha = uniforms->opacity;
                    write_imagef(outLuma, gid, (curY * (1.f - alpha) + luma * alpha));
                    if(handleChroma) {
                        float4 chroma = read_imagef(inChroma, sampler, (float2)(uv.x, uv.y));
                        write_imagef(outChroma, gid/2, (curUV * (1.f - alpha) + chroma * alpha));
                    }
                    return;
                } 
            }
            const float4 rgb2yuv[4] = { (float4)(0.299f, 0.587f, 0.113f, 0.f),
                 (float4)(-0.169f, -0.331f, 0.5f, 0.5f),
                 (float4)(0.5f, -0.419f, -0.081f, 0.5f),
                 (float4)(0.f, 0.f, 0.f, 1.f) };
            float4 fillColor = vecmat4((float4)(uniforms->fillColor.x, uniforms->fillColor.y, uniforms->fillColor.z, 1.0), rgb2yuv);
            float alpha = uniforms->opacity * uniforms->fillColor.w;
            write_imagef(outLuma, gid, clamp((curY * (1.f - alpha) + fillColor.x * alpha), 0.f, 1.f));
            if(handleChroma) {
                write_imagef(outChroma, gid/2, clamp((curUV * (1.f - alpha) + fillColor.yzyz * alpha), -1.f, 1.f));
            }
        }
        
    };
    """
    case img_y420p_nv12 = 
    """
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

    __constant sampler_t sampler = CLK_NORMALIZED_COORDS_TRUE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_LINEAR;
    __constant sampler_t curSampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;
    __kernel void img_y420p_nv12(__write_only image2d_t  outLuma,
                                __write_only image2d_t  outChroma,
                                __read_only  image2d_t  curLuma,
                                __read_only  image2d_t  curChroma,
                                __read_only  image2d_t  inLuma,
                                __read_only  image2d_t  inChromaU,
                                __read_only  image2d_t  inChromaV,
                                __constant ImageUniforms* uniforms) {
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        const float2 out_uv = (float2)((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = (float4)(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f &&  border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float4 curY = read_imagef(curLuma, curSampler, gid);
            float4 curUV;
            if(handleChroma) {
                curUV = read_imagef(curChroma, curSampler, gid/2);
            }
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0) {
                if(uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                    float4 luma = read_imagef(inLuma, sampler, (float2)(uv.x, uv.y));
                    float alpha = uniforms->opacity;
                    write_imagef(outLuma, gid, (curY * (1.f - alpha) + luma * alpha));
                    if(handleChroma) {
                        float4 cb = read_imagef(inChromaU, sampler, (float2)(uv.x, uv.y));
                        float4 cr = read_imagef(inChromaV, sampler, (float2)(uv.x, uv.y));
                        write_imagef(outChroma, gid/2, (curUV * (1.f - alpha) + (float4)(cb.x, cr.x, cb.x, cr.x) * alpha));
                    }
                    return;
                } 
            }
            const float4 rgb2yuv[4] = { (float4)(0.299f, 0.587f, 0.113f, 0.f),
                 (float4)(-0.169f, -0.331f, 0.5f, 0.5f),
                 (float4)(0.5f, -0.419f, -0.081f, 0.5f),
                 (float4)(0.f, 0.f, 0.f, 1.f) };
            float4 fillColor = vecmat4((float4)(uniforms->fillColor.x, uniforms->fillColor.y, uniforms->fillColor.z, 1.0), rgb2yuv);
            float alpha = uniforms->opacity * uniforms->fillColor.w;
            write_imagef(outLuma, gid, clamp((curY * (1.f - alpha) + fillColor.x * alpha), 0.f, 1.f));
            if(handleChroma) {
                write_imagef(outChroma, gid/2, clamp((curUV * (1.f - alpha) + fillColor.yzyz * alpha), -1.f, 1.f));
            }
        }
    };
    """
    case img_clear_y420p =
    """
    __kernel void img_clear_y420p(__read_write image2d_t out1,
                            __read_write image2d_t out2,
                            __read_write image2d_t out3) {
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        write_imagef(out1, gid, 0.0);
        write_imagef(out2, gid/2, 0.5);
        write_imagef(out3, gid/2, 0.5);
    }
    """
    case img_y420p_y420p = 
    """
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

    __constant sampler_t sampler = CLK_NORMALIZED_COORDS_TRUE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_LINEAR;
    __constant sampler_t curSampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;
    __kernel void img_y420p_y420p(__write_only image2d_t  outLuma,
                                __write_only image2d_t  outChromaU,
                                __write_only image2d_t  outChromaV,
                                __read_only image2d_t   curLuma,
                                __read_only image2d_t   curChromaU,
                                __read_only image2d_t   curChromaV,
                                __read_only  image2d_t  inLuma,
                                __read_only  image2d_t  inChromaU,
                                __read_only  image2d_t  inChromaV,
                                __constant ImageUniforms* uniforms) {
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        const float2 out_uv = (float2)((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = (float4)(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f &&  border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float4 curY = read_imagef(curLuma, curSampler, gid);
            float4 curU;
            float4 curV;
            if(handleChroma) {
                curU = read_imagef(curChromaU, curSampler, gid/2);
                curV = read_imagef(curChromaV, curSampler, gid/2);
            }
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0) {
                if(uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                    float4 luma = read_imagef(inLuma, sampler, (float2)(uv.x, uv.y));
                    float alpha = uniforms->opacity;
                    write_imagef(outLuma, gid, (curY * (1.f - alpha) + luma * alpha));
                    if(handleChroma) {
                        float4 cb = read_imagef(inChromaU, sampler, (float2)(uv.x, uv.y));
                        float4 cr = read_imagef(inChromaV, sampler, (float2)(uv.x, uv.y));
                        write_imagef(outChromaU, gid/2, (curU * (1.f - alpha) + cb * alpha));
                        write_imagef(outChromaV, gid/2, (curV * (1.f - alpha) + cr * alpha));
                    }
                    return;
                } 
            }
            const float4 rgb2yuv[4] = { (float4)(0.299f, 0.587f, 0.113f, 0.f),
                 (float4)(-0.169f, -0.331f, 0.5f, 0.5f),
                 (float4)(0.5f, -0.419f, -0.081f, 0.5f),
                 (float4)(0.f, 0.f, 0.f, 1.f) };
            float4 fillColor = vecmat4((float4)(uniforms->fillColor.x, uniforms->fillColor.y, uniforms->fillColor.z, 1.0), rgb2yuv);
            float alpha = uniforms->opacity * uniforms->fillColor.w;
            write_imagef(outLuma, gid, clamp((curY * (1.f - alpha) + fillColor.x * alpha), 0.f, 1.f));
            if(handleChroma) {
                write_imagef(outChromaU, gid/2, clamp((curU * (1.f - alpha) + fillColor.y * alpha), -1.f, 1.f));
                write_imagef(outChromaV, gid/2, clamp((curV * (1.f - alpha) + fillColor.z * alpha), -1.f, 1.f));
            }
        }
    };
    """

    case img_clear_bgra = 
    """
    __kernel void img_clear_bgra(__read_write image2d_t out1) {
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        write_imagef(out1, gid, (float4)(0.0, 0.0, 0.0, 1.0));
    }

    """

    case img_bgra_y420p =
    """
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

    __constant sampler_t sampler = CLK_NORMALIZED_COORDS_TRUE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_LINEAR;
    __constant sampler_t curSampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;
    __kernel void img_bgra_y420p(__write_only image2d_t  outLuma,
                                __write_only image2d_t  outChromaU,
                                __write_only image2d_t  outChromaV,
                                __read_only image2d_t   curLuma,
                                __read_only image2d_t   curChromaU,
                                __read_only image2d_t   curChromaV,
                                __read_only  image2d_t  inPixels,
                                __constant ImageUniforms* uniforms) {
        const float4 rgb2yuv[4] = { (float4)(0.299f, 0.587f, 0.113f, 0.f),
             (float4)(-0.169f, -0.331f, 0.5f, 0.5f),
             (float4)(0.5f, -0.419f, -0.081f, 0.5f),
             (float4)(0.f, 0.f, 0.f, 1.f) };
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        const float2 out_uv = (float2)((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = (float4)(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f &&  border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float4 curY = read_imagef(curLuma, curSampler, gid);
            float4 curU;
            float4 curV;
            if(handleChroma) {
                curU = read_imagef(curChromaU, curSampler, gid/2);
                curV = read_imagef(curChromaV, curSampler, gid/2);
            }
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0) {
                float alpha = uniforms->opacity * uniforms->fillColor.w;
                float4 fillColor = vecmat4((float4)(uniforms->fillColor.x * alpha, uniforms->fillColor.y * alpha, uniforms->fillColor.z * alpha, 1.0), rgb2yuv);
                float3 result;
                result.x = (curY.x * (1.f - alpha) + fillColor.x * alpha);
                result.y = clamp((curU.x * (1.f - alpha) + fillColor.y * alpha), -1.f, 1.f);
                result.z = clamp((curV.x * (1.f - alpha) + fillColor.z * alpha), -1.f, 1.f);
                if(uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                    float4 bgra = read_imagef(inPixels, sampler, (float2)(uv.x, uv.y));
                    float4 rgba = (float4)(bgra.z, bgra.y, bgra.x, bgra.w);
                    float alpha = rgba.w * uniforms->opacity;
                    float4 yuv = vecmat4((float4)(rgba.x * alpha, rgba.y * alpha, rgba.z * alpha, 1.0), rgb2yuv);
                    result.x = result.x * (1.f - alpha) + yuv.x * alpha;
                    result.y = result.y * (1.f - alpha) + yuv.y * alpha;
                    result.z = result.z * (1.f - alpha) + yuv.z * alpha;
                } 
                write_imagef(outLuma, gid, result.x);
                if(handleChroma) {
                    write_imagef(outChromaU, gid/2, result.y);
                    write_imagef(outChromaV, gid/2, result.z);
                }
            }
        }
    };
    """
    case img_rgba_y420p =
    """
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

    __constant sampler_t sampler = CLK_NORMALIZED_COORDS_TRUE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_LINEAR;
    __constant sampler_t curSampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;
    __kernel void img_rgba_y420p(__write_only image2d_t  outLuma,
                                __write_only image2d_t  outChromaU,
                                __write_only image2d_t  outChromaV,
                                __read_only image2d_t   curLuma,
                                __read_only image2d_t   curChromaU,
                                __read_only image2d_t   curChromaV,
                                __read_only  image2d_t  inPixels,
                                __constant ImageUniforms* uniforms) {
        const float4 rgb2yuv[4] = { (float4)(0.299f, 0.587f, 0.113f, 0.f),
             (float4)(-0.169f, -0.331f, 0.5f, 0.5f),
             (float4)(0.5f, -0.419f, -0.081f, 0.5f),
             (float4)(0.f, 0.f, 0.f, 1.f) };
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        const float2 out_uv = (float2)((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = (float4)(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f &&  border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float4 curY = read_imagef(curLuma, curSampler, gid);
            float4 curU;
            float4 curV;
            if(handleChroma) {
                curU = read_imagef(curChromaU, curSampler, gid/2);
                curV = read_imagef(curChromaV, curSampler, gid/2);
            }
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0) {
                float alpha = uniforms->opacity * uniforms->fillColor.w;
                float4 fillColor = vecmat4((float4)(uniforms->fillColor.x * alpha, uniforms->fillColor.y * alpha, uniforms->fillColor.z * alpha, 1.0), rgb2yuv);
                float3 result;
                result.x = (curY.x * (1.f - alpha) + fillColor.x * alpha);
                result.y = clamp((curU.x * (1.f - alpha) + fillColor.y * alpha), -1.f, 1.f);
                result.z = clamp((curV.x * (1.f - alpha) + fillColor.z * alpha), -1.f, 1.f);
                if(uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                    float4 rgba = read_imagef(inPixels, sampler, (float2)(uv.x, uv.y));
                    float alpha = rgba.w * uniforms->opacity;
                    float4 yuv = vecmat4((float4)(rgba.x * alpha, rgba.y * alpha, rgba.z * alpha, 1.0), rgb2yuv);
                    result.x = result.x * (1.f - alpha) + yuv.x * alpha;
                    result.y = result.y * (1.f - alpha) + yuv.y * alpha;
                    result.z = result.z * (1.f - alpha) + yuv.z * alpha;
                } 
                write_imagef(outLuma, gid, result.x);
                if(handleChroma) {
                    write_imagef(outChromaU, gid/2, result.y);
                    write_imagef(outChromaV, gid/2, result.z);
                }
            }
        }
    };
    """

    case img_rgba_nv12 =
    """
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

    __constant sampler_t sampler = CLK_NORMALIZED_COORDS_TRUE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_LINEAR;
    __constant sampler_t curSampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;
    __kernel void img_rgba_nv12(__write_only image2d_t  outLuma,
                                __write_only image2d_t  outChroma,
                                __read_only  image2d_t  curLuma,
                                __read_only  image2d_t  curChroma,
                                __read_only  image2d_t  inPixels,
                                __constant ImageUniforms* uniforms) {
        const float4 rgb2yuv[4] = { (float4)(0.299f, 0.587f, 0.113f, 0.f),
             (float4)(-0.169f, -0.331f, 0.5f, 0.5f),
             (float4)(0.5f, -0.419f, -0.081f, 0.5f),
             (float4)(0.f, 0.f, 0.f, 1.f) };
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        const float2 out_uv = (float2)((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = (float4)(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f &&  border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float4 curY = read_imagef(curLuma, curSampler, gid);
            float4 curUV;
            if(handleChroma) {
                curUV = read_imagef(curChroma, curSampler, gid/2);
            }
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0) {
                float alpha = uniforms->opacity * uniforms->fillColor.w;
                float4 fillColor = vecmat4((float4)(uniforms->fillColor.x * alpha, uniforms->fillColor.y * alpha, uniforms->fillColor.z * alpha, 1.0), rgb2yuv);
                float3 result;
                result.x = (curY.x * (1.f - alpha) + fillColor.x * alpha);
                result.y = clamp((curUV.x * (1.f - alpha) + fillColor.y * alpha), -1.f, 1.f);
                result.z = clamp((curUV.y * (1.f - alpha) + fillColor.z * alpha), -1.f, 1.f);
                if(uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                    float4 rgba = read_imagef(inPixels, sampler, (float2)(uv.x, uv.y));
                    float alpha = rgba.w * uniforms->opacity;
                    float4 yuv = vecmat4((float4)(rgba.x * alpha, rgba.y * alpha, rgba.z * alpha, 1.0), rgb2yuv);
                    result.x = result.x * (1.f - alpha) + yuv.x * alpha;
                    result.y = result.y * (1.f - alpha) + yuv.y * alpha;
                    result.z = result.z * (1.f - alpha) + yuv.z * alpha;
                } 
                write_imagef(outLuma, gid, result.x);
                if(handleChroma) {
                    write_imagef(outChroma, gid/2, result.yzyz);
                }
            }
        }
    };
    """

    case img_bgra_nv12 =
    """
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

    __constant sampler_t sampler = CLK_NORMALIZED_COORDS_TRUE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_LINEAR;
    __constant sampler_t curSampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;
    __kernel void img_bgra_nv12(__write_only image2d_t  outLuma,
                                __write_only image2d_t  outChroma,
                                __read_only  image2d_t  curLuma,
                                __read_only  image2d_t  curChroma,
                                __read_only  image2d_t  inPixels,
                                __constant ImageUniforms* uniforms) {
        const float4 rgb2yuv[4] = { (float4)(0.299f, 0.587f, 0.113f, 0.f),
             (float4)(-0.169f, -0.331f, 0.5f, 0.5f),
             (float4)(0.5f, -0.419f, -0.081f, 0.5f),
             (float4)(0.f, 0.f, 0.f, 1.f) };
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        float2 size = (float2)(get_global_size(0), get_global_size(1));
        const float2 out_uv = (float2)((float)gid.x / size.x, (float)gid.y / size.y);
        float4 normpos = (float4)(out_uv.x * 2.f - 1.f, out_uv.y * 2.f - 1.f, 0.f, 1.f);
        float4 tx = vecmat4(normpos, uniforms->transform);
        float4 border = vecmat4(normpos, uniforms->borderMatrix);
        bool handleChroma = (gid.x % 2) == 0 && (gid.y % 2) == 0;
        if(border.x >= 0.f && border.y >= 0.f && border.x <= 1.f &&  border.y <= 1.f) {
            float4 uv = vecmat4(tx, uniforms->textureTx);
            float4 curY = read_imagef(curLuma, curSampler, gid);
            float4 curUV;
            if(handleChroma) {
                curUV = read_imagef(curChroma, curSampler, gid/2);
            }
            if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0) {
                float alpha = uniforms->opacity * uniforms->fillColor.w;
                float4 fillColor = vecmat4((float4)(uniforms->fillColor.x * alpha, uniforms->fillColor.y * alpha, uniforms->fillColor.z * alpha, 1.0), rgb2yuv);
                float3 result;
                result.x = (curY.x * (1.f - alpha) + fillColor.x * alpha);
                result.y = clamp((curUV.x * (1.f - alpha) + fillColor.y * alpha), -1.f, 1.f);
                result.z = clamp((curUV.y * (1.f - alpha) + fillColor.z * alpha), -1.f, 1.f);
                if(uv.x >= 0.f && uv.y >= 0.f && uv.x <= 1.f && uv.y <= 1.f) {
                    float4 bgra = read_imagef(inPixels, sampler, (float2)(uv.x, uv.y));
                    float4 rgba = (float4)(bgra.z, bgra.y, bgra.x, bgra.w);
                    float alpha = rgba.w * uniforms->opacity;
                    float4 yuv = vecmat4((float4)(rgba.x * alpha, rgba.y * alpha, rgba.z * alpha, 1.0), rgb2yuv);
                    result.x = result.x * (1.f - alpha) + yuv.x * alpha;
                    result.y = result.y * (1.f - alpha) + yuv.y * alpha;
                    result.z = result.z * (1.f - alpha) + yuv.z * alpha;
                } 
                write_imagef(outLuma, gid, result.x);
                if(handleChroma) {
                    write_imagef(outChroma, gid/2, result.yzyz);
                }
            }
        }
    };
    """

    case snd_s16i_s16i = 
    """
    typedef struct {
        int inputCount;
        int inputOffsets[8];
        float inputGains[8];
        float inputFade[8];
    } BufferUniforms;

    __kernel void snd_s16i_s16i(__global short* outBuffer,
                                __constant BufferUniforms* uniforms,
                                __global short* in0,
                                __global short* in1,
                                __global short* in2,
                                __global short* in3,
                                __global short* in4,
                                __global short* in5,
                                __global short* in6,
                                __global short* in7) {
        __global short* inputs[8] = { in0, in1, in2, in3, in4, in5, in6, in7 };
        int gid = get_global_id(0);
        int channel = gid % 2;
        for(int i = 0 ; i < uniforms->inputCount ; i++) {
            float value = min((float)inputs[i][gid] * uniforms->inputGains[i] * (channel == 0 ? 1.f - uniforms->inputFade[i] : uniforms->inputFade[i]), 32767.f);
            outBuffer[gid] += (short)value;
        }
    }

    """
}

#endif
