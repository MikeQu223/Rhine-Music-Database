cmake_minimum_required(VERSION 3.24)
project(RhineDxcBootstrap LANGUAGES C CXX)
# No Qt, application resources or FidelityFX permutations: stage the host compiler first.
include("${CMAKE_CURRENT_LIST_DIR}/../Dxc.cmake")
rhine_dxc_build(RHINE_BOOTSTRAP_DXC RHINE_BOOTSTRAP_DXCOMPILER)
