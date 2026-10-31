#include "ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f.h"
#include "ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239.h"

typedef union ffx_frameinterpolation_reconstruct_previous_depth_pass_PermutationKey {
    struct {
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_INVERTED_DEPTH : 1;
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_LOW_RES_MOTION_VECTORS : 1;
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_JITTER_MOTION_VECTORS : 1;
    };
    uint32_t index;
} ffx_frameinterpolation_reconstruct_previous_depth_pass_PermutationKey;

typedef struct ffx_frameinterpolation_reconstruct_previous_depth_pass_PermutationInfo {
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
} ffx_frameinterpolation_reconstruct_previous_depth_pass_PermutationInfo;

static const uint32_t g_ffx_frameinterpolation_reconstruct_previous_depth_pass_IndirectionTable[] = {
    1,
    0,
    1,
    0,
    1,
    0,
    1,
    0,
};

static const ffx_frameinterpolation_reconstruct_previous_depth_pass_PermutationInfo g_ffx_frameinterpolation_reconstruct_previous_depth_pass_PermutationInfo[] = {
    { g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_size, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_data, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_CBVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_CBVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_CBVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_CBVResourceSets, 3, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_TextureSRVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_TextureSRVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_TextureSRVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_TextureSRVResourceSets, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_TextureUAVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_TextureUAVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_TextureUAVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_SamplerResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_SamplerResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_SamplerResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_1722b54597352133238e03581a95682f_SamplerResourceSets, 0, 0, 0, 0, 0, },
    { g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_size, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_data, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_CBVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_CBVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_CBVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_CBVResourceSets, 3, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_TextureSRVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_TextureSRVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_TextureSRVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_TextureSRVResourceSets, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_TextureUAVResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_TextureUAVResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_TextureUAVResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_SamplerResourceNames, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_SamplerResourceBindings, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_SamplerResourceCounts, g_ffx_frameinterpolation_reconstruct_previous_depth_pass_e967a857304942f5102f552d91394239_SamplerResourceSets, 0, 0, 0, 0, 0, },
};

