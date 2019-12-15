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
enum CUDAKernel: String, CaseIterable {
  case img_clear_nv12 =
    """
    __kernel void img_clear_nv12(__write_only image2d_t out1,
                            __write_only image2d_t out2) {
        int2 gid = (int2)(get_global_id(0), get_global_id(1));
        write_imagef(out1, gid, (float4)(0.0, 0.0, 0.0, 1.0));
        write_imagef(out2, gid/2, (float4)(0.5, 0.5, 0.5, 1.0));
    }
    """
}
#endif