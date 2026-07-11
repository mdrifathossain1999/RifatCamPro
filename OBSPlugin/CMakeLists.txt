cmake_minimum_required(VERSION 3.16)
project(rifatcam_source VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)

FetchContent_Declare(
    stb
    GIT_REPOSITORY https://github.com/nothings/stb.git
    GIT_TAG master
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(stb)

find_package(libobs REQUIRED)

add_library(rifatcam_source MODULE
    plugin-main.cpp
    rifatcam_source.cpp
    stb_image_impl.cpp
)

target_include_directories(rifatcam_source PRIVATE
    ${stb_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(rifatcam_source PRIVATE OBS::libobs)

if(WIN32)
    target_link_libraries(rifatcam_source PRIVATE ws2_32)
    set_target_properties(rifatcam_source PROPERTIES
        PREFIX ""
        OUTPUT_NAME "rifatcam-source"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    )
    install(TARGETS rifatcam_source RUNTIME DESTINATION bin/64bit)
elseif(APPLE)
    set_target_properties(rifatcam_source PROPERTIES
        PREFIX ""
        SUFFIX ".so"
        OUTPUT_NAME "rifatcam-source"
    )
    install(TARGETS rifatcam_source LIBRARY DESTINATION lib/obs-plugins)
else()
    set_target_properties(rifatcam_source PROPERTIES
        PREFIX ""
        OUTPUT_NAME "rifatcam-source"
    )
    install(TARGETS rifatcam_source LIBRARY DESTINATION lib/obs-plugins)
endif()
