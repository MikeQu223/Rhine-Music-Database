#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc.h"

typedef union ffx_fsr3upscaler_prepare_inputs_pass_wave64_PermutationKey {
    struct {
        uint32_t FFX_FSR3UPSCALER_OPTION_LOW_RESOLUTION_MOTION_VECTORS : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_JITTERED_MOTION_VECTORS : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_REPROJECT_USE_LANCZOS_TYPE : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_HDR_COLOR_INPUT : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING : 1;
    };
    uint32_t index;
} ffx_fsr3upscaler_prepare_inputs_pass_wave64_PermutationKey;

typedef struct ffx_fsr3upscaler_prepare_inputs_pass_wave64_PermutationInfo {
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
} ffx_fsr3upscaler_prepare_inputs_pass_wave64_PermutationInfo;

static const uint32_t g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_IndirectionTable[] = {
    7,
    3,
    4,
    1,
    6,
    2,
    5,
    0,
    7,
    3,
    4,
    1,
    6,
    2,
    5,
    0,
    7,
    3,
    4,
    1,
    6,
    2,
    5,
    0,
    7,
    3,
    4,
    1,
    6,
    2,
    5,
    0,
    7,
    3,
    4,
    1,
    6,
    2,
    5,
    0,
    7,
    3,
    4,
    1,
    6,
    2,
    5,
    0,
    7,
    3,
    4,
    1,
    6,
    2,
    5,
    0,
    7,
    3,
    4,
    1,
    6,
    2,
    5,
    0,
};

static const ffx_fsr3upscaler_prepare_inputs_pass_wave64_PermutationInfo g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_PermutationInfo[] = {
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_df034b79057eec123fe806210c3f2ecc_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_922a05c499f80e00eb153f5426afcb51_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_0466456d79ef58645f6bf9eca8a93d86_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_822720e3ccc137ccf1efd9d361fbc3e9_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_9fe1857c80cb4b4ab5795ce73b3673e4_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_3e0dc4ec92bbeaa5a657722bfc00b736_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_5e7cd27976df02c5f913921a98956a42_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_1c08f13f059e6d432c9eb50b6d6557bc_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
};

