cmake_minimum_required(VERSION 3.12)
project(hwr_driver C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(MSVC)
    add_compile_options(/O2 /W3)
else()
    add_compile_options(-O3 -Wall -Wextra)
endif()

# Shared library for runtime ctypes / dlopen / Android JNI
add_library(hwr_driver SHARED
    hwr_driver.c
    hwr_driver.h
    hwr_data.h
)
target_compile_definitions(hwr_driver PRIVATE HWR_BUILD_DLL)

# Standalone CLI / IPC Harness executable
add_executable(hwr_driver_cli
    hwr_driver.c
    hwr_cli.c
    hwr_driver.h
    hwr_data.h
)
target_compile_definitions(hwr_driver_cli PRIVATE HWR_STATIC)
set_target_properties(hwr_driver_cli PROPERTIES OUTPUT_NAME "hwr_driver")
