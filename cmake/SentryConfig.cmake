include_guard()

option(RHINE_ENABLE_SENTRY "Build the official Sentry SDK on supported platforms" ON)
set(RHINE_SENTRY_DSN "" CACHE STRING "Default Sentry DSN (empty disables production reporting)")
set(RHINE_SENTRY_ENVIRONMENT "" CACHE STRING "Default Sentry environment")

if(RHINE_ENABLE_SENTRY)
    # 发布构建通过环境变量注入。读取每次配置的值，以免复用构建目录时保留上一次的 DSN。
    foreach(setting RHINE_SENTRY_DSN RHINE_SENTRY_ENVIRONMENT)
        if(DEFINED ENV{${setting}})
            set(${setting} "$ENV{${setting}}")
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
