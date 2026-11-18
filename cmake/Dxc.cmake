# DXC (DirectXShaderCompiler) —— 构建期从 third_party/dxc 源码编译。
#
# 为什么需要这个模块：FidelityFX SDK 只随仓库签入预编译的 FidelityFX_SC.exe、 dxcompiler.dll 与
# dxil.dll（sdk/tools/binary_store、sdk/tools/ffx_shader_compiler/ libs/dxc/bin）。Rhine 不接受预编译二进制，所以 Windows/DX12
# 路径上真正干活的 DXC 必须由我们自己编出来。
#
# 为什么用 ExternalProject 而不是 add_subdirectory：DXC 自带完整的 LLVM/Clang 树， 它的顶层 CMakeLists 会 project(LLVM)、重设
# CMAKE_MODULE_PATH、add_definitions、设置 全局策略和 CMAKE_RUNTIME_OUTPUT_DIRECTORY。直接 add_subdirectory 会把这些污染带进
# 主构建，target 命名（utils、tools、clang……）也可能和主构建撞车。ExternalProject 在 独立目录里嵌套跑一次 configure/build，只把产物路径交回来。
#
# 工具产物放 generated/dxc/，与应用构建目录分开保存，清理 output/ 后仍可复用。 该目录已被 .gitignore 排除；CI 只缓存本项目从锁定源码构建的工具及签名。

include_guard(GLOBAL)

