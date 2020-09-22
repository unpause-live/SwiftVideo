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

#pragma once

#if !defined(__APPLE__) && defined(GPGPU_OCL)
#include <CL/cl.h>
#endif

#include <stdlib.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
   VP9ColorSpace_Unknown = 0,
   VP9ColorSpace_BT_601 = 1,
   VP9ColorSpace_BT_709 = 2,
   VP9ColorSpace_SMPTE_170 = 3,
   VP9ColorSpace_SMPTE_240 = 4,
   VP9ColorSpace_BT_2020 = 5,
   VP9ColorSpace_Reserved = 6,
   VP9ColorSpace_SRGB = 7
} VP9ColorSpace;

typedef struct {
   int width;
   int height;
   int displayWidth;
   int displayHeight;
   int bitDepth;
   VP9ColorSpace colorSpace;
   int subSamplingX;
   int subSamplingY;
   int fullSwingColor;
   int profile;
} VP9FrameProperties;

int aac_parse_asc(const void* data, int64_t size, int* channels, int* sample_rate, int* samples_per_frame);
int h264_sps_frame_size(const void* data, int64_t size, int* width, int* height);
int vp9_is_keyframe(const void* data, int64_t size, int* is_keyframe);
int vp9_frame_properties(const void* data, int64_t size, VP9FrameProperties* props);

#if defined(linux)
void generateRandomBytes(void* buf, size_t size);
#endif

uint64_t test_golomb_dec();

#ifdef __cplusplus
}
#endif
