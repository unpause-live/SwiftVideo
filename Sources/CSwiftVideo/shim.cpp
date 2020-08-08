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

#include <CSwiftVideo.h>
#include <optional>
#include <set>
#include <assert.h>
#include <inttypes.h>

#if defined(linux)
#include <bsd/stdlib.h>
#else
#include <stdlib.h>
#endif

static uint8_t clzlut[256] = {
  8,7,6,6,5,5,5,5,
  4,4,4,4,4,4,4,4,
  3,3,3,3,3,3,3,3,
  3,3,3,3,3,3,3,3,
  2,2,2,2,2,2,2,2,
  2,2,2,2,2,2,2,2,
  2,2,2,2,2,2,2,2,
  2,2,2,2,2,2,2,2,
  1,1,1,1,1,1,1,1,
  1,1,1,1,1,1,1,1,
  1,1,1,1,1,1,1,1,
  1,1,1,1,1,1,1,1,
  1,1,1,1,1,1,1,1,
  1,1,1,1,1,1,1,1,
  1,1,1,1,1,1,1,1,
  1,1,1,1,1,1,1,1,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0
};


class ExpGolomb {
public:
    ExpGolomb(uint8_t* data, int64_t size) 
    : pos(0), size(size), base(data), ptr(data) {}

    uint64_t u_decode() {
        const auto bits = zeroes()+1;
        // update state
        pos += bits-1;
        auto prev = ptr;
        ptr = (uint8_t*)(base + (pos / 8));
        auto result = get_bits(bits);

        if(result && *result > 0) {
            return *result - 1;
        } else {
            return 0;
        }
    }

    int64_t decode() {
        const uint64_t uresult = u_decode();
        const int64_t odd = int64_t(uresult%2);
        return uresult / 2 * (odd ? 1 : -1) + odd;
    }

    std::optional<uint64_t> get_bits(int64_t count) {
        const int64_t remaining = size*8 - pos;
        if(remaining <= 0 || count > 64 || count <= 0) { // cannot represent more than 64 bits
            return {};
        }
        auto offset = pos % 8;
        auto bits = std::min(count, remaining);
        uint64_t accumulator {0};
        uint8_t* p = ptr;
        while(bits > 0) {
            const uint8_t maskhigh = uint8_t(0xff >> offset);
            const uint8_t masklow = uint8_t((0xff << std::min(8LL, std::max(0LL, 8LL-bits-offset)))  & 0xff);
            const uint8_t mask = maskhigh & masklow;
            const auto bitsToCopy = std::min(8-offset, bits);
            const auto result = uint64_t(*p & mask) << (bits - bitsToCopy);
            accumulator |= (result >> (8L - bitsToCopy - offset));
            bits -= bitsToCopy;
            p++;
            offset = 0;
        }
        // update state
        pos += count;
        ptr = (uint8_t*)(base + (pos / 8));
        return accumulator;
    }

    int64_t alignment() const {
        return pos % 8;
    }

private:
    int64_t zeroes() {
        uint8_t* p = ptr;
        const uint8_t* end = base+size;
        auto offset = pos % 8;
        int64_t count = 0;
        int i = 0;
        while(p < end) {
            const uint8_t mask = (0xff << offset) >> offset;
            uint8_t test = *p & mask;
            if(offset == 0) { // offset is 0, just use the lookup table to find the number of leading zeroes for this byte
                count += clzlut[test];
                break;
            } else if(offset > 0) { // have to count zeroes since offset > 0
                bool done = false;
                for(auto i = offset; i < 8 && !done; i++) {
                    auto bit = ((1 << (7-i)) & test);
                    done |= bit > 0;
                    count += done == false ? 1 : 0;
                }
                if(done) {
                    break;
                }
            } 
            p++;
            offset = 0;
        }
        return count;
    }

private:
    int64_t pos; // in bits
    const int64_t size;
    const uint8_t* base;
    uint8_t* ptr; // to closes byte
};