get_filename_component(_rhine_dxc_repo_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

set(RHINE_DXC_SOURCE_DIR
    "${_rhine_dxc_repo_root}/third_party/dxc"
    CACHE PATH "Pinned DXC source checkout")
set(RHINE_DXC_BUILD_TYPE
    "Release"
    CACHE STRING "Build configuration for the host DXC toolchain")
include(ProcessorCount)
ProcessorCount(_rhine_dxc_processors)
if(_rhine_dxc_processors LESS 1)
    set(_rhine_dxc_processors 1)
endif()
if(_rhine_dxc_processors GREATER 8)
    set(_rhine_dxc_processors 8)
endif()
set(RHINE_DXC_BUILD_JOBS
    "${_rhine_dxc_processors}"
    CACHE STRING "Maximum parallel DXC build jobs")
if(NOT RHINE_DXC_BUILD_JOBS MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "RHINE_DXC_BUILD_JOBS must be a positive integer")
endif()

# 嵌套构建目录：LLVM 的产物很大，放在主构建树里而不是 generated/（那是给“可复用产物” 的，中间对象每次构建都会变，没必要长期留着）。
set(RHINE_DXC_BUILD_DIR "${CMAKE_BINARY_DIR}/dxc-build")

# 可复用的产物目录。与 RHINE_FFX_SHADER_OUTPUT_DIR 同理：放源码树里的 generated/。
set(RHINE_DXC_OUTPUT_DIR
    "${_rhine_dxc_repo_root}/generated/dxc/bin"
    CACHE PATH "Directory receiving the from-source dxc.exe/dxcompiler.dll/dxil.dll")
set(RHINE_DXC_REVISION_FILE
    "${_rhine_dxc_repo_root}/generated/dxc/dxc-source-revision.txt"
    CACHE FILEPATH "Marker recording which DXC source revision the staged binaries come from")

option(RHINE_DXC_REUSE_BUILT "Reuse the from-source DXC build staged in generated/dxc" ON)
option(RHINE_DXC_FORCE_REBUILD "Ignore the staged DXC build and re-run the nested build (incremental)" OFF)

# DXC 源码版本，用来判断 generated/dxc 里的产物是否还对应这份源码。 拿不到 git（源码包、没有 .git）时返回 unknown：仍然允许复用，只是感知不到源码改动。
function(_rhine_dxc_source_revision out_var)
    set(revision "unknown")
    find_package(Git QUIET)
    if(GIT_EXECUTABLE AND EXISTS "${RHINE_DXC_SOURCE_DIR}/.git")
        execute_process(
            COMMAND "${GIT_EXECUTABLE}" -C "${RHINE_DXC_SOURCE_DIR}" rev-parse HEAD
            OUTPUT_VARIABLE revision
            OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
        if(NOT revision)
            set(revision "unknown")
        endif()
    endif()
    set(${out_var}
        "${revision}"
        PARENT_SCOPE)
endfunction()

# 从源码构建 DXC，并把产物路径写回 <out_exe> / <out_dxcompiler>。 只应在 Windows 上调用（DX12 后端专用）；Linux 上 include 这个文件本身是安全的，
# 因为所有工作都发生在函数里，函数只有被调用时才执行。
function(rhine_dxc_build out_exe out_dxcompiler)
    set(${out_exe}
        ""
        PARENT_SCOPE)
    set(${out_dxcompiler}
        ""
        PARENT_SCOPE)

    if(NOT WIN32 OR NOT MSVC)
        message(FATAL_ERROR "Dxc.cmake: DXC 只用于 Windows/MSVC 的 DX12 后端，"
                            "当前平台 WIN32=${WIN32} MSVC=${MSVC}，不应该走到这里")
    endif()

    if(NOT EXISTS "${RHINE_DXC_SOURCE_DIR}/CMakeLists.txt")
        message(FATAL_ERROR "Dxc.cmake: 找不到 DXC 源码目录 ${RHINE_DXC_SOURCE_DIR}。\n"
                            "请先初始化子模块：git submodule update --init third_party/dxc")
    endif()

    set(exe "${RHINE_DXC_OUTPUT_DIR}/dxc.exe")
    set(dxcompiler "${RHINE_DXC_OUTPUT_DIR}/dxcompiler.dll")
    set(dxil "${RHINE_DXC_OUTPUT_DIR}/dxil.dll")
    set(${out_exe}
        "${exe}"
        PARENT_SCOPE)
    set(${out_dxcompiler}
        "${dxcompiler}"
        PARENT_SCOPE)

    # Vulkan 和 DX12 两个分支都会调用本函数，第二次直接复用已经配置好的目标。
    if(TARGET rhine_dxc)
        return()
    endif()

    # Keep the host interpreter independent of Python3 selected by Qt/glslang. setup-python exports
    # pythonLocation; prefer it in both Bash and PowerShell. Otherwise search PATH consistently, without
    # application package prefixes. CI preserves the resolved bootstrap interpreter across actions that run
    # setup-python again.
    if(NOT RHINE_DXC_PYTHON_EXECUTABLE AND DEFINED ENV{RHINE_DXC_PYTHON_EXECUTABLE})
        set(RHINE_DXC_PYTHON_EXECUTABLE
            "$ENV{RHINE_DXC_PYTHON_EXECUTABLE}"
            CACHE FILEPATH "Host Python 3 interpreter used only to build DXC" FORCE)
    endif()
    find_program(
        RHINE_DXC_PYTHON_EXECUTABLE
        NAMES python3.exe python.exe python3 python NAMES_PER_DIR
        HINTS "$ENV{pythonLocation}" ENV PATH
        NO_DEFAULT_PATH
        DOC "Host Python 3 interpreter used only to build DXC")
    if(NOT RHINE_DXC_PYTHON_EXECUTABLE)
        message(FATAL_ERROR "Dxc.cmake: 从源码构建 DXC 需要 Python 3（LLVM 的 TableGen 脚本依赖它），"
                            "请将 Python 3 加入 PATH，或显式传 -DRHINE_DXC_PYTHON_EXECUTABLE=<path>")
    endif()
    execute_process(
        COMMAND "${RHINE_DXC_PYTHON_EXECUTABLE}" -c
                "import sys; sys.exit(0 if sys.version_info.major == 3 else 1)"
        RESULT_VARIABLE _rhine_dxc_python_status
        OUTPUT_QUIET ERROR_QUIET)
    if(NOT _rhine_dxc_python_status EQUAL 0)
        message(FATAL_ERROR "RHINE_DXC_PYTHON_EXECUTABLE must be a working Python 3 interpreter")
    endif()

    # DXC 的 dxc target 在 MSVC 下 find_package(DiaSDK REQUIRED)，DIA SDK 随 Visual Studio 的“C++
    # 分析/诊断工具”组件安装。在这里先查一次：否则要等几分钟的 LLVM 配置走完才在末尾报一句找不到 DiaSDK。 复用 DXC 自带的 FindDiaSDK.cmake（它会用 vswhere /
    # CMAKE_GENERATOR_INSTANCE 找）。
    set(_rhine_dxc_saved_module_path "${CMAKE_MODULE_PATH}")
    list(INSERT CMAKE_MODULE_PATH 0 "${RHINE_DXC_SOURCE_DIR}/cmake/modules")
    find_package(DiaSDK QUIET)
    set(CMAKE_MODULE_PATH "${_rhine_dxc_saved_module_path}")
    if(NOT DiaSDK_FOUND)
        message(
            FATAL_ERROR
                "Dxc.cmake: 找不到 DIA SDK（dia2.h / diaguids.lib），DXC 的 dxc 工具在 MSVC " "下必须链接它。\n"
                "请在 Visual Studio Installer 里给当前 VS 安装 " "“MSVC v143 - VS 2022 C++ x64/x86 生成工具(最新)” 与 "
                "“C++ 分析工具 / C++ Profiling Tools”（DIA SDK 随后者提供），" "然后从 Developer PowerShell 重新配置。")
    endif()

    _rhine_dxc_source_revision(_rhine_dxc_revision)

    # Host tool configuration is independent of the application configuration.
    set(_rhine_dxc_build_type "${RHINE_DXC_BUILD_TYPE}")

    # LLVM 把可执行文件写到 ${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_CFG_INTDIR}/bin： Ninja/Makefiles 下就是
    # <build>/bin，多配置生成器下是 <build>/<Config>/bin。
    if(CMAKE_CONFIGURATION_TYPES)
        set(_rhine_dxc_bin_dir "${RHINE_DXC_BUILD_DIR}/${_rhine_dxc_build_type}/bin")
    else()
        set(_rhine_dxc_bin_dir "${RHINE_DXC_BUILD_DIR}/bin")
    endif()

    # HCT.cmake 生成 DxilConstants.h 等头文件后，会拿它们与源树里的同名文件做 compare_files 校验，行尾必须逐字节一致，否则那一步直接失败（CI 里表现为一串 FAILED:
    # include/dxc/DXIL/tmp/DxilConstants.h.stamp 而没有任何编译错误）。
    #
    # 上游的判定是运行时去问 git： git config --get core.autocrlf     # 返回非零就整个跳过探测 HLSL_AUTOCRLF=On  -> 不加 --force-lf（生成
    # CRLF） HLSL_AUTOCRLF=Off -> 加 --force-lf（生成 LF） 未定义时按 Off 处理。GitHub Actions 的检出并不设置 core.autocrlf（Windows
    # runner 上通常是未设置或 false），探测因此从不生效，于是生成器按 LF 输出； 而 dxc 的 .gitattributes 是 `* text=auto`，当 autocrlf 为 true
    # 时这些文件在 磁盘上是 CRLF —— 两者对不上，校验就失败。
    #
    # 这里不猜 git 配置，直接读磁盘上被校验文件的真实行尾：生成器输出的行尾因此 与校验对象必然一致，与 autocrlf、检出方式、平台都无关。
    set(_rhine_dxc_eol_probe "${RHINE_DXC_SOURCE_DIR}/include/dxc/DXIL/DxilConstants.h")
    set(_rhine_dxc_eol_arg "-DHLSL_AUTOCRLF=OFF")
    set(_rhine_dxc_eol_name "LF")
    if(EXISTS "${_rhine_dxc_eol_probe}")
        file(READ "${_rhine_dxc_eol_probe}" _rhine_dxc_eol_hex HEX)
        string(FIND "${_rhine_dxc_eol_hex}" "0d0a" _rhine_dxc_eol_crlf)
        if(NOT _rhine_dxc_eol_crlf EQUAL -1)
            # 磁盘上是 CRLF -> 生成器也要产 CRLF -> HLSL_AUTOCRLF=ON 即“不强制 LF”。
            set(_rhine_dxc_eol_arg "-DHLSL_AUTOCRLF=ON")
            set(_rhine_dxc_eol_name "CRLF")
        endif()
    endif()
    message(STATUS "DXC: 按源树实际行尾(${_rhine_dxc_eol_name})固定生成器输出")

    # 构建配方。注意这里没有用 -C cmake/caches/PredefinedParams.cmake：那份 cache 会顺手 打开 SPIR-V、测试和文档，而我们要的正好相反。下面显式给出
    # PredefinedParams 里 DX12 必需的三项（LLVM_DEFAULT_TARGET_TRIPLE / LLVM_TARGETS_TO_BUILD=None /
    # EH+RTTI），其余全部按“只编 dxc 需要的东西”收紧。
    set(_rhine_dxc_cmake_args
        "-DCMAKE_BUILD_TYPE=${_rhine_dxc_build_type}"
        "-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
        "-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}"
        "-DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}"
        # Upstream otherwise adds /Zi and /DEBUG even for Release. Keep full optimization, but do not generate
        # unused host-tool PDBs. Explicit Debug builds retain symbols.
        "-DCMAKE_POLICY_DEFAULT_CMP0141=NEW"
        "-DCMAKE_PROJECT_INCLUDE=${_rhine_dxc_repo_root}/cmake/DxcBuildOptions.cmake"
        "-DCMAKE_JOB_POOLS=rhine_dxc_link=1"
        "-DCMAKE_JOB_POOL_LINK=rhine_dxc_link"
        "-DPython3_EXECUTABLE=${RHINE_DXC_PYTHON_EXECUTABLE}"
        # DXC 官方 cache（cmake/caches/PredefinedParams.cmake）里的核心三项， docs/BuildingAndTestingDXC.rst 明确 Windows
        # 也用同一套参数。
        "-DLLVM_DEFAULT_TARGET_TRIPLE=dxil-ms-dx"
        "-DLLVM_TARGETS_TO_BUILD=None"
        "-DLLVM_ENABLE_EH=ON"
        "-DLLVM_ENABLE_RTTI=ON"
        # 关掉所有测试。LLVM_INCLUDE_UTILS 必须和 LLVM_INCLUDE_TESTS 一起关：LLVM 的 utils/ 分支在“有测试但没 utils”时会直接 FATAL_ERROR。
        "-DLLVM_INCLUDE_TESTS=OFF"
        "-DLLVM_BUILD_TESTS=OFF"
        "-DLLVM_INCLUDE_UTILS=OFF"
        "-DLLVM_INCLUDE_EXAMPLES=OFF"
        "-DLLVM_INCLUDE_BENCHMARKS=OFF"
        "-DLLVM_INCLUDE_DOCS=OFF"
        "-DLLVM_BUILD_DOCS=OFF"
        "-DLLVM_ENABLE_SPHINX=OFF"
        "-DLLVM_ENABLE_OCAMLDOC=OFF"
        "-DLLVM_ENABLE_BINDINGS=OFF"
        "-DLLVM_ENABLE_TERMINFO=OFF"
        "-DLLVM_ENABLE_ZLIB=OFF"
        "-DLLVM_ENABLE_LIBXML2=OFF"
        "-DLLVM_ENABLE_FFI=OFF"
        "-DLLVM_ENABLE_LIBEDIT=OFF"
        "-DLLVM_ENABLE_ASSERTIONS=OFF"
        "-DLLVM_APPEND_VC_REV=OFF"
        "-DHLSL_INCLUDE_TESTS=OFF"
        "-DHLSL_BUILD_DXILCONV=OFF"
        # SPIR-V 后端要额外的 SPIRV-Headers/SPIRV-Tools 源码，DX12 用不到。
        "-DENABLE_SPIRV_CODEGEN=OFF"
        "-DSPIRV_BUILD_TESTS=OFF"
        # clang 侧只保留 HLSL 前端需要的东西。
        "-DCLANG_ENABLE_STATIC_ANALYZER=OFF"
        "-DCLANG_ENABLE_ARCMT=OFF"
        "-DCLANG_ENABLE_CLANGD=OFF"
        "-DCLANG_INCLUDE_TESTS=OFF"
        "-DLIBCLANG_BUILD_STATIC=ON"
        # 不在构建里重生成写回源树的 hctgen 产物（HlslIntrinsicOp.h、DxilConstants.h、
        # DxilInstructions.h、DxilSigPoint.inl、DxilCounters.h 等 7 个）。
        #
        # 这些文件在 dxc 仓库里本来就是「生成 + clang-format 格式化后提交」的产物， 而 HCT.cmake 每次构建都会重跑一遍 hctgen、用本机的 clang-format
        # 重新格式化， 再 compare_files 与源树里的版本逐字节比对。clang-format 不同版本对同一份 代码的排版并不完全一致（我们源树里那批是某个特定版本排的），所以只要 runner
        # 上装的 clang-format 版本不同，这 5 个校验就必然失败： FAILED: include/dxc/DXIL/tmp/DxilConstants.h.stamp 且完全没有编译错误可看。
        #
        # 我们只需要 dxc 能编出来，不需要校验这些生成的源码是否与 hctdb 同步； 跳过重生成即可，源树里的文件已经是可用版本。 注意这个开关只影响「写回源树」的那几个（HCT.cmake 里的条件是
        # `HLSL_DISABLE_SOURCE_GENERATION AND NOT ARG_BUILD_DIR`），带 BUILD_DIR 的 6 个仍会正常生成到构建目录，不会缺产物。
        "-DHLSL_DISABLE_SOURCE_GENERATION=ON"
        # 见上面的行尾探测：显式指定，避免流程依赖 git 的 core.autocrlf 探测。
        "${_rhine_dxc_eol_arg}")

    # 签名 = 源码版本 + 构建配方。配方变了（比如以后改选项）也要重建，避免拿旧产物 骗过构建；签名文件只在整个构建成功后才拷进 generated/，失败的构建不会留下标记。
    file(SHA256 "${_rhine_dxc_repo_root}/cmake/DxcBuildOptions.cmake" _rhine_dxc_options_hash)
    set(_rhine_dxc_signature_args ${_rhine_dxc_cmake_args})
    list(REMOVE_ITEM _rhine_dxc_signature_args
         "-DCMAKE_PROJECT_INCLUDE=${_rhine_dxc_repo_root}/cmake/DxcBuildOptions.cmake")
    string(SHA256 _rhine_dxc_recipe_hash
                  "${_rhine_dxc_build_type};${_rhine_dxc_signature_args};${_rhine_dxc_options_hash}")
    set(_rhine_dxc_signature "rev=${_rhine_dxc_revision}\nrecipe=${_rhine_dxc_recipe_hash}")
    set(_rhine_dxc_signature_file "${CMAKE_BINARY_DIR}/rhine-dxc-signature.txt")
    file(WRITE "${_rhine_dxc_signature_file}" "${_rhine_dxc_signature}\n")

    set(_rhine_dxc_reuse FALSE)
    if(RHINE_DXC_REUSE_BUILT
       AND NOT RHINE_DXC_FORCE_REBUILD
       AND EXISTS "${exe}"
       AND EXISTS "${dxcompiler}"
       AND EXISTS "${dxil}"
       AND EXISTS "${RHINE_DXC_REVISION_FILE}")
        file(READ "${RHINE_DXC_REVISION_FILE}" _rhine_dxc_stored)
        # 文件里带结尾换行，比较前去掉，否则永远判不等、每次都白跑一遍嵌套构建。
        string(STRIP "${_rhine_dxc_stored}" _rhine_dxc_stored)
        if(_rhine_dxc_stored STREQUAL _rhine_dxc_signature)
            set(_rhine_dxc_reuse TRUE)
        endif()
    endif()

    if(_rhine_dxc_reuse)
        # 空的自定义目标：让上层可以无条件 add_dependencies(... rhine_dxc)。
        add_custom_target(rhine_dxc)
        message(STATUS "DXC: 复用 ${RHINE_DXC_OUTPUT_DIR} 里的源码构建（rev ${_rhine_dxc_revision}）")
        return()
    endif()

    include(ExternalProject)

    # stamp 单独放：ExternalProject 靠 stamp 判断“这一步做过了”。复用失败时（产物被删、 源码换了版本、构建配方改了）必须把 stamp 清掉，否则它认为
    # configure/build/install 都已完成，什么都不会发生 —— 嵌套构建目录里的中间产物仍然保留，所以重跑是增量的。
    set(_rhine_dxc_stamp_dir "${CMAKE_BINARY_DIR}/dxc-stamps")
    file(REMOVE_RECURSE "${_rhine_dxc_stamp_dir}")

    ExternalProject_Add(
        rhine_dxc
        SOURCE_DIR "${RHINE_DXC_SOURCE_DIR}"
        BINARY_DIR "${RHINE_DXC_BUILD_DIR}"
        STAMP_DIR "${_rhine_dxc_stamp_dir}"
        CMAKE_GENERATOR "${CMAKE_GENERATOR}"
        CMAKE_ARGS ${_rhine_dxc_cmake_args}
        # 只编这三个产物：默认的“编全部”会连 opt/llvm-as 等一堆工具一起编。 目标名是 dxildll（产物名才是 dxil.dll），写错会直接报 unknown target。
        BUILD_COMMAND "${CMAKE_COMMAND}" --build "${RHINE_DXC_BUILD_DIR}" --config "${_rhine_dxc_build_type}"
                      --parallel "${RHINE_DXC_BUILD_JOBS}" --target dxc dxcompiler dxildll
        # 产物拷到 generated/dxc/bin。用 copy_if_different：重复构建不会刷新时间戳。
        INSTALL_COMMAND "${CMAKE_COMMAND}" -E make_directory "${RHINE_DXC_OUTPUT_DIR}"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_rhine_dxc_bin_dir}/dxc.exe" "${exe}"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_rhine_dxc_bin_dir}/dxcompiler.dll" "${dxcompiler}"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_rhine_dxc_bin_dir}/dxil.dll" "${dxil}"
        # 标记最后写：构建或拷贝中途失败时，下次 configure 仍然会重建。
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_rhine_dxc_signature_file}"
                "${RHINE_DXC_REVISION_FILE}"
        # 源码是 pinned 子模块，不走 git update，也不打补丁。
        UPDATE_COMMAND ""
        DOWNLOAD_COMMAND ""
        PATCH_COMMAND ""
        BUILD_BYPRODUCTS "${exe}" "${dxcompiler}" "${dxil}"
        # 配置和编译都很慢，输出直接透到终端，别让用户以为卡死了。
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        USES_TERMINAL_INSTALL TRUE)

    message(STATUS "DXC: 将从源码构建（${RHINE_DXC_SOURCE_DIR} -> ${RHINE_DXC_OUTPUT_DIR}，" "首次约需数十分钟；之后会复用）")
endfunction()
