# 实验性轻量时域
qt_add_shaders(
    RhineMusicDatabase
    "rhine_metal_temporal_shaders"
    PREFIX
    "/metalTemporal"
    BASE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    GLSL
    "130,150,300es"
    MSL
    12
    FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/resolve.vert"
    "${CMAKE_CURRENT_SOURCE_DIR}/resolve.frag"
    "${CMAKE_CURRENT_SOURCE_DIR}/present.vert"
    "${CMAKE_CURRENT_SOURCE_DIR}/present.frag")
