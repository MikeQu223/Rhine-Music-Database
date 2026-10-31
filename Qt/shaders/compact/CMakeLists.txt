# E05a：无运动矢量消费者时的紧凑实例变体——不带 RHINE_SINGLE_PASS_MOTION。
#
# 只烘真正需要的两个阶段：几何顶点（不读 previousModel）与无 MRT 的片元
# （不声明第二个颜色附件）。运行期按管线选择 /optical 还是 /opticalCompact。
qt_add_shaders(
    RhineMusicDatabase
    "rhine_enhancement_compact_shaders"
    PREFIX
    "/opticalCompact"
    BASE
    "${CMAKE_CURRENT_SOURCE_DIR}/../enhancement"
    GLSL
    "130,150,300es"
    HLSL
    50
    MSL
    12
    FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/../enhancement/opticalGeometry.vert"
    "${CMAKE_CURRENT_SOURCE_DIR}/../enhancement/opticalSurfaceNoMrt.frag")
