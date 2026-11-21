# Download a prebuilt ONNX Runtime (the official NuGet package) when it is not installed locally.
# On success sets ONNXRUNTIME_ROOT (and DRIFT_ONNXRUNTIME_FETCHED).
#
# Only the CPU package is ever fetched, and only two things are taken from it: the headers Drift
# compiles against, and — when DRIFT_BUNDLE_ONNXRUNTIME is on — a runtime for the build tree to
# load so a dev build works before any addon is installed. The library is never linked; which
# runtime the shipped app uses is the user's runtime choice, not a configure-time one
# (src/engine/OrtRuntime.cpp).

if(DRIFT_ONNXRUNTIME_FETCHED)
    return()
endif()

set(_onnxruntime_version "1.27.0")

if(ANDROID)
    # Only the headers are ever used here — the app links no ONNX Runtime at all and dlopens one at
    # startup (src/engine/OrtRuntime.cpp), which on Android arrives as an Acceleration addon. The
    # C and C++ API headers are identical across platforms and architectures, so the package's
    # headers serve as they are; nothing from its lib/ directory is linked or staged
    # (drift_bundle_onnxruntime is skipped on Android, and scripts/build.sh passes
    # DRIFT_BUNDLE_ONNXRUNTIME=OFF). Using the official android AAR instead would mean unzipping a
    # second archive format to obtain byte-identical headers.
    set(_onnxruntime_rid "linux-x64")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|ARM64")
        set(_onnxruntime_rid "linux-arm64")
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
        set(_onnxruntime_rid "linux-x64")
    endif()
elseif(APPLE)
    # Upstream stopped publishing an osx-x86_64 (and universal2) release; 1.27.0 ships arm64 only.
    # An Intel Mac used to fall through to the FATAL_ERROR below and could not configure at all.
    # The headers are identical across platforms and architectures — the same reason the Android
    # branch above takes them as they are — so the arm64 runtime folder is a valid
    # source for them here too. Its dylib is not: bundling is forced off rather than stage an
    # arm64 runtime an x86_64 process would fail to dlopen with no explanation.
    set(_onnxruntime_rid "osx-arm64")
    if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64|ARM64")
        if(DRIFT_BUNDLE_ONNXRUNTIME)
            message(STATUS
                "ONNX Runtime publishes no x86_64 macOS build; taking headers from the arm64 "
                "release and disabling DRIFT_BUNDLE_ONNXRUNTIME. Install an Acceleration addon, "
                "or point DRIFT_ONNXRUNTIME_DIR at an x86_64 runtime.")
        endif()
        set(DRIFT_BUNDLE_ONNXRUNTIME OFF CACHE BOOL
            "Stage a CPU ONNX Runtime into the build tree for development" FORCE)
    endif()
elseif(WIN32)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|aarch64")
        set(_onnxruntime_rid "win-arm64")
    else()
        set(_onnxruntime_rid "win-x64")
    endif()
endif()

if(NOT _onnxruntime_rid)
    message(FATAL_ERROR
        "Automatic ONNX Runtime download is not supported for "
        "${CMAKE_SYSTEM_NAME}/${CMAKE_SYSTEM_PROCESSOR}. "
        "Install ONNX Runtime manually and set ONNXRUNTIME_ROOT.")
endif()

