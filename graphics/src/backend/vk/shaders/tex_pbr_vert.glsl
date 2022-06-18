#version 450
#pragma shader_stage(vertex)

// layout(binding = 0) uniform ModelViewProj {
//     mat4 mat;
// } u_mvp;

layout(push_constant) uniform VertConstants {
    mat4 mvp;
    mat3 normal;
    uint material_idx;
} u_const;

struct Material {
    float emissivity;
    float roughness;
    float reflectivity;
    float metallic;
};

layout(set = 2, binding = 2) readonly buffer Materials {
	Material mats[];
};

layout(location = 0) in vec4 a_pos;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec2 a_uv;
layout(location = 3) in vec4 a_color;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;
layout(location = 2) out vec3 v_normal;
layout(location = 3) out vec3 v_pos;
layout(location = 4) out float v_emissivity;
layout(location = 5) out float v_roughness;
layout(location = 6) out float v_reflectivity;
layout(location = 7) out float v_metallic;

void main()
{
    v_uv = a_uv;
    v_color = a_color;
    v_normal = normalize(a_normal * u_const.normal);
    v_pos = a_pos.xyz;
    Material mat = mats[u_const.material_idx];
    v_emissivity = mat.emissivity;
    v_roughness = mat.roughness;
    v_reflectivity = mat.reflectivity;
    v_metallic = mat.metallic;
    gl_Position = a_pos * u_const.mvp;
}