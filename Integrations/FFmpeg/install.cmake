# SPDX-License-Identifier: LGPL-2.1-or-later
cmake_minimum_required(VERSION 3.16)
if(NOT DEFINED FFMPEG_SOURCE OR NOT EXISTS "${FFMPEG_SOURCE}/libavcodec/codec_internal.h")
    message(FATAL_ERROR "Set FFMPEG_SOURCE to an existing FFmpeg source checkout")
endif()
find_program(STHD_GIT_EXECUTABLE git REQUIRED)
set(adapter_files libavcodec/libtruehdddec.c tests/fate/libtruehdd.mak doc/libtruehdd.texi)
set(local_files libtruehdddec.c libtruehdd.mak libtruehdd.texi)
foreach(index RANGE 0 2)
    list(GET adapter_files ${index} destination)
    list(GET local_files ${index} source)
    if(EXISTS "${FFMPEG_SOURCE}/${destination}")
        file(SHA256 "${FFMPEG_SOURCE}/${destination}" destination_hash)
        file(SHA256 "${CMAKE_CURRENT_LIST_DIR}/${source}" source_hash)
        if(NOT destination_hash STREQUAL source_hash)
            message(FATAL_ERROR "Existing ${destination} differs; refusing to overwrite it")
        endif()
    endif()
endforeach()
execute_process(COMMAND "${STHD_GIT_EXECUTABLE}" -C "${FFMPEG_SOURCE}" apply --check
    "${CMAKE_CURRENT_LIST_DIR}/registration.patch" RESULT_VARIABLE patch_check
    OUTPUT_QUIET ERROR_QUIET)
if(patch_check EQUAL 0)
    execute_process(COMMAND "${STHD_GIT_EXECUTABLE}" -C "${FFMPEG_SOURCE}" apply
        "${CMAKE_CURRENT_LIST_DIR}/registration.patch" RESULT_VARIABLE patch_result)
    if(NOT patch_result EQUAL 0)
        message(FATAL_ERROR "Could not apply FFmpeg registration")
    endif()
else()
    execute_process(COMMAND "${STHD_GIT_EXECUTABLE}" -C "${FFMPEG_SOURCE}" apply
        --reverse --check "${CMAKE_CURRENT_LIST_DIR}/registration.patch"
        RESULT_VARIABLE reverse_check OUTPUT_QUIET ERROR_QUIET)
    if(NOT reverse_check EQUAL 0)
        message(FATAL_ERROR "FFmpeg registration context differs; no files were copied")
    endif()
endif()
configure_file("${CMAKE_CURRENT_LIST_DIR}/libtruehdddec.c"
    "${FFMPEG_SOURCE}/libavcodec/libtruehdddec.c" COPYONLY)
configure_file("${CMAKE_CURRENT_LIST_DIR}/libtruehdd.mak"
    "${FFMPEG_SOURCE}/tests/fate/libtruehdd.mak" COPYONLY)
configure_file("${CMAKE_CURRENT_LIST_DIR}/libtruehdd.texi"
    "${FFMPEG_SOURCE}/doc/libtruehdd.texi" COPYONLY)
message(STATUS "Independent libtruehdd registered; mlpdec.c is unchanged")
