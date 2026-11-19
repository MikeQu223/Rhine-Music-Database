#version 440

layout(std140, binding = 0) uniform BackdropBlock {
    mat4 correction;
    vec4 viewport;
    vec4 paper;
    vec4 parameters;
    vec4 palette[4];
    vec4 anchors[4];
};

layout(location = 0) out vec2 v_uv;

void main() {
    int id = gl_VertexIndex;
    vec2 p = vec2(id == 2 ? 3.0 : -1.0, id == 1 ? 3.0 : -1.0);
    gl_Position = correction * vec4(p, 0.0, 1.0);
    v_uv = vec2((p.x + 1.0) * .5, 1.0 - (p.y + 1.0) * .5);
}
