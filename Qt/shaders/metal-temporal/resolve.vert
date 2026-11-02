#version 440
layout(location = 0) out vec2 v_uv;
void main() {
    vec2 position = vec2(gl_VertexIndex == 2 ? 3 : -1, gl_VertexIndex == 1 ? 3 : -1);
    gl_Position = vec4(position, 0, 1);
    v_uv = vec2(position.x + 1, 1 - position.y) * 0.5;
}