# The source is the official NuGet package, not the GitHub release tarballs: on 2026-11-21 every
# https://github.com/microsoft/onnxruntime/releases/download/... URL answered 404 (the repository itself
# no longer resolved), and CI failed at configure on feature/motion since 2026-11-17. One .nupkg carries
# the headers (build/native/include) and every platform's runtime (runtimes/<rid>/native); it is
# repacked here into the include/ + lib/ layout FindOnnxRuntime.cmake reads.
set(_onnxruntime_nupkg "microsoft.ml.onnxruntime.${_onnxruntime_version}.nupkg")
set(_onnxruntime_sha256 "c725e8cefdfe4de08befb9f79b3f218c162439cdcdb97cbbb5192888d58ea669")
set(_onnxruntime_url
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${_onnxruntime_version}/${_onnxruntime_nupkg}")

set(_onnxruntime_staging "${CMAKE_BINARY_DIR}/_deps/onnxruntime/cpu")
set(_onnxruntime_prefix "${_onnxruntime_staging}/onnxruntime-${_onnxruntime_rid}-${_onnxruntime_version}")

if(NOT EXISTS "${_onnxruntime_prefix}/include/onnxruntime_cxx_api.h")
    file(MAKE_DIRECTORY "${_onnxruntime_staging}")
    set(_onnxruntime_archive_path "${_onnxruntime_staging}/${_onnxruntime_nupkg}")
    if(NOT EXISTS "${_onnxruntime_archive_path}")
        message(STATUS "Downloading ONNX Runtime ${_onnxruntime_version}: ${_onnxruntime_url}")
        file(DOWNLOAD "${_onnxruntime_url}" "${_onnxruntime_archive_path}"
            EXPECTED_HASH SHA256=${_onnxruntime_sha256}
            STATUS _onnxruntime_download_status)
        list(GET _onnxruntime_download_status 0 _onnxruntime_download_code)
        if(NOT _onnxruntime_download_code EQUAL 0)
            file(REMOVE "${_onnxruntime_archive_path}")
            message(FATAL_ERROR "ONNX Runtime download failed: ${_onnxruntime_download_status}")
        endif()
    endif()

    set(_onnxruntime_unpacked "${_onnxruntime_staging}/nupkg-${_onnxruntime_version}")
    file(REMOVE_RECURSE "${_onnxruntime_unpacked}")
    file(ARCHIVE_EXTRACT
        INPUT "${_onnxruntime_archive_path}"
        DESTINATION "${_onnxruntime_unpacked}"
        PATTERNS "build/native/include/*" "runtimes/${_onnxruntime_rid}/native/*")

    file(REMOVE_RECURSE "${_onnxruntime_prefix}")
    file(MAKE_DIRECTORY "${_onnxruntime_prefix}/include" "${_onnxruntime_prefix}/lib")
    file(GLOB _onnxruntime_headers "${_onnxruntime_unpacked}/build/native/include/*")
    file(GLOB _onnxruntime_libs "${_onnxruntime_unpacked}/runtimes/${_onnxruntime_rid}/native/*")
    file(COPY ${_onnxruntime_headers} DESTINATION "${_onnxruntime_prefix}/include")
    if(_onnxruntime_libs)
        file(COPY ${_onnxruntime_libs} DESTINATION "${_onnxruntime_prefix}/lib")
    endif()
    file(REMOVE_RECURSE "${_onnxruntime_unpacked}")
endif()

if(NOT EXISTS "${_onnxruntime_prefix}/include/onnxruntime_cxx_api.h")
    message(FATAL_ERROR
        "Failed to extract ONNX Runtime from ${_onnxruntime_nupkg}")
endif()

# find_path caches its result, so a build tree configured against a previous prefix would keep
# resolving to it.
unset(OnnxRuntime_INCLUDE_DIR CACHE)

set(ONNXRUNTIME_ROOT "${_onnxruntime_prefix}" CACHE PATH
    "ONNX Runtime install prefix (auto-downloaded)" FORCE)
set(OnnxRuntime_ROOT "${_onnxruntime_prefix}" CACHE PATH
    "ONNX Runtime install prefix (auto-downloaded)" FORCE)
set(DRIFT_ONNXRUNTIME_VERSION "${_onnxruntime_version}" CACHE STRING
    "Version of the fetched ONNX Runtime" FORCE)
set(DRIFT_ONNXRUNTIME_FETCHED TRUE)
message(STATUS "ONNX Runtime ${_onnxruntime_version} headers ready at ${ONNXRUNTIME_ROOT}")
