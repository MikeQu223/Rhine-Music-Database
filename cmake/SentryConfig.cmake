include_guard()

option(RHINE_ENABLE_SENTRY "Build the official Sentry SDK on supported platforms" ON)
set(RHINE_SENTRY_DSN "" CACHE STRING "Default Sentry DSN (empty disables production reporting)")
set(RHINE_SENTRY_ENVIRONMENT "" CACHE STRING "Default Sentry environment")

if(RHINE_ENABLE_SENTRY)
    # 每次配置都读取输入，避免本地 DSN 写入缓存后影响后续构建。
    set(localDsnFile "${CMAKE_CURRENT_LIST_DIR}/../.sentry-dsn")
    foreach(setting RHINE_SENTRY_DSN RHINE_SENTRY_ENVIRONMENT)
        if(DEFINED ENV{${setting}})
            set(${setting} "$ENV{${setting}}")
        elseif(setting STREQUAL "RHINE_SENTRY_DSN" AND RHINE_SENTRY_DSN STREQUAL ""
               AND EXISTS "${localDsnFile}")
            file(READ "${localDsnFile}" RHINE_SENTRY_DSN)
            string(STRIP "${RHINE_SENTRY_DSN}" RHINE_SENTRY_DSN)
        endif()
        string(REPLACE "\\" "\\\\" ${setting}_LITERAL "${${setting}}")
        string(REPLACE "\"" "\\\"" ${setting}_LITERAL "${${setting}_LITERAL}")
        if("${${setting}_LITERAL}" MATCHES "[\r\n]")
            message(FATAL_ERROR "${setting} must be a single line")
        endif()
    endforeach()
    set(RHINE_SENTRY_CONFIG_DIR "${CMAKE_BINARY_DIR}/sentry-config")
    configure_file("${CMAKE_CURRENT_LIST_DIR}/SentryBuildConfig.h.in"
                   "${RHINE_SENTRY_CONFIG_DIR}/SentryBuildConfig.h" @ONLY)
endif()
