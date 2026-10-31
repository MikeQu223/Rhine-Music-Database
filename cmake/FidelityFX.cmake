# AMD FidelityFX integration (build system only).
#
# The vendored FidelityFX SDK 1.1.4 ships a Windows/MSVC-only CMake build
# (sdk/CMakeLists.txt requires CMAKE_GENERATOR_PLATFORM=x64 and a shader
# compiler to pre-compile shaders), so it cannot be added as-is on Linux. This
# module wires the parts we need into the Rhine build:
#
#   * FSR3 host components: ffx_fsr3upscaler, ffx_frameinterpolation,
#     ffx_opticalflow plus the shared host sources they depend on.
#   * Vulkan backend (sdk/src/backends/vk) with its FSR3/FI/OF shader permutations.
#     The shaders are compiled from the SDK's GLSL sources at build time:
#     FfxShaderCompiler.cmake builds ffx_shader_compiler from source, and
#     Glslang.cmake builds the glslangValidator it drives. No prebuilt binary
#     from FidelityFX-SDK/sdk/tools/**/libs/ is used on any platform.
#   * DX12 backend: kept behind if(WIN32) and delegated to the SDK's own CMake.
#     The shader compiler it drives is our own ffx_sc, and the DXC behind it is
#     built from third_party/dxc at build time (Dxc.cmake) — the prebuilt
#     sdk/tools/binary_store/FidelityFX_SC.exe is never used.
#     It never blocks a Linux build.
#
# Nothing under FidelityFX-SDK/ or FidelityFX-FSR/ is modified. GCC/Clang need
# a few compatibility shims that are supplied from the build tree instead:
#   * FFX_GCC removes __declspec(dllexport) from FFX_API (ffx_types.h).
#   * cmake/ffx_linux_compat.h is force-included and provides _countof,
#     wcscpy_s, <cstddef>/<cwchar>/<cmath> and a wstring_convert replacement.
#   * two SDK sources use the MSVC-only `L#token` wide-string trick; a copy with
#     `L"" #token` is generated under the build tree and compiled instead.
#
# Targets exposed for the eventual FSR3 runtime wiring:
#   FidelityFX::SDK               aggregate (components + available backends)
#   FidelityFX::fsr3upscaler      FSR3 upscaler host API
#   FidelityFX::frameinterpolation frame interpolation host API
#   FidelityFX::opticalflow       optical flow host API
#   FidelityFX::backend_vk        Vulkan backend (when Vulkan is available)
#   FidelityFX::backend_dx12      DX12 backend (WIN32 only)
#   FidelityFX::fsr1_reference    FSR1 EASU/RCAS shader sources (reference only)

include_guard(GLOBAL)

# Shader permutations are produced at build time by these two helpers:
#   Glslang.cmake          builds glslangValidator from third_party/glslang
#   FfxShaderCompiler.cmake builds ffx_shader_compiler from the SDK sources and drives it
include("${CMAKE_CURRENT_LIST_DIR}/Glslang.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/FfxShaderCompiler.cmake")

