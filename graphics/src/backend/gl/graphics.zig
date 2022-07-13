const std = @import("std");
const stdx = @import("stdx");
const Transform = stdx.math.Transform;
const gl = @import("gl");

const graphics = @import("../../graphics.zig");
const gpu = graphics.gpu;
pub const SwapChain = @import("swapchain.zig").SwapChain;
pub const Shader = @import("shader.zig").Shader;
pub const shaders = @import("shaders.zig");
pub const Renderer = @import("renderer.zig").Renderer;
const TexShaderVertex = gpu.TexShaderVertex;
const log = stdx.log.scoped(.gl_graphics);

pub const Pipelines = struct {
    tex: shaders.TexShader,
    gradient: shaders.GradientShader,
    plane: shaders.PlaneShader,

    pub fn deinit(self: Pipelines) void {
        self.tex.deinit();
        self.gradient.deinit();
        self.plane.deinit();
    }
};

pub const Graphics = struct {
    renderer: Renderer,
    gpu_ctx: *gpu.Graphics,

    pub fn init(self: *Graphics, alloc: std.mem.Allocator) !void {
        self.* = .{
            .gpu_ctx = undefined,
            .renderer = undefined,
        };
        try self.renderer.init(alloc);
    }

    pub fn deinit(self: Graphics, alloc: std.mem.Allocator) void {
        self.renderer.deinit(alloc);
    }

    /// Points of front face is in ccw order.
    pub fn fillTriangle3D(self: *Graphics, x1: f32, y1: f32, z1: f32, x2: f32, y2: f32, z2: f32, x3: f32, y3: f32, z3: f32) void {
        self.gpu_ctx.batcher.endCmd();
        self.renderer.ensureUnusedBuffer(3, 3);

        var vert: TexShaderVertex = undefined;
        vert.setColor(self.gpu_ctx.cur_fill_color);
        vert.setUV(0, 0); // Don't map uvs for now.

        const start_idx = self.renderer.getCurrentIndexId();
        vert.setXYZ(x1, y1, z1);
        self.renderer.pushVertex(vert);
        vert.setXYZ(x2, y2, z2);
        self.renderer.pushVertex(vert);
        vert.setXYZ(x3, y3, z3);
        self.renderer.pushVertex(vert);
        self.renderer.mesh.addTriangle(start_idx, start_idx + 1, start_idx + 2);

        const vp = self.gpu_ctx.view_transform.getAppliedTransform(self.gpu_ctx.cur_proj_transform);
        self.renderer.pushTex3D(vp.mat, self.gpu_ctx.white_tex.tex_id);
    }

    pub fn fillScene3D(self: *Graphics, xform: Transform, scene: graphics.GLTFscene) void {
        for (scene.mesh_nodes) |id| {
            const node = scene.nodes[id];
            for (node.primitives) |prim| {
                self.fillMesh3D(xform, prim);
            }
        }
    }

    pub fn fillMesh3D(self: *Graphics, xform: Transform, mesh: graphics.Mesh3D) void {
        self.gpu_ctx.batcher.endCmd();
        const vp = self.gpu_ctx.view_transform.getAppliedTransform(self.gpu_ctx.cur_proj_transform);
        const mvp = xform.getAppliedTransform(vp);

        self.renderer.ensureUnusedBuffer(mesh.verts.len, mesh.indexes.len);
        const vert_start = self.renderer.getCurrentIndexId();
        for (mesh.verts) |vert| {
            var new_vert = vert;
            new_vert.setColor(self.gpu_ctx.cur_fill_color);
            self.renderer.pushVertex(new_vert);
        }
        self.renderer.pushDeltaIndices(vert_start, mesh.indexes);
        self.renderer.pushTex3D(mvp.mat, self.gpu_ctx.white_tex.tex_id);
    }
};

pub fn initImage(image: *gpu.Image, width: usize, height: usize, data: ?[]const u8, linear_filter: bool) void {
    image.* = .{
        .tex_id = undefined,
        .width = width,
        .height = height,
        .inner = undefined,
        .remove = false,
    };

    gl.genTextures(1, &image.tex_id);
    gl.activeTexture(gl.GL_TEXTURE0 + 0);
    gl.bindTexture(gl.GL_TEXTURE_2D, image.tex_id);

    // A GLint specifying the level of detail. Level 0 is the base image level and level n is the nth mipmap reduction level.
    const level = 0;
    // A GLint specifying the width of the border. Usually 0.
    const border = 0;
    // Data type of the texel data.
    const data_type = gl.GL_UNSIGNED_BYTE;

    // Set the filtering so we don't need mips.
    // TEXTURE_MIN_FILTER - filter for scaled down texture
    // TEXTURE_MAG_FILTER - filter for scaled up texture
    // Linear filter is better for anti-aliased font bitmaps.
    gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, if (linear_filter) gl.GL_LINEAR else gl.GL_NEAREST);
    gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, if (linear_filter) gl.GL_LINEAR else gl.GL_NEAREST);
    gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.texParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    const data_ptr = if (data != null) data.?.ptr else null;
    gl.texImage2D(gl.GL_TEXTURE_2D, level, gl.GL_RGBA8, @intCast(c_int, width), @intCast(c_int, height), border, gl.GL_RGBA, data_type, data_ptr);

    gl.bindTexture(gl.GL_TEXTURE_2D, 0);
}