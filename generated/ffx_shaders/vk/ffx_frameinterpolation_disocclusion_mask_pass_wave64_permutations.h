#include "ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f.h"
#include "ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667.h"

typedef union ffx_frameinterpolation_disocclusion_mask_pass_wave64_PermutationKey {
    struct {
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_INVERTED_DEPTH : 1;
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_LOW_RES_MOTION_VECTORS : 1;
        uint32_t FFX_FRAMEINTERPOLATION_OPTION_JITTER_MOTION_VECTORS : 1;
    };
    uint32_t index;
} ffx_frameinterpolation_disocclusion_mask_pass_wave64_PermutationKey;

typedef struct ffx_frameinterpolation_disocclusion_mask_pass_wave64_PermutationInfo {
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
} ffx_frameinterpolation_disocclusion_mask_pass_wave64_PermutationInfo;

static const uint32_t g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_IndirectionTable[] = {
    0,
    1,
    0,
    1,
    0,
    1,
    0,
    1,
};

static const ffx_frameinterpolation_disocclusion_mask_pass_wave64_PermutationInfo g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_PermutationInfo[] = {
    { g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_size, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_data, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_CBVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_CBVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_CBVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_CBVResourceSets, 7, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_TextureSRVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_TextureSRVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_TextureSRVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_TextureSRVResourceSets, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_TextureUAVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_TextureUAVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_TextureUAVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_SamplerResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_SamplerResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_SamplerResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_97ced9cb6e16ace99d03bbbe4ce2cd8f_SamplerResourceSets, 0, 0, 0, 0, 0, },
    { g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_size, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_data, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_CBVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_CBVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_CBVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_CBVResourceSets, 7, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_TextureSRVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_TextureSRVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_TextureSRVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_TextureSRVResourceSets, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_TextureUAVResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_TextureUAVResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_TextureUAVResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_SamplerResourceNames, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_SamplerResourceBindings, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_SamplerResourceCounts, g_ffx_frameinterpolation_disocclusion_mask_pass_wave64_f793bbb407e55aa27a0b01453038b667_SamplerResourceSets, 0, 0, 0, 0, 0, },
};

