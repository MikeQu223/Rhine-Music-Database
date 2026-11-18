# 其他平台只编译空实现，不下载、不编译 Crashpad。
target_sources(RhineMusicDatabase
               PRIVATE "${CMAKE_SOURCE_DIR}/Qt/src/CrashDiagnostics.cpp"
                       "${CMAKE_SOURCE_DIR}/Qt/src/CrashDiagnostics.h")
if(NOT (WIN32 OR (APPLE AND NOT IOS)))
    return()
endif()

set(RHINE_CRASHPAD_SOURCE_DIR
    "${CMAKE_SOURCE_DIR}/output/crashpad-source"
    CACHE PATH "Pinned Crashpad source prepared by scripts/prepare-crash-tools.cjs")
file(READ "${CMAKE_SOURCE_DIR}/scripts/crash-tools.json" RHINE_CRASH_MANIFEST)
string(JSON RHINE_CRASHPAD_REVISION GET "${RHINE_CRASH_MANIFEST}" crashpadRevision)
execute_process(
    COMMAND "${GIT_EXECUTABLE}" -C "${RHINE_CRASHPAD_SOURCE_DIR}" rev-parse HEAD
    OUTPUT_VARIABLE RHINE_CRASHPAD_ACTUAL_REVISION
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT RHINE_CRASHPAD_ACTUAL_REVISION STREQUAL RHINE_CRASHPAD_REVISION)
    message(FATAL_ERROR "Run node scripts/prepare-crash-tools.cjs to prepare pinned Crashpad dependencies")
endif()
# 提交号相同不代表子模块已拉全；中断的 clone 也会让后续 add_subdirectory 报难懂的错。
foreach(required "${RHINE_CRASHPAD_SOURCE_DIR}/CMakeLists.txt"
                 "${RHINE_CRASHPAD_SOURCE_DIR}/third_party/mini_chromium/mini_chromium/BUILD.gn"
                 "${RHINE_CRASHPAD_SOURCE_DIR}/third_party/zlib/zlib/CMakeLists.txt")
    if(NOT EXISTS "${required}")
        message(FATAL_ERROR "Run node scripts/prepare-crash-tools.cjs to prepare pinned Crashpad dependencies")
    endif()
endforeach()
set(CRASHPAD_ENABLE_INSTALL
    OFF
    CACHE BOOL "" FORCE)
set(CRASHPAD_ENABLE_INSTALL_DEV
    OFF
    CACHE BOOL "" FORCE)
set(CRASHPAD_BUILD_TOOLS
    OFF
    CACHE BOOL "" FORCE)
set(CMAKE_AUTOMOC OFF)
add_subdirectory("${RHINE_CRASHPAD_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/crashpad" EXCLUDE_FROM_ALL)
set(CMAKE_AUTOMOC ON)

target_compile_definitions(RhineMusicDatabase PRIVATE RHINE_CRASHPAD=1)
target_link_libraries(RhineMusicDatabase PRIVATE crashpad_client)
target_include_directories(RhineMusicDatabase PRIVATE "${CMAKE_BINARY_DIR}")

add_executable(RhineCrashReporter "${CMAKE_SOURCE_DIR}/Qt/src/CrashReportWorker.cpp")
target_link_libraries(RhineCrashReporter PRIVATE Qt6::Core crashpad_client crashpad_snapshot)
set_target_properties(RhineCrashReporter PROPERTIES AUTOMOC OFF RUNTIME_OUTPUT_DIRECTORY
                                                                "${CMAKE_BINARY_DIR}")
if(APPLE)
    set_target_properties(RhineCrashReporter PROPERTIES BUILD_RPATH "@executable_path/../Frameworks")
endif()
if(MSVC)
    target_compile_options(RhineCrashReporter PRIVATE /utf-8)
    target_compile_definitions(RhineMusicDatabase PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_compile_definitions(RhineCrashReporter PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# 保持 Release 优化，仅为自维护代码增加独立调试信息；构建后生成可离线解析的符号库。
foreach(target RhineMusicDatabase RhineCore RhinePlaybackCore crashpad_client)
    if(MSVC)
        target_compile_options(${target} PRIVATE /Zi)
    else()
        target_compile_options(${target} PRIVATE -g -fno-omit-frame-pointer)
    endif()
endforeach()
if(MSVC)
    target_link_options(RhineMusicDatabase PRIVATE /DEBUG:FULL /OPT:REF /OPT:ICF)
    set(RHINE_CRASH_PDB "$<TARGET_PDB_FILE:RhineMusicDatabase>")
else()
    # 保留 LTO 临时对象直到 dsymutil 提取完成，避免优化链接丢失源码行信息。
    target_link_options(RhineMusicDatabase PRIVATE
                        "LINKER:-object_path_lto,${CMAKE_BINARY_DIR}/rhine-crash-symbols-lto.o")
    set(RHINE_CRASH_PDB "")
endif()
find_program(RHINE_CRASH_NODE NAMES node node.exe)
if(NOT RHINE_CRASH_NODE AND DEFINED ENV{RHINE_NODE_BINARY})
    set(RHINE_CRASH_NODE "$ENV{RHINE_NODE_BINARY}")
endif()
add_dependencies(RhineMusicDatabase crashpad_handler RhineCrashReporter)
set(RHINE_CRASH_WER "")
if(WIN32)
    add_dependencies(RhineMusicDatabase crashpad_wer)
    set(RHINE_CRASH_WER "$<TARGET_FILE:crashpad_wer>")
endif()
# 符号生成放在独立目标里，由打包流程显式调用；普通编译不因缺少 Node 而失败。
if(RHINE_CRASH_NODE AND EXISTS "${RHINE_CRASH_NODE}")
    add_custom_target(
        RhineCrashSymbols
        COMMAND
            "${RHINE_CRASH_NODE}" "${CMAKE_SOURCE_DIR}/scripts/package-crash-tools.cjs"
            "$<TARGET_FILE:RhineMusicDatabase>" "$<TARGET_FILE:crashpad_handler>"
            "$<TARGET_FILE:RhineCrashReporter>" "${RHINE_CRASHPAD_SOURCE_DIR}" "${RHINE_CRASH_PDB}"
            "${RHINE_CRASH_WER}"
        DEPENDS RhineMusicDatabase RhineCrashReporter crashpad_handler
        COMMENT "Generating Crashpad symbols and helper binaries"
        VERBATIM)
else()
    add_custom_target(
        RhineCrashSymbols
        COMMAND "${CMAKE_COMMAND}" -E echo "RhineCrashSymbols requires Node."
                "Set RHINE_NODE_BINARY or pass -DRHINE_CRASH_NODE."
        COMMAND "${CMAKE_COMMAND}" -E false
        COMMENT "RhineCrashSymbols unavailable")
endif()
