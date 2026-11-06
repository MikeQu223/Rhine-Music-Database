"""导出原始 Blender 网格和 glTF PBR 参数，不改变资源内容。"""

import json
import os
import struct
import pathlib
import hashlib

root = pathlib.Path(__file__).resolve().parents[1]
# Android 用独立的一套 3D 源与产物：两个变量由 scripts/build-android.cjs 设置。
# 不设置时逐值等于原来的公共路径，桌面与 iOS 的产物完全一致。
source_directory = pathlib.Path(
    os.environ.get("RHINE_3D_SOURCE", root / "Assets/models")
)
output_directory = pathlib.Path(
    os.environ.get("RHINE_3D_OUTPUT", root / "output/resources")
)
# 副本里没有的文件（2D 字形 boot-lettering-art.json）仍取公共资源：它不属于 3D，
# 保持共享，桌面路径下三个文件本来就都从这里读。
default_config_directory = root / "Resources"
output_directory.mkdir(parents=True, exist_ok=True)
# 原始模型与材质一同导出，不改变几何、变换或光学参数。
for asset in ["archive-cassette", "archive-assembly"]:
    source_bytes = (source_directory / f"{asset}.glb").read_bytes()
    length = struct.unpack_from("<I", source_bytes, 12)[0]
    gltf = json.loads(source_bytes[20 : 20 + length])
    binary = source_bytes[28 + length :]

    def read_accessor(accessor_index):
        """按 glTF accessor 的偏移、步长和分量类型读取原始二进制数据。"""
        accessor = gltf["accessors"][accessor_index]
        buffer_view = gltf["bufferViews"][accessor["bufferView"]]
        component_format = {5126: "f", 5125: "I", 5123: "H", 5121: "B"}[
            accessor["componentType"]
        ]
        component_count = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[
            accessor["type"]
        ]
        byte_stride = buffer_view.get(
            "byteStride", struct.calcsize(component_format) * component_count
        )
        byte_offset = buffer_view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
        return [
            struct.unpack_from(
                "<" + component_format * component_count,
                binary,
                byte_offset + item_index * byte_stride,
            )
            for item_index in range(accessor["count"])
        ]

    # 顶点统一为八个分量：位置、法线、UV，与原生顶点布局的 32 字节步长一致。
    vertices = []
    index_values = []
    parts = []

    def closed_surface(positions, indices, epsilon=1e-5):
        """按位置合并顶点后统计边的共享次数：全部为 2 才是闭合流形，可安全关闭双面渲染。"""
        unique = {}
        merged = []
        for point in positions:
            key = tuple(round(value / epsilon) for value in point)
            merged.append(unique.setdefault(key, len(unique)))
        edges = {}
        for offset in range(0, len(indices), 3):
            first, second, third = (merged[indices[offset + i]] for i in range(3))
            if first == second or second == third or third == first:
                continue
            for left, right in ((first, second), (second, third), (third, first)):
                edge = (left, right) if left < right else (right, left)
                edges[edge] = edges.get(edge, 0) + 1
        # 非流形或带开放边界的部件保持双面，避免薄片单面消失。
        return bool(edges) and all(count == 2 for count in edges.values())

    for node in gltf["nodes"]:
        if "mesh" not in node:
            continue
        assert not any(
            (k in node for k in ("matrix", "rotation", "translation", "scale"))
        ), "Do not silently discard transforms"
        for primitive in gltf["meshes"][node["mesh"]]["primitives"]:
            material = gltf["materials"][primitive["material"]]
            name = material["name"].split(".")[0]
            if name in {
                "Carbon_Ink",
                # 藏在磨砂外壳之后的内部结构，经多点平均的透射采样后细节不可辨：
                # 胶片边缘齿纹约 3.6 万三角、内部陶瓷、次表面光学、光学内边框约 1.1 万、
                # 琥珀嵌件。全部剔除后模型三角数约为原始的三分之一，磨砂模糊下视觉等价。
                "Optical_Film_Edge",
                "Internal_Ceramic",
                "Subsurface_Optics",
                "Optical_Edges",
                "Amber_Optical_Inlay",
            }:
                continue
            positions = read_accessor(primitive["attributes"]["POSITION"])
            normals = read_accessor(primitive["attributes"]["NORMAL"])
            texture_coordinates = (
                read_accessor(primitive["attributes"]["TEXCOORD_0"])
                if "TEXCOORD_0" in primitive["attributes"]
                else [(0, 0)] * len(positions)
            )
            indices = read_accessor(primitive["indices"])
            index_offset = len(index_values)
            vertex_offset = len(vertices) // 8
            for i in range(len(positions)):
                vertices.extend([*positions[i], *normals[i], *texture_coordinates[i]])
            index_values.extend((vertex_offset + i[0] for i in indices))
            parts.append(
                dict(
                    name=name,
                    start=index_offset,
                    count=len(indices),
                    vertexStart=vertex_offset,
                    vertexCount=len(positions),
                    closed=closed_surface(positions, [value[0] for value in indices]),
                    material=material,
                    minimum=gltf["accessors"][primitive["attributes"]["POSITION"]][
                        "min"
                    ],
                    maximum=gltf["accessors"][primitive["attributes"]["POSITION"]][
                        "max"
                    ],
                    assemblyPart=node.get("extras", {}).get("assemblyPart", "shell"),
                )
            )
    # 原生绘制与拾取共用二进制坐标，不再生成脚本侧坐标副本。
    (output_directory / f"{asset}.bin").write_bytes(
        struct.pack("<" + "f" * len(vertices), *vertices)
    )
    (output_directory / f"{asset}-indices.bin").write_bytes(
        struct.pack("<" + "I" * len(index_values), *index_values)
    )
    (output_directory / f"{asset}.json").write_text(
        json.dumps(
            dict(sourceSHA256=hashlib.sha256(source_bytes).hexdigest(), meshes=parts),
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

for name in ["slots.json", "boot-lettering-art.json", "scene-fixture.json"]:
    candidate = source_directory / name
    source = candidate if candidate.is_file() else default_config_directory / name
    (output_directory / name).write_bytes(source.read_bytes())
print(output_directory)
