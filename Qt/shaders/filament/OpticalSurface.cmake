# Qt/shaders/filament/OpticalSurface.cmake
#
# Compiles the OpticalSurface material into its state variants with matc.
#   include(${CMAKE_SOURCE_DIR}/Qt/shaders/filament/OpticalSurface.cmake)
#   optical_add_surface_materials(${CMAKE_BINARY_DIR}/materials)
#
# Options:
#   OPTICAL_FILAMENT_MATC   absolute path to matc (default: <repo>/third_party/filament-dist/bin/matc)
#   OPTICAL_MATERIAL_API    "vulkan" (default) or e.g. "vulkan;opengl;metal"
#   OPTICAL_OUTPUT_ENCODE   1 (default, encode in material) / 0 (encode in composite pass)

set(OPTICAL_FILAMENT_MATC "${CMAKE_SOURCE_DIR}/third_party/filament-dist/bin/matc"
    CACHE FILEPATH "Path to the Filament matc compiler")
set(OPTICAL_MATERIAL_API "vulkan" CACHE STRING "Filament API(s) baked into the .filamat")
set(OPTICAL_OUTPUT_ENCODE "1" CACHE STRING "Bake outputColor(aces()) into the material (1) or leave it to the host (0)")

set(OPTICAL_SURFACE_MAT "${CMAKE_CURRENT_LIST_DIR}/OpticalSurface.mat")

# name | blending | depthWrite | doubleSided
set(OPTICAL_SURFACE_VARIANTS
    "opaque_depthwrite_2sided|opaque|true|true"
    "opaque_depthwrite_1sided|opaque|true|false"
    "opaque_nodepthwrite_1sided|opaque|false|false"
    "blend_alpha_depthwrite_2sided|transparent|true|true"
    "blend_alpha_nodepthwrite_2sided|transparent|false|true"
    "blend_alpha_nodepthwrite_1sided|transparent|false|false")

function(optical_add_surface_materials out_dir)
    set(_api_args "")
    foreach(_api IN LISTS OPTICAL_MATERIAL_API)
        list(APPEND _api_args -a ${_api})
    endforeach()

    # matc does not create its output directory.
    file(MAKE_DIRECTORY "${out_dir}")

    set(_outputs "")
    foreach(_entry IN LISTS OPTICAL_SURFACE_VARIANTS)
        string(REPLACE "|" ";" _f "${_entry}")
        list(GET _f 0 _name)
        list(GET _f 1 _blend)
        list(GET _f 2 _depth_write)
        list(GET _f 3 _double_sided)

        set(_out "${out_dir}/OpticalSurface_${_name}.filamat")
        add_custom_command(
            OUTPUT  "${_out}"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${out_dir}"
            COMMAND "${OPTICAL_FILAMENT_MATC}" ${_api_args} -p desktop
                    -DOPTICAL_OUTPUT_ENCODE=${OPTICAL_OUTPUT_ENCODE}
                    -Pblending=${_blend}
                    -PdepthWrite=${_depth_write}
                    -PdoubleSided=${_double_sided}
                    -o "${_out}"
                    "${OPTICAL_SURFACE_MAT}"
            MAIN_DEPENDENCY "${OPTICAL_SURFACE_MAT}"
            COMMENT "matc: OpticalSurface_${_name}.filamat"
            VERBATIM)
        list(APPEND _outputs "${_out}")
    endforeach()

    add_custom_target(optical_surface_materials ALL DEPENDS ${_outputs})
    set(OPTICAL_SURFACE_MATERIAL_FILES ${_outputs} PARENT_SCOPE)
endfunction()
