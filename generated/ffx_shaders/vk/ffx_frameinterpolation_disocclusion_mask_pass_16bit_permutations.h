#include "ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1.h"
#include "ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98.h"

typedef union ffx_frameinterpolation_disocclusion_mask_pass_16bit_PermutationKey {
    struct {
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_INVERTED_DEPTH : 1;
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_LOW_RES_MOTION_VECTORS : 1;
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_JITTER_MOTION_VECTORS : 1;
    };
    uint32_t index;
} ffx_frameinterpolation_disocclusion_mask_pass_16bit_PermutationKey;

typedef struct ffx_frameinterpolation_disocclusion_mask_pass_16bit_PermutationInfo {
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
} ffx_frameinterpolation_disocclusion_mask_pass_16bit_PermutationInfo;

static const uint32_t g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_IndirectionTable[] = {
    1,
    0,
    1,
    0,
    1,
    0,
    1,
    0,
};

static const ffx_frameinterpolation_disocclusion_mask_pass_16bit_PermutationInfo g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_PermutationInfo[] = {
    { g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_size, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_data, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_CBVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_CBVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_CBVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_CBVResourceSets, 7, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_TextureSRVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_TextureSRVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_TextureSRVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_TextureSRVResourceSets, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_TextureUAVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_TextureUAVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_TextureUAVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_SamplerResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_SamplerResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_SamplerResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_a743ca9da5bf340adb4afb9b30c99df1_SamplerResourceSets, 0, 0, 0, 0, 0, },
    { g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_size, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_data, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_CBVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_CBVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_CBVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_CBVResourceSets, 7, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_TextureSRVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_TextureSRVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_TextureSRVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_TextureSRVResourceSets, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_TextureUAVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_TextureUAVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_TextureUAVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_SamplerResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_SamplerResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_SamplerResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_16bit_58a1a2dfb7b64e548ede0635e81eac98_SamplerResourceSets, 0, 0, 0, 0, 0, },
};

