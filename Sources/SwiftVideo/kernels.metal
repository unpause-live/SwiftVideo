
#include <metal_stdlib>

using namespace metal;

struct ImageUniforms {
    float4x4 transform;
    float4x4 textureTx;
    float4x4 borderMatrix;
    float4 fillColor;
    float2 inputSize;
    float2 outputSize;
    float opacity;
    float sampleTime;
    float targetTime;
};

struct MotionEstimationUniforms {
    int2 blockSize;
    int2 searchWindowSize;
    int2 imageSize;
};

// MARK: - Image Composition
//
//
kernel void img_clear_y420p(texture2d<float, access::write> outLuma [[texture(0)]],
                      texture2d<float, access::write> outChromaCb [[texture(1)]],
                      texture2d<float, access::write> outChromaCr [[texture(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
    outLuma.write(float4(0,0,0,1), gid);
    outChromaCb.write(float4(0.5,0.5,0.5,1), gid/2);
    outChromaCr.write(float4(0.5,0.5,0.5,1), gid/2);
}

#warning("TODO: apply transformations")
kernel void img_bgra_bgra(texture2d<float, access::read_write> outTexture [[texture(0)]],
                          texture2d<float, access::read> inTexture [[texture(1)]],
                          constant ImageUniforms& uniforms [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    float2 inPos = float2(gid) * (uniforms.inputSize / uniforms.outputSize);
    float4 inColor = inTexture.read(uint2(inPos));
    float4 extColor = outTexture.read(gid);
    float4 mixColor = float4(inColor.rgb * inColor.a + extColor.rgb * (1.0 - inColor.a), 1.0);
    outTexture.write(mixColor,gid);
}

kernel void img_clear_nv12(texture2d<float, access::read_write> outLuma [[texture(0)]],
                           texture2d<float, access::read_write> outChroma [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    outLuma.write(float4(0,0,0,1), gid);
    outChroma.write(float4(0.5, 0.5, 0.5, 1), gid/2);
}

kernel void img_nv12_nv12(texture2d<float, access::read_write> outLuma [[texture(0)]],
                          texture2d<float, access::read_write> outChroma [[texture(1)]],
                          texture2d<float, access::sample> inLuma [[texture(2)]],
                          texture2d<float, access::sample> inChroma [[texture(3)]],
                          constant ImageUniforms& uniforms [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    float2 normpos = (float2(gid) / uniforms.outputSize) * 2.0 - 1.0;
    float4 tx = float4(normpos, 0.0, 1.0) * uniforms.transform ;
    float4 border = float4(normpos, 0.0, 1.0) * uniforms.borderMatrix;
    if(border.x >= 0.0 && border.y >= 0.0 && border.x <= 1.0 && border.y <= 1.0) {
        float2 uv = (tx * uniforms.textureTx).xy;
        if(tx.x >= 0.0 && tx.y >= 0.0 && tx.x <= 1.0 && tx.y <= 1.0) {
            if(uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
                constexpr sampler s (address::clamp_to_edge, filter::linear);
                float luma = inLuma.sample(s, uv.xy).r;
                float4 chroma = float4(inChroma.sample(s, uv.xy).rg,0,0);
                float4 outLumaCurrent = outLuma.read(gid);
                float4 outChromaCurrent = outChroma.read(gid/2);
                outLuma.write(luma * uniforms.opacity + (1.0 - uniforms.opacity) * outLumaCurrent.r, gid);
                outChroma.write(chroma * uniforms.opacity + (1.0 - uniforms.opacity) * outChromaCurrent, gid/2);
                return;
            }
        }
        const float4x4 rgb2yuv = { { 0.299f, 0.587f, 0.113f, 0.f },
            {-0.169f, -0.331f, 0.5f, 0.5f},
            {0.5f, -0.419f, -0.081f, 0.5f},
            {0.f, 0.f, 0.f, 1.f} };
        float4 fillColor = float4(uniforms.fillColor.xyz, 1.0) * rgb2yuv;
        float4 outLumaCurrent = outLuma.read(gid);
        float4 outChromaCurrent = outChroma.read(gid/2);
        float alpha = uniforms.opacity * uniforms.fillColor.w;
        outLuma.write(saturate(fillColor.r * alpha + (1.0 - alpha) * outLumaCurrent.r), gid);
        outChroma.write(clamp(float4(fillColor.gb * alpha + (1.0 - alpha) * outChromaCurrent.rg, 0, 0), -1, 1), gid/2);
    }
}

kernel void img_y420p_y420p(texture2d<float, access::read_write> outLuma [[texture(0)]],
                          texture2d<float, access::read_write> outChromaCb [[texture(1)]],
                          texture2d<float, access::read_write> outChromaCr [[texture(2)]],
                          texture2d<float, access::sample> inLuma [[texture(3)]],
                          texture2d<float, access::sample> inChromaCb [[texture(4)]],
                          texture2d<float, access::sample> inChromaCr [[texture(5)]],
                          constant ImageUniforms& uniforms [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    float2 normpos = (float2(gid) / uniforms.outputSize);
    float4 tpos = float4(normpos * 2.0 - 1.0, 1.0, 1.0) * uniforms.transform ;
    float2 uv = tpos.xy / tpos.z * 0.5 + 0.5;
    if(uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
        constexpr sampler s (address::clamp_to_edge, filter::linear);
        float luma = inLuma.sample(s, uv.xy).r;
        float4 chromaCb = float4(inChromaCb.sample(s, uv.xy).rg,0,0);
        float4 chromaCr = float4(inChromaCr.sample(s, uv.xy).rg,0,0);
        outLuma.write(luma, gid);
        outChromaCb.write(chromaCb, gid/2);
        outChromaCr.write(chromaCr, gid/2);
    }
}

// MARK: - Motion Estimation
// Motion Estimation
//

struct SadReturn {
    float leftSide;
    float sad;
};

inline float deltaCost2(float2 motionVector) {
    const float lambda = 4.0;
    const float qpex = 4.0;
    float2 mvcLog2 = log2(float2(abs(motionVector) + 1));
    float2 rounding = float2(!!motionVector.x, !!motionVector.y);
    float2 mvc = lambda * (mvcLog2 * 2.0 + 0.718 + rounding) + 0.5;
    return qpex * (mvc.x + mvc.y);
}

inline SadReturn sumAbsoluteDifferences(const int4 block1,
                                        const int4 block2,
                                        texture2d<float, access::read> tex1,
                                        texture2d<float, access::read> tex2,
                                        float previousSide,
                                        float previousSad) {
    int2 pos1 = block1.xy;
    int2 pos2 = block2.xy;
    float sum = 0;
    float topSide = 0;
    if(previousSide > 0) {
        // in this case we need to sample the top and bottom rows
        float bottomSide = 0;
        for(;pos1.x < block1.z && pos2.x < block2.z; pos1.x++, pos2.x++) {
            float a_top = tex1.read(uint2(pos1.x, block1.y)).r;
            float b_top = tex2.read(uint2(pos2.x, block2.y)).r;
            topSide += abs(a_top - b_top);
        }
        for(;pos1.x < block1.z && pos2.x < block2.z; pos1.x++, pos2.x++) {
            float a_bottom = tex1.read(uint2(pos1.x, block1.w-1)).r;
            float b_bottom = tex2.read(uint2(pos2.x, block2.w-1)).r;
            bottomSide += abs(a_bottom - b_bottom);
        }
        sum = previousSad - previousSide + bottomSide;
    } else {
        while(pos1.y < block1.w && pos2.y < block2.w) {
            pos1.x = block1.x;
            pos2.x = block2.x;
            while(pos1.x < block1.z && pos2.x < block2.z) {
                float a = tex1.read(uint2(pos1)).r;
                float b = tex2.read(uint2(pos2)).r;
                sum += abs(a - b);
                if(pos1.y == block1.y && pos2.y == block2.y) {
                    topSide += abs(a - b);
                }
                pos1.x++;
                pos2.x++;
            }
            pos1.y++;
            pos2.y++;
        }
    }

    return { topSide, sum };
}

inline int4 searchExtent(int4 originBlock,
                         int2 searchWindowSize,
                         int2 blockSize,
                         int2 imageSize) {
    const int left = clamp(originBlock.x + blockSize.x / 2 - searchWindowSize.x / 2, 0, imageSize.x);
    const int top  = clamp(originBlock.y + blockSize.y / 2 - searchWindowSize.y / 2, 0, imageSize.y);
    const int right = clamp(left + searchWindowSize.x, 0, imageSize.x);
    const int bottom = clamp(top + searchWindowSize.y, 0, imageSize.y);
    return int4(left, top, right, bottom);
}

#define MAX_SEARCH_SIZE 64

kernel void me_fullsearch(texture2d<float, access::write> outTexture [[texture(0)]],
                          texture2d<float, access::read> refTexture [[texture(1)]],
                          texture2d<float, access::read> curTexture [[texture(2)]],
                          constant MotionEstimationUniforms& uniforms [[buffer(0)]],
                          uint2 block [[thread_position_in_grid]]) {
    
    const int4 originBlock = int4(int2(block) * uniforms.blockSize, // block we are looking for
                                    int2(block) * uniforms.blockSize + uniforms.blockSize);
    const int4 searchArea = searchExtent(originBlock,
                                         min(uniforms.searchWindowSize,MAX_SEARCH_SIZE),
                                         uniforms.blockSize,
                                         uniforms.imageSize);
   
    const float2 maxMV = float2(uniforms.searchWindowSize / 2);
    const float threshold = 0;
    
    int4 refBlock = int4(searchArea.xy, searchArea.xy + uniforms.blockSize);
    
    float bestScore = MAXFLOAT;
    float2 bestMV = float2(0,0);
    float bestSad = MAXFLOAT;
    float leftSide = 0;
    float prevSad = 0;
    bool earlyExit = false;
    while(refBlock.z < searchArea.z && !earlyExit) {
        refBlock.y = searchArea.y;
        refBlock.w = refBlock.y + uniforms.blockSize.y;
        while(refBlock.w < searchArea.w && !earlyExit) {
            const SadReturn sad = sumAbsoluteDifferences(originBlock,
                                                           refBlock,
                                                           curTexture,
                                                           refTexture,
                                                           leftSide,
                                                           prevSad);
            const float2 motionVector = float2(originBlock.xy) - float2(refBlock.xy);
            const float score = deltaCost2(motionVector) + sad.sad * 256.0;
            prevSad = sad.sad;
            leftSide = sad.leftSide;
            
            if(score < bestScore) {
                bestScore = score;
                bestSad = sad.sad;
                bestMV = clamp(motionVector, -maxMV, maxMV);
            }
            
            if(score < threshold) {
                earlyExit = true;
            }
            refBlock.y ++;
            refBlock.w ++;
        }
        leftSide = 0;
        prevSad = 0;
        refBlock.x ++;
        refBlock.z ++;
    }
    //bestMV = float2(originBlock.xy) - float2(searchArea.xy);
    bestMV /= float2(uniforms.searchWindowSize / 2); // normalize
    bestMV = bestMV * 0.5 + 0.5; // make positive
    outTexture.write(float4(bestMV.x, 0.5, bestMV.y, 1.0), block);

}
