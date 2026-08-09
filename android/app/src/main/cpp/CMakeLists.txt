# Native layer: whisper.cpp built from the repo submodule (android/third_party).
#
# One platform assumption, mirroring the desktop rule "one per module":
# CPU-only inference (GGML_USE_CPU). GPU delegates on Android (Vulkan/OpenCL)
# are a per-vendor minefield; whisper tiny/base/small are CPU-realtime enough.
cmake_minimum_required(VERSION 3.22)
project(voiceflow_native)

set(CMAKE_CXX_STANDARD 17)
set(WHISPER_LIB_DIR ${CMAKE_SOURCE_DIR}/../../../../third_party/whisper.cpp)

# whisper.cpp expects its version injected by the build system.
file(READ "${WHISPER_LIB_DIR}/CMakeLists.txt" MAIN_CMAKE_CONTENT)
string(REGEX MATCH "project\\(\"whisper\\.cpp\" VERSION ([0-9]+\\.[0-9]+\\.[0-9]+)\\)" _ "${MAIN_CMAKE_CONTENT}")
if(CMAKE_MATCH_1)
    set(WHISPER_VERSION ${CMAKE_MATCH_1})
else()
    set(WHISPER_VERSION "unknown")
endif()

find_library(LOG_LIB log)

include(FetchContent)

set(SOURCE_FILES
    ${WHISPER_LIB_DIR}/src/whisper.cpp
    ${CMAKE_SOURCE_DIR}/jni.c
)

function(build_library target_name)
    add_library(${target_name} SHARED ${SOURCE_FILES})

    target_compile_definitions(${target_name} PUBLIC GGML_USE_CPU)
    target_compile_definitions(${target_name} PRIVATE WHISPER_VERSION="${WHISPER_VERSION}")

    if (${target_name} STREQUAL "voiceflow_v8fp16_va")
        target_compile_options(${target_name} PRIVATE -march=armv8.2-a+fp16)
        set(GGML_COMPILE_OPTIONS -march=armv8.2-a+fp16)
    endif ()

    if (NOT ${CMAKE_BUILD_TYPE} STREQUAL "Debug")
        target_compile_options(${target_name} PRIVATE -O3
            -fvisibility=hidden -fvisibility-inlines-hidden
            -ffunction-sections -fdata-sections)
        target_link_options(${target_name} PRIVATE
            -Wl,--gc-sections -Wl,--exclude-libs,ALL -flto)
    endif ()

    FetchContent_Declare(ggml SOURCE_DIR ${WHISPER_LIB_DIR}/ggml)
    FetchContent_MakeAvailable(ggml)
    if (GGML_COMPILE_OPTIONS)
        target_compile_options(ggml PRIVATE ${GGML_COMPILE_OPTIONS})
    endif ()
    target_link_libraries(${target_name} ${LOG_LIB} android ggml)
endfunction()

# arm64 devices with fp16 vector arithmetic get a faster build; the plain
# "voiceflow" target is what x86_64 emulators and older devices load.
if (${ANDROID_ABI} STREQUAL "arm64-v8a")
    build_library("voiceflow_v8fp16_va")
endif ()
build_library("voiceflow")

include_directories(${WHISPER_LIB_DIR})
include_directories(${WHISPER_LIB_DIR}/src)
include_directories(${WHISPER_LIB_DIR}/include)
include_directories(${WHISPER_LIB_DIR}/ggml/include)
include_directories(${WHISPER_LIB_DIR}/ggml/src)
include_directories(${WHISPER_LIB_DIR}/ggml/src/ggml-cpu)
