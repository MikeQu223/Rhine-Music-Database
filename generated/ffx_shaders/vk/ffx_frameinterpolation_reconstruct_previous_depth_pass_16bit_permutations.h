#include "ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b.h"
#include "ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909.h"

typedef union ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_PermutationKey {
    struct {
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_INVERTED_DEPTH : 1;
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_LOW_RES_MOTION_VECTORS : 1;
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_JITTER_MOTION_VECTORS : 1;
    };
    uint32_t index;
} ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_PermutationKey;

typedef struct ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_PermutationInfo {
    const uint32_t       blobSize;
    const unsigned char* blobData;


    const uint32_t  numConstantBuffers;
    const char**    constantBufferNames;
    const uint32_t* constantBufferBindings;
    const uint32_t* constantBufferCounts;
    const uint32_t* constantBufferSpaces;

    const uint32_t  numSRVTextures;
    const char**    srvTextureNames;
    const uint32_t* srvTextureBindings;
    const uint32_t* srvTextureCounts;
    const uint32_t* srvTextureSpaces;

    const uint32_t  numUAVTextures;
    const char**    uavTextureNames;
    const uint32_t* uavTextureBindings;
    const uint32_t* uavTextureCounts;
    const uint32_t* uavTextureSpaces;

    const uint32_t  numSRVBuffers;
    const char**    srvBufferNames;
    const uint32_t* srvBufferBindings;
    const uint32_t* srvBufferCounts;
    const uint32_t* srvBufferSpaces;

    const uint32_t  numUAVBuffers;
    const char**    uavBufferNames;
    const uint32_t* uavBufferBindings;
    const uint32_t* uavBufferCounts;
    const uint32_t* uavBufferSpaces;

    const uint32_t  numSamplers;
    const char**    samplerNames;
    const uint32_t* samplerBindings;
    const uint32_t* samplerCounts;
    const uint32_t* samplerSpaces;

    const uint32_t  numRTAccelerationStructures;
    const char**    rtAccelerationStructureNames;
    const uint32_t* rtAccelerationStructureBindings;
    const uint32_t* rtAccelerationStructureCounts;
    const uint32_t* rtAccelerationStructureSpaces;
} ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_PermutationInfo;

static const uint32_t g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_IndirectionTable[] = {
    1,
    0,
    1,
    0,
    1,
    0,
    1,
    0,
};

static const ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_PermutationInfo g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_PermutationInfo[] = {
    { g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_size, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_data, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_CBVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_CBVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_CBVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_CBVResourceSets, 3, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_TextureSRVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_TextureSRVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_TextureSRVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_TextureSRVResourceSets, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_TextureUAVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_TextureUAVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_TextureUAVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_SamplerResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_SamplerResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_SamplerResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_c4080dc41641ba60c4279a67fc04127b_SamplerResourceSets, 0, 0, 0, 0, 0, },
    { g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_size, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_data, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_CBVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_CBVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_CBVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_CBVResourceSets, 3, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_TextureSRVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_TextureSRVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_TextureSRVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_TextureSRVResourceSets, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_TextureUAVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_TextureUAVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_TextureUAVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_SamplerResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_SamplerResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_SamplerResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_16bit_5c930846f6636588c63bdbf1c4158909_SamplerResourceSets, 0, 0, 0, 0, 0, },
};