set(RHINE_FFX_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/FidelityFX-SDK")
set(RHINE_FFX_FSR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/FidelityFX-FSR")
set(RHINE_FFX_COMPAT_HEADER "${CMAKE_CURRENT_LIST_DIR}/ffx_linux_compat.h")

# Pinned submodule revisions, mirrored in .gitmodules.
set(RHINE_FFX_SDK_PIN "c6efa6bf7f2027b3ec94f28578bb5965eabb9e55")
set(RHINE_FFX_FSR_PIN "a21ffb8f6c13233ba336352bdff293894c706575")

option(RHINE_ENABLE_FIDELITYFX "Build the vendored FidelityFX SDK (FSR3 host components and backends)" ON)

if(NOT RHINE_ENABLE_FIDELITYFX)
    message(STATUS "FidelityFX: disabled by RHINE_ENABLE_FIDELITYFX=OFF")
    return()
endif()

if(NOT EXISTS "${RHINE_FFX_SDK_DIR}/sdk/include/FidelityFX/host/ffx_interface.h")
    message(STATUS "FidelityFX: FidelityFX-SDK/ is not checked out; skipping SDK targets")
    return()
endif()

find_package(Git QUIET)

# Report the checked-out revision and warn when it drifts from the pin recorded
# in .gitmodules (the gitlink itself cannot be staged from the build system).
function(_rhine_ffx_check_pin repository label expected)
    if(NOT GIT_FOUND OR NOT EXISTS "${repository}/.git")
        return()
    endif()
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" -C "${repository}" rev-parse HEAD
        OUTPUT_VARIABLE actual
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
        RESULT_VARIABLE result)
    if(NOT result EQUAL 0)
        return()
    endif()
    if(NOT actual STREQUAL expected)
        message(
            WARNING
                "FidelityFX: ${label} is checked out at ${actual}, expected pin ${expected} (see .gitmodules)"
        )
    else()
        message(STATUS "FidelityFX: ${label} @ ${actual}")
    endif()
endfunction()

_rhine_ffx_check_pin("${RHINE_FFX_SDK_DIR}" "FidelityFX-SDK" "${RHINE_FFX_SDK_PIN}")
if(EXISTS "${RHINE_FFX_FSR_DIR}/license.txt")
    _rhine_ffx_check_pin("${RHINE_FFX_FSR_DIR}" "FidelityFX-FSR" "${RHINE_FFX_FSR_PIN}")
endif()

# ---------------------------------------------------------------------------
# Build-tree compatibility copies for MSVC-only source constructs.
# ---------------------------------------------------------------------------

set(RHINE_FFX_COMPAT_DIR "${CMAKE_CURRENT_BINARY_DIR}/fidelityfx-compat")

function(_rhine_ffx_compat_copy source_rel output_path)
    set(source "${RHINE_FFX_SDK_DIR}/${source_rel}")
    file(READ "${source}" contents)
    # MSVC accepts `L#token` (wide literal from stringification); GCC/Clang do
    # not, but `L"" #token` is portable and produces the same wide literal.
    string(REGEX REPLACE "L#([A-Za-z_][A-Za-z0-9_]*)" "L\"\" #\\1" contents "${contents}")
    if(contents MATCHES "L#[A-Za-z_]")
        message(FATAL_ERROR "FidelityFX: could not rewrite MSVC-only L#token in ${source}")
    endif()
    # libstdc++ 16 removed std::wstring_convert; the shim provides an
    # equivalent UTF-8 <-> wchar_t converter with the same call syntax. The SDK spells
    # the template two ways, so both are rewritten.
    string(REPLACE "std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> converter;"
                   "RhineFfxWideConverter converter;" contents "${contents}")
    string(REPLACE "std::wstring_convert<std::codecvt_utf8<wchar_t>, wchar_t> converter;"
                   "RhineFfxWideConverter converter;" contents "${contents}")
    if(contents MATCHES "std::wstring_convert")
        message(FATAL_ERROR "FidelityFX: unhandled std::wstring_convert spelling in ${source}")
    endif()
    # ffx_vk.cpp：BackendContext_VK::EffectContext 带 alignas(32)，但 scratch 里排在它
    # 前面的几个数组只按 4 字节对齐，GCC/Clang 会为它的赋值生成 movaps 对齐写，一旦落在
    # 非 16 字节边界就直接 SIGSEGV（MSVC 生成非对齐写，所以上游没暴露这个问题）。
    # 这里在映射 context 数组之前补一次 32 字节对齐，并在尺寸函数里留出同样的余量。
    if(source_rel MATCHES "backends/vk/ffx_vk\\.cpp")
        string(REPLACE "pipelineArraySize + resourceArraySize + contextArraySize,"
                       "pipelineArraySize + resourceArraySize + contextArraySize + 32,"
                       contents "${contents}")
        string(REPLACE "        // Map context array\n        backendContext->pEffectContexts = (BackendContext_VK::EffectContext*)pMem;"
                       "        // Map context array: EffectContext is alignas(32), so align before mapping.\n        pMem = (uint8_t*)FFX_ALIGN_UP((uintptr_t)pMem, 32);\n        backendContext->pEffectContexts = (BackendContext_VK::EffectContext*)pMem;"
                       contents "${contents}")
        if(NOT contents MATCHES "FFX_ALIGN_UP\\(\\(uintptr_t\\)pMem, 32\\)")
            message(FATAL_ERROR "FidelityFX: ffx_vk.cpp EffectContext alignment patch did not apply")
        endif()
        # RHINE：给 FFX 的计算管线挂进程级 VkPipelineCache。上游 SDK 全程没有管线缓存，
        # 而 FSR3 上下文在 resize 时会被整体重建、每个 pass 重新编译；核显上这批编译正好
        # 落在用户拖窗口的那一刻。代码块放在 cmake/ffx_vk_pipeline_cache.inc，这里注入到
        # CreatePipelineVK 的入口处，并把建管线时的 pipelineCache 参数从 nullptr 换过去。
        file(READ "${CMAKE_CURRENT_LIST_DIR}/ffx_vk_pipeline_cache.inc" rhine_pipeline_cache_block)
        string(FIND "${contents}" "    // start by fetching the shader blob" rhine_cache_anchor)
        if(rhine_cache_anchor EQUAL -1)
            message(FATAL_ERROR "FidelityFX: ffx_vk.cpp pipeline-cache anchor not found")
        endif()
        string(REPLACE "    // start by fetching the shader blob"
                       "${rhine_pipeline_cache_block}    // start by fetching the shader blob"
                       contents "${contents}")
        file(READ "${CMAKE_CURRENT_LIST_DIR}/ffx_vk_pipeline_cache_create.inc" rhine_pipeline_create_block)
        string(REPLACE "    if (backendContext->vkFunctionTable.vkCreateComputePipelines(backendContext->device, nullptr, 1, &pipelineCreateInfo, nullptr, &computePipeline) != VK_SUCCESS) {"
                       "${rhine_pipeline_create_block}"
                       contents "${contents}")
        string(REPLACE "#include <vulkan/vulkan.h>"
                       "#include <vulkan/vulkan.h>\n#include <cstdio>\n#include <cstdlib>\n#include <ctime>"
                       contents "${contents}")
        if(NOT contents MATCHES "rhinePipelineResult != VK_SUCCESS")
            message(FATAL_ERROR "FidelityFX: ffx_vk.cpp pipeline-cache patch did not apply")
        endif()
    endif()
    if(EXISTS "${output_path}")
        file(READ "${output_path}" previous)
        if(previous STREQUAL contents)
            return()
        endif()
    endif()
    file(WRITE "${output_path}" "${contents}")
endfunction()

# ---------------------------------------------------------------------------
# Context size override for 4-byte wchar_t platforms.
#
# The opaque effect contexts are fixed-size arrays sized by FFX_SDK_DEFAULT_CONTEXT_SIZE
# (512 KiB as 131072 uint32). That number is calibrated for Windows, where wchar_t is two
# bytes. On Linux wchar_t is four bytes, and FfxResourceBinding embeds a
# wchar_t[FFX_RESOURCE_NAME_SIZE] name, so it grows from 140 to 268 bytes. With twelve
# FfxPipelineState members the FSR3 upscaler's private context reaches 837848 bytes and the
# SDK's own static_assert in ffx_fsr3upscaler.cpp fails.
#
# Measured requirements on Linux x86-64 (uint32 slots): FSR3 upscaler 209462, frame
# interpolation 192018, optical flow 122210. 262144 slots (1 MiB) leaves headroom.
#
# The constant is a plain #define in a public header, so it cannot be overridden from the
# command line. Instead a build-tree copy of ffx_types.h with the one literal changed is
# placed ahead of sdk/include. The copy is generated from the vendored header, so it
# cannot drift when the SDK revision changes.
# ---------------------------------------------------------------------------

set(RHINE_FFX_OVERRIDE_INCLUDE "${RHINE_FFX_COMPAT_DIR}/include")

function(_rhine_ffx_override_context_size)
    if(MSVC)
        # 2-byte wchar_t: the SDK's own default is correct, nothing to override.
        return()
    endif()

    set(source "${RHINE_FFX_SDK_DIR}/sdk/include/FidelityFX/host/ffx_types.h")
    set(destination "${RHINE_FFX_OVERRIDE_INCLUDE}/FidelityFX/host/ffx_types.h")
    set(original "#define FFX_SDK_DEFAULT_CONTEXT_SIZE (1024 * 128)")
    set(replacement "#define FFX_SDK_DEFAULT_CONTEXT_SIZE (1024 * 256)")

    file(READ "${source}" contents)
    string(FIND "${contents}" "${original}" position)
    if(position EQUAL -1)
        message(
            FATAL_ERROR
                "FidelityFX: '${original}' is gone from ${source}; re-check the 4-byte wchar_t context size override"
        )
    endif()
    string(REPLACE "${original}" "${replacement}" contents "${contents}")

    if(EXISTS "${destination}")
        file(READ "${destination}" previous)
        if(previous STREQUAL contents)
            return()
        endif()
    endif()
    file(WRITE "${destination}" "${contents}")
endfunction()

_rhine_ffx_override_context_size()

# The frame-interpolation swapchain includes <Windows.h> unconditionally. Install the
# POSIX shim as Windows.h in the same override directory so those sources compile without
# touching the vendored tree.
if(NOT MSVC)
    configure_file("${CMAKE_CURRENT_LIST_DIR}/ffx_windows_shim.h"
                   "${RHINE_FFX_OVERRIDE_INCLUDE}/Windows.h" COPYONLY)
    configure_file("${CMAKE_CURRENT_LIST_DIR}/ffx_synchapi_shim.h"
                   "${RHINE_FFX_OVERRIDE_INCLUDE}/synchapi.h" COPYONLY)
endif()

# ---------------------------------------------------------------------------
# Common target configuration for SDK translation units.
# ---------------------------------------------------------------------------

function(_rhine_ffx_configure_target target)
    set_target_properties(
        ${target}
        PROPERTIES CXX_STANDARD 20
                   CXX_STANDARD_REQUIRED ON
                   CXX_EXTENSIONS OFF
                   AUTOMOC OFF
                   AUTOUIC OFF
                   AUTORCC OFF)
    # The override copy has to come first so every translation unit, ours included, sees
    # the same context layout.
    target_include_directories(${target} BEFORE PUBLIC "${RHINE_FFX_OVERRIDE_INCLUDE}")
    target_include_directories(${target} PUBLIC "${RHINE_FFX_SDK_DIR}/sdk/include")
    if(MSVC)
        target_compile_options(${target} PRIVATE /W3)
        target_compile_definitions(${target} PUBLIC UNICODE _UNICODE NOMINMAX)
    else()
        # FFX_API is __declspec(dllexport) unless FFX_GCC is defined.
        target_compile_definitions(${target} PUBLIC FFX_GCC)
        target_compile_options(${target} PRIVATE -include "${RHINE_FFX_COMPAT_HEADER}"
                                                  -Wno-deprecated-declarations)
        if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
            target_compile_options(${target} PRIVATE -Wno-write-strings)
        elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
            target_compile_options(${target} PRIVATE -Wno-writable-strings)
        endif()
    endif()
endfunction()

# ---------------------------------------------------------------------------
# Shared host sources and FSR3 components.
# ---------------------------------------------------------------------------

add_library(
    ffx_shared STATIC
    "${RHINE_FFX_SDK_DIR}/sdk/src/shared/ffx_assert.cpp"
    "${RHINE_FFX_SDK_DIR}/sdk/src/shared/ffx_breadcrumbs_list.cpp"
    "${RHINE_FFX_SDK_DIR}/sdk/src/shared/ffx_message.cpp"
    "${RHINE_FFX_SDK_DIR}/sdk/src/shared/ffx_object_management.cpp")
_rhine_ffx_configure_target(ffx_shared)
target_include_directories(ffx_shared PRIVATE "${RHINE_FFX_SDK_DIR}/sdk/src/shared")
add_library(FidelityFX::shared ALIAS ffx_shared)

set(_rhine_ffx_component_includes
    "${RHINE_FFX_SDK_DIR}/sdk/src/shared"
    "${RHINE_FFX_SDK_DIR}/sdk/src/components")

add_library(
    ffx_fsr3upscaler STATIC
    "${RHINE_FFX_SDK_DIR}/sdk/src/components/fsr3upscaler/ffx_fsr3upscaler.cpp"
    "${RHINE_FFX_SDK_DIR}/sdk/src/components/fsr3upscaler/ffx_fsr3upscaler_private.h")
_rhine_ffx_configure_target(ffx_fsr3upscaler)
target_include_directories(ffx_fsr3upscaler PRIVATE ${_rhine_ffx_component_includes})
target_link_libraries(ffx_fsr3upscaler PUBLIC ffx_shared)
add_library(FidelityFX::fsr3upscaler ALIAS ffx_fsr3upscaler)

add_library(
    ffx_frameinterpolation STATIC
    "${RHINE_FFX_SDK_DIR}/sdk/src/components/frameinterpolation/ffx_frameinterpolation.cpp"
    "${RHINE_FFX_SDK_DIR}/sdk/src/components/frameinterpolation/ffx_frameinterpolation_private.h")
_rhine_ffx_configure_target(ffx_frameinterpolation)
target_include_directories(ffx_frameinterpolation PRIVATE ${_rhine_ffx_component_includes})
target_link_libraries(ffx_frameinterpolation PUBLIC ffx_shared)
add_library(FidelityFX::frameinterpolation ALIAS ffx_frameinterpolation)

if(MSVC)
    set(_rhine_ffx_opticalflow_source
        "${RHINE_FFX_SDK_DIR}/sdk/src/components/opticalflow/ffx_opticalflow.cpp")
else()
    file(MAKE_DIRECTORY "${RHINE_FFX_COMPAT_DIR}")
    _rhine_ffx_compat_copy("sdk/src/components/opticalflow/ffx_opticalflow.cpp"
                           "${RHINE_FFX_COMPAT_DIR}/ffx_opticalflow.cpp")
    set(_rhine_ffx_opticalflow_source "${RHINE_FFX_COMPAT_DIR}/ffx_opticalflow.cpp")
endif()

add_library(
    ffx_opticalflow STATIC
    "${_rhine_ffx_opticalflow_source}"
    "${RHINE_FFX_SDK_DIR}/sdk/src/components/opticalflow/ffx_opticalflow_private.h")
_rhine_ffx_configure_target(ffx_opticalflow)
target_include_directories(
    ffx_opticalflow PRIVATE ${_rhine_ffx_component_includes}
                            "${RHINE_FFX_SDK_DIR}/sdk/src/components/opticalflow")
target_link_libraries(ffx_opticalflow PUBLIC ffx_shared)
add_library(FidelityFX::opticalflow ALIAS ffx_opticalflow)

# ---------------------------------------------------------------------------
# Vulkan shader permutations.
#
# Mirrors the SDK's own sdk/src/backends/vk/CMakeShaders*.txt scripts: same compiler
# arguments, same permutation matrices, same output layout. The generated headers are
# flat in one directory because the SDK's blob accessors include them by bare name
# (`#include <ffx_fsr3upscaler_rcas_pass_permutations.h>`).
# ---------------------------------------------------------------------------

function(_rhine_ffx_generate_vk_shaders target sdk_dir sc_executable glslang_executable)
    set(gpu "${sdk_dir}/sdk/include/FidelityFX/gpu")
    set(shader_root "${sdk_dir}/sdk/src/backends/vk/shaders")
    # 置换头有 364 个文件、约 25MB，而重新生成要跑上千次 glslang（首次全量约 40 分钟）。
    # 因此默认落在源码树里未被 .gitignore 排除的 generated/ 下，而不是 output/ 里——
    # 后者整目录被忽略，产物既无法复用也无法跨机拷贝。需要时可用
    # -DRHINE_FFX_SHADER_OUTPUT_DIR=<dir> 覆盖。
    set(RHINE_FFX_SHADER_OUTPUT_DIR
        "${CMAKE_SOURCE_DIR}/generated/ffx_shaders/vk"
        CACHE PATH "FidelityFX Vulkan 置换头的输出目录（默认在源码树内，便于复用）")
    set(output "${RHINE_FFX_SHADER_OUTPUT_DIR}")
    file(MAKE_DIRECTORY "${output}")

    # Tool selection plus a modest per-invocation thread count: CMake already runs
    # several shaders concurrently, and each invocation internally compiles 2^N
    # permutations through glslangValidator.
    set(tool_args "-glslangexe=${glslang_executable}" -num-threads=4)

    # Vulkan flavour of the compiler arguments, identical across the three effects.
    set(api_base_args -compiler=glslang -e CS --target-env vulkan1.2 -S comp -Os -DFFX_GLSL=1)

    # Shared "half precision sampler" choices; only reprojection runs at half precision.
    set(sampler_args
        -DFFX_FSR3UPSCALER_OPTION_UPSAMPLE_SAMPLERS_USE_DATA_HALF=0
        -DFFX_FSR3UPSCALER_OPTION_ACCUMULATE_SAMPLERS_USE_DATA_HALF=0
        -DFFX_FSR3UPSCALER_OPTION_REPROJECT_SAMPLERS_USE_DATA_HALF=1
        -DFFX_FSR3UPSCALER_OPTION_POSTPROCESSLOCKSTATUS_SAMPLERS_USE_DATA_HALF=0
        -DFFX_FSR3UPSCALER_OPTION_UPSAMPLE_USE_LANCZOS_TYPE=2)
    set(fi_sampler_args
        -DFFX_FRAMEINTERPOLATION_OPTION_UPSAMPLE_SAMPLERS_USE_DATA_HALF=0
        -DFFX_FRAMEINTERPOLATION_OPTION_ACCUMULATE_SAMPLERS_USE_DATA_HALF=0
        -DFFX_FRAMEINTERPOLATION_OPTION_REPROJECT_SAMPLERS_USE_DATA_HALF=1
        -DFFX_FRAMEINTERPOLATION_OPTION_POSTPROCESSLOCKSTATUS_SAMPLERS_USE_DATA_HALF=0
        -DFFX_FRAMEINTERPOLATION_OPTION_UPSAMPLE_USE_LANCZOS_TYPE=2)

    set(deps ffx_sc glslang-standalone)
    set(all_outputs "")

    # --- FSR3 upscaler: 10 passes, 6 binary options -> 64 permutations per variant.
    file(GLOB fsr3_shaders "${shader_root}/fsr3upscaler/*.glsl")
    set(fsr3_perm_args
        "-DFFX_FSR3UPSCALER_OPTION_REPROJECT_USE_LANCZOS_TYPE={0,1}"
        "-DFFX_FSR3UPSCALER_OPTION_HDR_COLOR_INPUT={0,1}"
        "-DFFX_FSR3UPSCALER_OPTION_LOW_RESOLUTION_MOTION_VECTORS={0,1}"
        "-DFFX_FSR3UPSCALER_OPTION_JITTERED_MOTION_VECTORS={0,1}"
        "-DFFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH={0,1}"
        "-DFFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING={0,1}")
    rhine_ffx_compile_shaders(
        "${sc_executable}"
        "${tool_args}"
        "-reflection;-deps=gcc;-DFFX_GPU=1;${sampler_args}"
        "${api_base_args}"
        "${fsr3_perm_args}"
        "${gpu};${gpu}/fsr3upscaler"
        "${fsr3_shaders}"
        "${output}"
        fsr3_outputs
        ${deps})
    list(APPEND all_outputs ${fsr3_outputs})

    # --- Frame interpolation: 11 passes, 3 binary options -> 8 permutations per variant.
    file(GLOB fi_shaders "${shader_root}/frameinterpolation/*.glsl")
    set(fi_perm_args
        "-DFFX_FRAMEINTERPOLATION_OPTION_LOW_RES_MOTION_VECTORS={0,1}"
        "-DFFX_FRAMEINTERPOLATION_OPTION_JITTER_MOTION_VECTORS={0,1}"
        "-DFFX_FRAMEINTERPOLATION_OPTION_INVERTED_DEPTH={0,1}")
    rhine_ffx_compile_shaders(
        "${sc_executable}"
        "${tool_args}"
        "-reflection;-deps=gcc;-DFFX_GPU=1;${fi_sampler_args}"
        "${api_base_args}"
        "${fi_perm_args}"
        "${gpu};${gpu}/frameinterpolation"
        "${fi_shaders}"
        "${output}"
        fi_outputs
        ${deps})
    list(APPEND all_outputs ${fi_outputs})

    # --- Optical flow: 7 passes, 1 binary option -> 2 permutations per variant.
    file(GLOB of_shaders "${shader_root}/opticalflow/*.glsl")
    set(of_perm_args "-DFFX_OPTICALFLOW_OPTION_HDR_COLOR_INPUT={0,1}")
    rhine_ffx_compile_shaders(
        "${sc_executable}"
        "${tool_args}"
        "-reflection;-deps=gcc;-DFFX_GPU=1"
        "${api_base_args}"
        "${of_perm_args}"
        "${gpu};${gpu}/opticalflow"
        "${of_shaders}"
        "${output}"
        of_outputs
        ${deps})
    list(APPEND all_outputs ${of_outputs})

    list(LENGTH all_outputs _rhine_ffx_shader_count)
    message(STATUS "FidelityFX: generating ${_rhine_ffx_shader_count} Vulkan shader permutation headers")

    target_sources(${target} PRIVATE ${all_outputs})
    target_include_directories(${target} PRIVATE "${output}")
    set(RHINE_FFX_SHADER_OUTPUT_DIR
        "${output}"
        PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# Vulkan backend. Its FSR3 / frame-interpolation / optical-flow shaders are compiled
# from the SDK's GLSL sources at build time, so the permutation headers always match the
# vendored SDK revision and no prebuilt shader binary is consumed.
# ---------------------------------------------------------------------------

set(RHINE_FFX_VK_AVAILABLE FALSE)
set(RHINE_FFX_SHADER_BLOBS_AVAILABLE FALSE)

find_package(Vulkan QUIET)
if(Vulkan_FOUND OR VULKAN_FOUND)
    if(MSVC)
        set(_rhine_ffx_vk_source "${RHINE_FFX_SDK_DIR}/sdk/src/backends/vk/ffx_vk.cpp")
    else()
        file(MAKE_DIRECTORY "${RHINE_FFX_COMPAT_DIR}")
        _rhine_ffx_compat_copy("sdk/src/backends/vk/ffx_vk.cpp"
                               "${RHINE_FFX_COMPAT_DIR}/ffx_vk.cpp")
        set(_rhine_ffx_vk_source "${RHINE_FFX_COMPAT_DIR}/ffx_vk.cpp")
    endif()

    set(_rhine_ffx_blob_dir "${RHINE_FFX_SDK_DIR}/sdk/src/backends/shared/blob_accessors")

    add_library(
        ffx_backend_vk STATIC
        "${_rhine_ffx_vk_source}"
        "${RHINE_FFX_SDK_DIR}/sdk/src/backends/shared/ffx_shader_blobs.cpp"
        "${RHINE_FFX_SDK_DIR}/sdk/src/backends/shared/ffx_shader_blobs.h"
        "${_rhine_ffx_blob_dir}/ffx_fsr3upscaler_shaderblobs.cpp"
        "${_rhine_ffx_blob_dir}/ffx_frameinterpolation_shaderblobs.cpp"
        "${_rhine_ffx_blob_dir}/ffx_opticalflow_shaderblobs.cpp"
        "${RHINE_FFX_SDK_DIR}/sdk/include/FidelityFX/host/backends/vk/ffx_vk.h")

    # ffx_vk.cpp always installs a frame-generation callback, so the symbol must exist.
    # The stand-in reports the feature as unavailable instead of breaking the link.
    #
    # 这里对 Windows 也用替身，而不是编 SDK 真正的交换链（见 ffx_fg_unsupported.cpp）。
    # 原因不是"Windows 编不过"，而是两条独立的硬约束：
    #   * 呈现权在 Qt 手里。交换链由 QRhi 创建和 present，SDK 的交换链要求调用方把
    #     交换链交出来、由它接管 present（ffxReplaceSwapchainForFrameinterpolationVK
    #     会 vkDestroySwapchainKHR 调用方传入的交换链），这在 QQuickWindow 下拿不到。
    #     本项目的呈现层是自己写的 VulkanPresenter，见 docs/fg-integration-plan.md。
    #   * 符号冲突。DX12 与 VK 两套交换链各自定义了同名非 static 符号
    #     （interpolationThread / ffxWaitForPresents /
    #     ffxFrameInterpolationUiComposition / s_debugPacingFrameIndex）。上游从不把
    #     两个后端链进同一个二进制，所以没暴露过；Rhine 同时支持两个后端，一旦两者
    #     都参与链接就是 LNK2005 重复定义。只用替身可以彻底避开这一类冲突。
    # 真需要 FG 呈现时补的是 VulkanPresenter 那条路径，不是把 SDK 交换链编回来。
    target_sources(ffx_backend_vk PRIVATE "${CMAKE_CURRENT_LIST_DIR}/ffx_fg_unsupported.cpp")
    _rhine_ffx_configure_target(ffx_backend_vk)
    # ffx_shader_blobs.cpp 用这些宏决定为哪些 effect 生成 wave64 查询分支。
    # 缺任何一个，ffxGetEffectIsWave64 会落到 default 直接返回 FFX_ERROR_BACKEND_API_ERROR，
    # 表现为 ffxFsr3UpscalerContextCreate 失败（实测返回码 -2147483635）。
    target_compile_definitions(ffx_backend_vk PRIVATE FFX_FSR3UPSCALER FFX_FI FFX_OF)
    # The blob accessors reach into each effect's private header through a
    # "<effect>/..." path, so sdk/src/components has to be an include root.
    target_include_directories(ffx_backend_vk
                               PRIVATE "${RHINE_FFX_SDK_DIR}/sdk/src/backends/shared"
                                       "${RHINE_FFX_SDK_DIR}/sdk/src/components"
                                       "${RHINE_FFX_SDK_DIR}/sdk/src/shared")
    target_link_libraries(ffx_backend_vk PUBLIC ffx_shared Vulkan::Vulkan)
    add_library(FidelityFX::backend_vk ALIAS ffx_backend_vk)
    set(RHINE_FFX_VK_AVAILABLE TRUE)

    rhine_ffx_build_shader_compiler("${RHINE_FFX_SDK_DIR}" _rhine_ffx_sc_executable)
    rhine_ffx_resolve_glslang("${RHINE_FFX_SDK_DIR}" _rhine_ffx_glslang_executable)

    if(_rhine_ffx_sc_executable AND _rhine_ffx_glslang_executable)
        _rhine_ffx_generate_vk_shaders(ffx_backend_vk "${RHINE_FFX_SDK_DIR}"
                                       "${_rhine_ffx_sc_executable}"
                                       "${_rhine_ffx_glslang_executable}")
        set(RHINE_FFX_SHADER_BLOBS_AVAILABLE TRUE)
    else()
        message(
            STATUS
                "FidelityFX: Vulkan shader permutations cannot be generated "
                "(ffx_shader_compiler or glslangValidator unavailable); FSR3 will report unavailable at runtime")
    endif()

    message(STATUS "FidelityFX: Vulkan backend enabled (${Vulkan_LIBRARY})")
else()
    message(STATUS "FidelityFX: Vulkan not found; Vulkan backend target disabled")
endif()

# ---------------------------------------------------------------------------
# DX12 backend (Windows only). The SDK's own CMake still drives the permutation
# build, but the tools it drives (ffx_sc + DXC) are compiled from source here;
# nothing comes from the prebuilt binaries checked into the SDK.
# Never part of a Linux build.
# ---------------------------------------------------------------------------

set(RHINE_FFX_DX12_AVAILABLE FALSE)
if(WIN32 AND RHINE_ENABLE_D3D12_BACKEND)
    include("${CMAKE_CURRENT_LIST_DIR}/Dxc.cmake")

    set(FFX_API_DX12 ON)
    set(FFX_PLATFORM_NAME x64)
    set(FFX_INCLUDE_PATH "${RHINE_FFX_SDK_DIR}/sdk/include")
    # 不是 sdk/include：SDK 自己的 sdk/CMakeLists.txt:174 把 FFX_LIB_PATH 定义成
    # <sdk>/libs，dx12 后端靠 `target_include_directories(... PUBLIC ${FFX_LIB_PATH})`
    # 才能解析 antilag2/ffx_antilag2_dx12.h 与 pix/pix3.h 这两个头。写成 include
    # 就会得到 "fatal error C1083: Cannot open include file: 'pix/pix3.h'"。
    set(FFX_LIB_PATH "${RHINE_FFX_SDK_DIR}/sdk/libs")
    set(FFX_SHARED_PATH "${RHINE_FFX_SDK_DIR}/sdk/src/shared")
    set(FFX_HOST_PATH "${FFX_INCLUDE_PATH}/FidelityFX/host")
    set(FFX_GPU_PATH "${FFX_INCLUDE_PATH}/FidelityFX/gpu")
    set(FFX_COMPONENTS_PATH "${RHINE_FFX_SDK_DIR}/sdk/src/components")
    set(FFX_HOST_BACKENDS_PATH "${FFX_HOST_PATH}/backends")
    set(FFX_SRC_BACKENDS_PATH "${RHINE_FFX_SDK_DIR}/sdk/src/backends")
    # 不用 SDK 签入的 sdk/tools/binary_store/FidelityFX_SC.exe：那是预编译二进制。
    # 这里两个工具都从源码编：
    #   * ffx_sc —— cmake/FfxShaderCompiler.cmake，从 SDK 的 ffx_shader_compiler 源码；
    #   * DXC    —— cmake/Dxc.cmake，从 third_party/dxc（LLVM 级，首次较慢，之后复用）。
    rhine_dxc_build(_rhine_ffx_dxc_exe _rhine_ffx_dxc_dll)
    rhine_ffx_build_shader_compiler("${RHINE_FFX_SDK_DIR}" _rhine_ffx_sc_exe)
    if(NOT _rhine_ffx_sc_exe OR NOT _rhine_ffx_dxc_dll)
        # 不静默降级：没有这两个工具就生成不了置换头，DX12 后端连编译都过不去，
        # 运行期 ffxFsr3UpscalerContextCreate 也必然失败。早点报出来更好查。
        message(FATAL_ERROR
            "FidelityFX: 无法从源码构建 DX12 着色器工具链（ffx_sc / DXC）。"
            "请检查 MSVC 工具链、Python 3 与 DIA SDK 是否就绪。")
    endif()

    # ffx_sc 用 -dxcdll=<dxcompiler.dll 路径> 指定 DXC（见
    # sdk/tools/ffx_shader_compiler/src/ffx_sc.cpp 里 -dxcdll 的解析；没有 -dxcexe 这个
    # 参数）。SDK 的 CMakeCompileShaders.txt 把命令写成
    # `COMMAND ${EXECUTABLE} ...`（未加引号），所以这里用列表：
    # 第一个元素是工具本身，后面是每次调用都附带的参数。
    set(FFX_SC_EXECUTABLE "${_rhine_ffx_sc_exe};-dxcdll=${_rhine_ffx_dxc_dll}")

    # dxcompiler.dll 由 -dxcdll 的绝对路径加载；它内部再按“可执行文件所在目录”找
    # dxil.dll，所以把两个 DLL 一并放到 ffx_sc.exe 旁边（构建树里，随 ffx_sc 更新）。
    add_custom_command(TARGET ffx_sc POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${_rhine_ffx_dxc_dll}" "$<TARGET_FILE_DIR:ffx_sc>"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${RHINE_DXC_OUTPUT_DIR}/dxil.dll" "$<TARGET_FILE_DIR:ffx_sc>"
        VERBATIM)
    add_dependencies(ffx_sc rhine_dxc)
    # SDK 1.1.4 的 dx12/CMakeLists.txt 只认这些按效果命名的开关：FFX_FSR1、FFX_FSR2、
    # FFX_FSR3UPSCALER、FFX_FI、FFX_OF……（FFX_ALL 是它们的并集）。FFX_FSR / FFX_FSR3
    # 是它不认识的名字，写了等于什么都没开。而 shader blob 访问器
    # （ffx_*_shaderblobs.cpp）和 CMakeShaders*.txt 全挂在这些开关上：一个都不开的话
    # 后端仍然编得过，但 FSR3 上下文创建时找不到 permutation blob，运行期必然失败。
    set(FFX_FSR3UPSCALER ON)
    set(FFX_FI ON)
    set(FFX_OF ON)
    set(FFX_ALL OFF)
    set(FFX_BUILD_AS_DLL OFF)
    set(SHADERS "")
    if(CMAKE_GENERATOR STREQUAL "Ninja")
        set(USE_DEPFILE TRUE)
    else()
        set(USE_DEPFILE FALSE)
    endif()
    # 置换头由我们自己的 ffx_sc 在构建时生成，工具是刚编出来的，不存在“缺失”这种
    # 状态：真出问题会在构建时以 ExternalProject / 编译错误的形式暴露，而不是悄悄关掉
    # DX12 —— 关掉之后运行期 ffxFsr3UpscalerContextCreate 必然失败，更难查。
    set(FFX_AUTO_COMPILE_SHADERS ON)

    # The SDK's DX12 target links `pixlib` from the Cauldron framework, which we
    # do not build; an empty interface target keeps the backend linkable.
    if(NOT TARGET pixlib)
        add_library(pixlib INTERFACE)
    endif()
    # SDK 的着色器脚本有一个自引用 bug，会把字面变量名混进 ninja 的 DEPENDS。
    #
    # sdk/include/FidelityFX/gpu/CMakeCompileShaders.txt 里：
    #   function(compile_shaders_with_depfile ... PERMUTATION_OUTPUTS)   # 形参
    #     list(APPEND PERMUTATION_OUTPUTS ${WAVE32_PERMUTATION_HEADER})  # 追加到形参
    #     set(${PERMUTATION_OUTPUTS} ${PERMUTATION_OUTPUTS} PARENT_SCOPE) # ← 问题在这
    # 最后一行展开后是
    #   set(FSR3UPSCALER_PERMUTATION_OUTPUTS "FSR3UPSCALER_PERMUTATION_OUTPUTS;<路径>...")
    # 即把变量名本身当作列表首元素写出去。这个裸名经 add_shader_output() 汇入
    # FFX_SC_PERMUTATION_OUTPUTS，再由 dx12/CMakeLists.txt:561 消费：
    #   add_custom_target(ffx_shader_permutations_dx12 DEPENDS ${FFX_SC_PERMUTATION_OUTPUTS})
    # CMake 把裸名当成相对路径（基准是这个子目录的 binary dir），于是 ninja 报
    #   "'fidelityfx/dx12/FSR3UPSCALER_PERMUTATION_OUTPUTS' missing and no known rule"
    # 这与 glob 是否命中、*.hlsl 是否存在无关——即使着色器齐全也照样发生。
    #
    # 为什么只有 Windows 中招：Linux 不走 SDK 的 add_subdirectory，而是用本文件里
    # _rhine_ffx_generate_vk_shaders 自己生成置换头。
    #
    # 修法：add_subdirectory 之前把这些幽灵路径建成真实文件。它们只是 ninja 的依赖
    # 占位，不是置换头本身（真正的 *_permutations.h 仍由 SDK 的 add_custom_command
    # 生成）。改 SDK 源码会脏化 submodule 工作树，且每次 configure 重写后又会复发。

    # i nocticed github action inf load gif is slower than endfield Rekindled's bpm when fixing windows ci
    # because th problem is so eh, is like many evils (oh thrers no neuro) so i should fix mang times
    set(_rhine_ffx_dx12_bin "${CMAKE_CURRENT_BINARY_DIR}/fidelityfx/dx12")
    file(MAKE_DIRECTORY "${_rhine_ffx_dx12_bin}")
    set(_rhine_ffx_dx12_ghosts)
    if(FFX_FSR3UPSCALER OR FFX_ALL)
        list(APPEND _rhine_ffx_dx12_ghosts FSR3UPSCALER_PERMUTATION_OUTPUTS)
    endif()
    if(FFX_FI OR FFX_ALL)
        list(APPEND _rhine_ffx_dx12_ghosts FRAMEINTERPOLATION_PERMUTATION_OUTPUTS)
    endif()
    if(FFX_OF OR FFX_ALL)
        list(APPEND _rhine_ffx_dx12_ghosts OPTICALFLOW_PERMUTATION_OUTPUTS)
    endif()
    foreach(_ghost IN LISTS _rhine_ffx_dx12_ghosts)
        file(TOUCH "${_rhine_ffx_dx12_bin}/${_ghost}")
    endforeach()
    if(_rhine_ffx_dx12_ghosts)
        message(STATUS "FidelityFX: DX12 幽灵依赖占位已就绪（${_rhine_ffx_dx12_ghosts}）")
    endif()

    # 顺带把着色器源数量打出来：源缺失会让置换头为空集、FSR3 运行期不可用，
    # 而这类问题在构建期是无声的，值得一行日志。
    set(_rhine_ffx_dx12_shader_root "${FFX_SRC_BACKENDS_PATH}/dx12/shaders")
    foreach(_effect fsr3upscaler frameinterpolation opticalflow)
        if(EXISTS "${_rhine_ffx_dx12_shader_root}/${_effect}")
            file(GLOB _rhine_ffx_effect_hlsl
                 "${_rhine_ffx_dx12_shader_root}/${_effect}/*.hlsl")
            list(LENGTH _rhine_ffx_effect_hlsl _rhine_ffx_effect_hlsl_count)
            message(STATUS
                "FidelityFX: DX12 ${_effect} 着色器源 ${_rhine_ffx_effect_hlsl_count} 个")
        endif()
    endforeach()

    set(_rhine_ffx_saved_module_path "${CMAKE_MODULE_PATH}")
    list(APPEND CMAKE_MODULE_PATH "${FFX_SRC_BACKENDS_PATH}/dx12")
    add_subdirectory("${FFX_SRC_BACKENDS_PATH}/dx12"
                     "${_rhine_ffx_dx12_bin}")
    set(CMAKE_MODULE_PATH "${_rhine_ffx_saved_module_path}")
    # target 名带 FFX_PLATFORM_NAME（x64）。按同一个变量取名，SDK 改名时会在这里
    # 报出来，而不是留下一个指向不存在目标的 ALIAS。
    if(TARGET ffx_backend_dx12_${FFX_PLATFORM_NAME})
        # SDK 在 sdk/CMakeLists.txt:161-164 用 add_compile_definitions 给整个 SDK 目录
        # 挂了 _UNICODE / UNICODE / _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR。我们不走那个
        # 顶层 CMakeLists（只 add_subdirectory 了 dx12 后端），这些定义就丢了，后果是
        #   ffx_dx12.cpp(345): error C2664: 'LoadLibraryA': cannot convert argument 1
        #   from 'const wchar_t *' to 'LPCSTR'
        # —— 没有 UNICODE 时 LoadLibrary 展开成 LoadLibraryA，而该处传的是宽字符路径。
        # 我们的 _rhine_ffx_configure_target() 只覆盖了自己创建的那几个 target，dx12
        # 后端是 add_subdirectory 内部建的，没走过它，所以在这里补上。
        target_compile_definitions(ffx_backend_dx12_${FFX_PLATFORM_NAME}
                                   PUBLIC UNICODE _UNICODE NOMINMAX
                                   PRIVATE _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)
        # 置换头由 ffx_shader_permutations_dx12 这个 custom target 生成，它和后端
        # target 之间只有“后端依赖它”这一条边，没有“它依赖工具”的边。不显式排到
        # ffx_sc/rhine_dxc 之后，并行构建会先跑着色器编译、再等工具出现，直接失败。
        if(TARGET ffx_shader_permutations_dx12)
            add_dependencies(ffx_shader_permutations_dx12 rhine_dxc ffx_sc)
        endif()
        add_library(FidelityFX::backend_dx12 ALIAS ffx_backend_dx12_${FFX_PLATFORM_NAME})
        set(RHINE_FFX_DX12_AVAILABLE TRUE)
        message(STATUS "FidelityFX: DX12 backend enabled (ffx_backend_dx12_${FFX_PLATFORM_NAME})")
    else()
        message(WARNING
            "FidelityFX: ffx_backend_dx12_${FFX_PLATFORM_NAME} 没有被生成，DX12 后端不可用")
    endif()
else()
    message(STATUS "FidelityFX: DX12 backend skipped (Windows-only)")
endif()

# ---------------------------------------------------------------------------
# Aggregate target for the eventual FSR3 runtime wiring.
# ---------------------------------------------------------------------------

add_library(rhine_fidelityfx_sdk INTERFACE)
add_library(FidelityFX::SDK ALIAS rhine_fidelityfx_sdk)
target_link_libraries(
    rhine_fidelityfx_sdk
    INTERFACE FidelityFX::fsr3upscaler
              FidelityFX::frameinterpolation
              FidelityFX::opticalflow)
if(TARGET FidelityFX::backend_vk)
    target_link_libraries(rhine_fidelityfx_sdk INTERFACE FidelityFX::backend_vk)
endif()
if(TARGET FidelityFX::backend_dx12)
    target_link_libraries(rhine_fidelityfx_sdk INTERFACE FidelityFX::backend_dx12)
endif()
target_include_directories(rhine_fidelityfx_sdk INTERFACE "${RHINE_FFX_SDK_DIR}/sdk/include")
# Consumers of the aggregate target must see the same context layout as the SDK
# translation units, so the override copy comes first here as well.
if(NOT MSVC)
    target_include_directories(rhine_fidelityfx_sdk BEFORE INTERFACE "${RHINE_FFX_OVERRIDE_INCLUDE}")
endif()
if(NOT MSVC)
    target_compile_definitions(rhine_fidelityfx_sdk INTERFACE FFX_GCC)
    # ffx_types.h 只用 <stdint.h> 却引用 size_t/wchar_t；让消费方无需先手工包含。
    # 必须写成单个 SHELL: 条目：target_compile_options 会去掉重复的 -include，
    # 拆成两个参数时会被压成 `-include cstddef cwchar`，cwchar 就成了输入文件。
    target_compile_options(rhine_fidelityfx_sdk INTERFACE "SHELL:-include cstddef -include cwchar")
endif()

set(RHINE_FFX_FSR3_AVAILABLE TRUE)

# ---------------------------------------------------------------------------
# FSR1 reference sources + MIT license distribution.
# ---------------------------------------------------------------------------

if(EXISTS "${RHINE_FFX_FSR_DIR}/ffx-fsr/ffx_fsr1.h")
    add_library(rhine_fidelityfx_fsr1_reference INTERFACE)
    add_library(FidelityFX::fsr1_reference ALIAS rhine_fidelityfx_fsr1_reference)
    target_sources(
        rhine_fidelityfx_fsr1_reference
        INTERFACE "${RHINE_FFX_FSR_DIR}/ffx-fsr/ffx_a.h"
                  "${RHINE_FFX_FSR_DIR}/ffx-fsr/ffx_fsr1.h")
    install(
        FILES "${RHINE_FFX_FSR_DIR}/ffx-fsr/ffx_a.h"
              "${RHINE_FFX_FSR_DIR}/ffx-fsr/ffx_fsr1.h"
        DESTINATION share/rhine/reference/fsr1)
endif()

# MIT requires the copyright notice to travel with binary distributions.
install(
    FILES "${RHINE_FFX_SDK_DIR}/LICENSE.txt"
    DESTINATION share/rhine/licenses
    RENAME FidelityFX-SDK-LICENSE.txt)
if(EXISTS "${RHINE_FFX_FSR_DIR}/license.txt")
    install(
        FILES "${RHINE_FFX_FSR_DIR}/license.txt"
        DESTINATION share/rhine/licenses
        RENAME FidelityFX-FSR-LICENSE.txt)
endif()

message(
    STATUS
        "FidelityFX: FSR3 components=ON vk=${RHINE_FFX_VK_AVAILABLE} dx12=${RHINE_FFX_DX12_AVAILABLE} shader_blobs=${RHINE_FFX_SHADER_BLOBS_AVAILABLE}"
)
