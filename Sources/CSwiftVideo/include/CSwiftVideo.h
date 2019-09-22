#pragma once

#ifndef __APPLE__
#include <CL/cl.h>
#endif

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int aac_parse_asc(const void* data, int64_t size, int* channels, int* sample_rate);
int h264_sps_frame_size(const void* data, int64_t size, int* width, int* height);
void generateRandomBytes(void* buf, size_t size);

uint64_t test_golomb_dec();

#ifdef __cplusplus
}
#endif
