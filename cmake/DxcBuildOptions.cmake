# Applied inside the nested DXC project, before its targets and HandleLLVMOptions. Keep a nonempty generator
# expression so upstream does not force /Zi + /DEBUG into Release. CMake evaluates it per configuration when
# emitting compile flags.
set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<$<CONFIG:Debug,RelWithDebInfo>:ProgramDatabase>")
