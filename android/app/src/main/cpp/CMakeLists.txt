cmake_minimum_required(VERSION 3.10.2)
project("hwr_driver")

add_library(hwr_driver SHARED
    hwr_driver.c
    hwr_jni.c
)

target_include_directories(hwr_driver PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

find_library(log-lib log)
target_link_libraries(hwr_driver ${log-lib})