extern "C" {
#if defined(linux)
    void generateRandomBytes(void* buf, size_t size) {
        arc4random_buf(buf, size);
    }
#endif
    int aac_parse_asc(const void* data, int64_t size, int* channels, int* sample_rate, int* samples_per_frame) {
        if(!(data != nullptr && size >= 2)) {
            return 0;
        }
        const int sr[13] = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };
        const uint8_t* ptr = (const uint8_t*)data;
        const int sr_idx = ((ptr[0] & 0x7) << 1) | ((ptr[1] >> 7) & 0x1);
        int cct = (ptr[1] >> 3) & 0x3;
        int fl = (ptr[1] >> 2) & 0x1;
        
        if(sr_idx < 13 && sample_rate != nullptr) {
            *sample_rate = sr[sr_idx];
        } else if(sr_idx == 15 && sample_rate != nullptr && size > 4) {
            *sample_rate = (int(ptr[1] & 0xF) << 17) | (int(ptr[2]) << 9) | (int(ptr[3]) << 1) | int(ptr[4] & 0x80) >> 7;
            cct = (ptr[4] & 0x78) >> 3;
        }

        if(channels != nullptr) {
            *channels = cct;
        }
        
        if(samples_per_frame != nullptr) {
            *samples_per_frame = (fl > 0 ? 960 : 1024);
        }
        
        return 1;
    }    

    int h264_sps_frame_size(const void* data, int64_t size, int* width, int* height)  {
        // TREC H.264 2011/06 7.3.2.1.1
        if(data == nullptr || size <= 0 || width == nullptr || height == nullptr) {
            return 0;
        }
        auto decoder = ExpGolomb((uint8_t*)data, size);
        decoder.get_bits(8); // nal header
        auto profile_idc = decoder.get_bits(8);
        decoder.get_bits(16); // constraints, level_idc
        decoder.u_decode(); // seq_parameter_set_id
        const std::set<uint64_t> need_scaling = { 44, 83, 86, 100, 110, 118, 122, 128, 244 };

        if(profile_idc && need_scaling.find(*profile_idc) != need_scaling.end())  {
            auto scaling_list = [&decoder](int64_t size) {
                int64_t l_scale{8}, n_scale{8};
                for(int64_t i = 0; i < size; i++ ) {
                    if( n_scale != 0 ) {
                        auto delta_scale = decoder.decode();
                        n_scale = ( l_scale + l_scale + 256 ) % 256;
                        
                    }               
                    l_scale =  (n_scale == 0) ? l_scale : n_scale;
                }
            };
            auto chroma_format_idc = decoder.u_decode();
            if(chroma_format_idc == 3) {
                decoder.get_bits(1); // separate_colour_plane_flag
            }
            decoder.u_decode(); // bit_depth_luma_minus8
            decoder.u_decode(); // bit_depth_chroma_minus8
            decoder.get_bits(1); // qpprime_y_zero_transform_bypass_flag
            auto seq_scaling_matrix_present_flag = decoder.get_bits(1);
            if(seq_scaling_matrix_present_flag && *seq_scaling_matrix_present_flag == 1) {
                const auto count = chroma_format_idc == 3 ? 12 : 8;
                for(int64_t i = 0; i < count; i++) {
                    auto seq_scaling_list_present_flag_i = decoder.get_bits(1);
                    if(seq_scaling_list_present_flag_i == 1) {
                        const int64_t list_size = i <= 5 ? 16 : 32;
                        scaling_list(list_size);
                    }
                }
            }
        }
        decoder.u_decode(); // log2_max_frame_num_minus4
        auto pic_order_cnt_type = decoder.u_decode(); 
        if(pic_order_cnt_type == 0) {
            decoder.u_decode(); // log2_max_pic_order_cnt_lsb_minus4
        } else if (pic_order_cnt_type == 1) {
            decoder.get_bits(1); // delta_pic_order_always_zero_flag
            decoder.decode(); // offset_for_non_ref_pic
            decoder.decode(); // offset_for_top_to_bottom_field
            auto num_ref_frames_in_pic_order_cnt_cycle = decoder.u_decode();
            for(int64_t i = 0; i < num_ref_frames_in_pic_order_cnt_cycle; i++) {
                decoder.decode(); // offset_for_ref_frame
            }
        }
        decoder.u_decode(); // num_ref_frames
        decoder.get_bits(1); // gaps_in_frame_num_value_allowed_flag
        auto pic_width_in_mbs_minus1 = decoder.u_decode();
        auto pic_height_in_map_units_minus1 =  decoder.u_decode();
        auto frame_mbs_only_flag = decoder.get_bits(1);
        if(frame_mbs_only_flag && *frame_mbs_only_flag == 0) {
            decoder.get_bits(1); // mb_adaptive_frame_field_flag
        }
        decoder.get_bits(1); // direct_8x8_inference_flag
        auto frame_cropping_flag = decoder.get_bits(1);

        int64_t frame_crop_left_offset  = 0;
        int64_t frame_crop_right_offset = 0;
        int64_t frame_crop_top_offset = 0;
        int64_t frame_crop_bottom_offset = 0;
        if(frame_cropping_flag && *frame_cropping_flag == 1) {
            frame_crop_left_offset = decoder.u_decode();
            frame_crop_right_offset = decoder.u_decode();
            frame_crop_top_offset = decoder.u_decode();
            frame_crop_bottom_offset = decoder.u_decode();
        } 
        if(width != nullptr) {
            *width = int( ((pic_width_in_mbs_minus1 + 1) * 16) - (frame_crop_left_offset*2 + frame_crop_right_offset*2) );
        }
        if(height != nullptr) {
            *height = int((2 - (frame_mbs_only_flag && *frame_mbs_only_flag)) * ((pic_height_in_map_units_minus1 + 1) * 16) - (frame_crop_top_offset*2 + frame_crop_bottom_offset*2) );
        }
        return 1;
    }

    static int vp9_bitdepth_colorspace_sampling(ExpGolomb& decoder, VP9FrameProperties* props) {
        props->bitDepth = 8;
        if(props->profile >= 2) {
            props->bitDepth = *decoder.get_bits(1) ? 12 : 10;
        }
        props->colorSpace = static_cast<VP9ColorSpace>(*decoder.get_bits(3));
        if(props->colorSpace != VP9ColorSpace_SRGB) {
            props->fullSwingColor = *decoder.get_bits(1); // movie = 0, full = 1
            if(props->profile == 1 || props->profile == 3) {
                props->subSamplingX = *decoder.get_bits(1);
                props->subSamplingY = *decoder.get_bits(1);
                decoder.get_bits(1); // reserved 0
            } else {
                props->subSamplingX = props->subSamplingY = 1;
            }
        } else {
            props->subSamplingX = props->subSamplingY = 0;
            decoder.get_bits(1); // reserved 0
            if(props->profile != 1 && props->profile != 3) {
                return 0;
            }
        }
        return 1;
    }
    static int vp9_frame_size(ExpGolomb& decoder, VP9FrameProperties* props) {
        props->width = *decoder.get_bits(16) + 1;
        props->height = *decoder.get_bits(16) + 1;
        auto has_scaling = decoder.get_bits(1);
        if(has_scaling && *has_scaling) {
            props->displayWidth = *decoder.get_bits(16) + 1;
            props->displayHeight = *decoder.get_bits(16) + 1;
        } else {
            props->displayWidth = props->width;
            props->displayHeight = props->height;
        }
        return 1;
    }
    int vp9_is_keyframe(const void* data, int64_t size, int* is_keyframe) {
        auto decoder = ExpGolomb((uint8_t*)data, size);
        if(*decoder.get_bits(2) != 0b10) {
            return 0;
        }
        auto version = *decoder.get_bits(1);
        auto high = *decoder.get_bits(1);
        auto profile = (high << 1) + version;
        if(profile == 3) {
            decoder.get_bits(1); // reserved
        }
        if(*decoder.get_bits(1)) { // show_existing_frame - not a new frame
            return 0;
        }
        *is_keyframe = !(*decoder.get_bits(1));
        return 1;
    }

    int vp9_frame_properties(const void* data, int64_t size, VP9FrameProperties* props) {
        auto decoder = ExpGolomb((uint8_t*)data, size);
        if(*decoder.get_bits(2) != 0b10) {
            return 0;
        }
        auto version = *decoder.get_bits(1);
        auto high = *decoder.get_bits(1);
        props->profile = (high << 1) + version;
        if(props->profile == 3) {
            decoder.get_bits(1); // reserved
        }
        if(*decoder.get_bits(1)) { // show_existing_frame - not a new frame
            return 0;
        }
        auto frame_type = *decoder.get_bits(1);
        if(frame_type != 0) {
            return 0;
        }
        decoder.get_bits(1); // show_frame
        decoder.get_bits(1); // error_resilient_mode
        auto sync_code = *decoder.get_bits(24);
        if(sync_code == 0x498342 && vp9_bitdepth_colorspace_sampling(decoder, props)) {
            if(decoder.alignment() > 0) {
                decoder.get_bits(8 - decoder.alignment());
            }
            vp9_frame_size(decoder, props);
            return 1;
        }
        return 0;
    }

    uint64_t test_golomb_dec() {
        uint8_t bytes[4] = {0};
        bytes[0] = 0x1;
        bytes[1] = 0xff;

        ExpGolomb dec(bytes, 2);
        auto val = dec.u_decode();
        printf("[golomb] test decode - result=%" PRId64 "\n", val);
        return val;
    }
}
