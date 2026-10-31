#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793.h"
#include "ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd.h"

typedef union ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_PermutationKey {
    struct {
        uint32_t FFX_FSR3UPSCALER_OPTION_LOW_RESOLUTION_MOTION_VECTORS : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_JITTERED_MOTION_VECTORS : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_REPROJECT_USE_LANCZOS_TYPE : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_HDR_COLOR_INPUT : 1;
        uint32_t FFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING : 1;
    };
    uint32_t index;
} ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_PermutationKey;

typedef struct ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_PermutationInfo {
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
} ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_PermutationInfo;

static const uint32_t g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_IndirectionTable[] = {
    6,
    3,
    5,
    2,
    7,
    1,
    4,
    0,
    6,
    3,
    5,
    2,
    7,
    1,
    4,
    0,
    6,
    3,
    5,
    2,
    7,
    1,
    4,
    0,
    6,
    3,
    5,
    2,
    7,
    1,
    4,
    0,
    6,
    3,
    5,
    2,
    7,
    1,
    4,
    0,
    6,
    3,
    5,
    2,
    7,
    1,
    4,
    0,
    6,
    3,
    5,
    2,
    7,
    1,
    4,
    0,
    6,
    3,
    5,
    2,
    7,
    1,
    4,
    0,
};

static const ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_PermutationInfo g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_PermutationInfo[] = {
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_ca43ccb044533a8a199ab5e00577408a_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_1fc8144adef4180f133ecd18fc077c57_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_15fd60aa4cc1a08467627f67d20beea8_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_a25b4b32b666f3a062debdb83c798f24_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_963c16bebeac1c05d9a95530d2e96c01_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_383585131d873eb2133d63bf7e205d84_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_d46f4ad7fcbb2b9151c0af3e1e22f793_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_size, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_data, 1, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_CBVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_CBVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_CBVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_CBVResourceSets, 3, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_TextureSRVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_TextureSRVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_TextureSRVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_TextureSRVResourceSets, 5, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_TextureUAVResourceNames, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_TextureUAVResourceBindings, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_TextureUAVResourceCounts, g_ffx_fsr3upscaler_prepare_inputs_pass_wave64_16bit_b16b54b6ca2011b951ecf846361b5fcd_TextureUAVResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
};

