cmake_minimum_required(VERSION 3.22.1)
project(rhinenodehost CXX)

add_library(nodehost SHARED node_host.cpp)
find_library(log-lib log)
target_link_libraries(nodehost ${log-lib} dl android)
