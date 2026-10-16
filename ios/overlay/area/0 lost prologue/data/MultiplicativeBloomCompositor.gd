class_name MultiplicativeBloomCompositor
extends CompositorEffect

const BLUR_SHADER_SOURCE := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_tex;
layout(rgba8, set = 0, binding = 1) uniform restrict writeonly image2D target_image;

layout(push_constant, std430) uniform Params {
    vec2  texel_size;
    float strength;
    int   width;
    int   height;
    int   direction;
    float _pad0;
    float _pad1;
} p;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= p.width || coord.y >= p.height) return;

    vec2 uv  = (vec2(coord) + 0.5) * p.texel_size;
    vec2 dir = (p.direction == 0) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec2 step_uv = p.texel_size * p.strength * dir;

    const float W[7] = float[](
        0.015625, 0.09375, 0.234375, 0.3125,
        0.234375, 0.09375, 0.015625
    );

    vec4 result = vec4(0.0);
    for (int i = -3; i <= 3; i++) {
        result += W[i + 3] * texture(source_tex, uv + step_uv * float(i));
    }

    imageStore(target_image, coord, result);
}
""";

const COMPOSITE_SHADER_SOURCE := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D blurred_bloom;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D blurred_mask;

layout(push_constant, std430) uniform Params {
    vec2  texel_size;
    int   width;
    int   height;
    float effect_threshold;
    float foreground_threshold;
    float foreground_edge_start;
    float _pad;
} p;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= p.width || coord.y >= p.height) return;

    vec2 uv = (vec2(coord) + 0.5) * p.texel_size;

    float fg = texture(blurred_mask, uv).a;

    float bloom_amount = 1.0 - smoothstep(p.foreground_edge_start, p.foreground_threshold, fg);
    if (bloom_amount < 0.001) return;

    vec3 bloom = texture(blurred_bloom, uv).rgb;
    float darkness = 1.0 - dot(bloom, vec3(0.333));
    if (darkness < p.effect_threshold) return;

    vec4 main_col = imageLoad(color_image, coord);
    vec3 result   = mix(main_col.rgb, main_col.rgb * bloom, bloom_amount);
    imageStore(color_image, coord, vec4(result, main_col.a));
}
""";

# The Mobile renderer (iOS) can't bind its color buffer as a storage image, so
# there the composite is a fullscreen draw instead: the fragment outputs the
# factor the compute shader multiplies by, and the pipeline blends
# dst * src into the color buffer. 1.0 leaves a pixel unchanged.
const COMPOSITE_RASTER_VERTEX_SOURCE := """
#version 450

void main() {
    vec2 base = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(base * 2.0 - 1.0, 0.0, 1.0);
}
""";

const COMPOSITE_RASTER_FRAGMENT_SOURCE := """
#version 450

layout(set = 0, binding = 0) uniform sampler2D blurred_bloom;
layout(set = 0, binding = 1) uniform sampler2D blurred_mask;

layout(push_constant, std430) uniform Params {
    vec2  texel_size;
    float effect_threshold;
    float foreground_threshold;
    float foreground_edge_start;
    float _pad0;
    float _pad1;
    float _pad2;
} p;

layout(location = 0) out vec4 frag_color;

void main() {
    vec2 uv = gl_FragCoord.xy * p.texel_size;
    frag_color = vec4(1.0);

    float fg = texture(blurred_mask, uv).a;

    float bloom_amount = 1.0 - smoothstep(p.foreground_edge_start, p.foreground_threshold, fg);
    if (bloom_amount < 0.001) return;

    vec3 bloom = texture(blurred_bloom, uv).rgb;
    float darkness = 1.0 - dot(bloom, vec3(0.333));
    if (darkness < p.effect_threshold) return;

    frag_color = vec4(mix(vec3(1.0), bloom, bloom_amount), 1.0);
}
""";

@export var strength: float = 1.5
@export var mask_blur_strength: float = 1.0
@export var effect_threshold: float = 0.01
@export var foreground_threshold: float = 1.3
@export var foreground_edge_start: float = 0.5

var bloom_texture_rid: RID = RID()
var foreground_mask_rid: RID = RID()
var bloom_size := Vector2i(0, 0)
var mask_size  := Vector2i(0, 0)

var rd: RenderingDevice
var blur_shader_rid: RID = RID()
var blur_pipeline: RID = RID()
var composite_shader_rid: RID = RID()
var composite_pipeline: RID = RID()
var sampler_rid: RID = RID()

var raster_shader_rid: RID = RID()
var raster_pipeline: RID = RID()
var raster_pipeline_format: int = RenderingDevice.INVALID_FORMAT_ID
var storage_support := {}  # color buffer RID -> whether it can be a storage image
var force_raster := OS.get_environment("PR_BLOOM_RASTER") == "1"  # Compare both paths on one renderer

var blur_temp_a_rid: RID = RID()
var blur_temp_b_rid: RID = RID()
var current_blur_size := Vector2i(0, 0)

var mask_temp_a_rid: RID = RID()
var mask_temp_b_rid: RID = RID()
var current_mask_size := Vector2i(0, 0)

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _initialize_compute() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_error("MultiplicativeBloomCompositor: no RenderingDevice")
		return

	blur_shader_rid = _compile(BLUR_SHADER_SOURCE, "blur")
	if not blur_shader_rid.is_valid(): return
	blur_pipeline = rd.compute_pipeline_create(blur_shader_rid)

	composite_shader_rid = _compile(COMPOSITE_SHADER_SOURCE, "composite")
	if not composite_shader_rid.is_valid(): return
	composite_pipeline = rd.compute_pipeline_create(composite_shader_rid)

	var raster_source := RDShaderSource.new()
	raster_source.source_vertex = COMPOSITE_RASTER_VERTEX_SOURCE
	raster_source.source_fragment = COMPOSITE_RASTER_FRAGMENT_SOURCE
	var raster_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(raster_source)
	if raster_spirv == null or raster_spirv.compile_error_vertex != "" or raster_spirv.compile_error_fragment != "":
		push_error("MultiplicativeBloomCompositor compile error in raster composite:\n"
			+ (raster_spirv.compile_error_vertex + raster_spirv.compile_error_fragment if raster_spirv else "SPIR-V null"))
	else:
		raster_shader_rid = rd.shader_create_from_spirv(raster_spirv)

	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u   = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v   = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_rid   = rd.sampler_create(ss)

func _compile(source: String, label: String) -> RID:
	var src := RDShaderSource.new()
	src.source_compute = source
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(src)
	if spirv == null:
		push_error("MultiplicativeBloomCompositor: SPIR-V null for " + label)
		return RID()
	if spirv.compile_error_compute != "":
		push_error("MultiplicativeBloomCompositor compile error in " + label + ":\n" + spirv.compile_error_compute)
		return RID()
	return rd.shader_create_from_spirv(spirv)

func _ensure_textures(target_size: Vector2i, current_size_ref: Vector2i,
		a_ref: RID, b_ref: RID) -> Array:
	if target_size == current_size_ref and a_ref.is_valid() and b_ref.is_valid():
		return [a_ref, b_ref, current_size_ref]

	if a_ref.is_valid(): rd.free_rid(a_ref)
	if b_ref.is_valid(): rd.free_rid(b_ref)

	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.width  = target_size.x
	fmt.height = target_size.y
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
				   | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
				   | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

	var view := RDTextureView.new()
	var new_a = rd.texture_create(fmt, view)
	var new_b = rd.texture_create(fmt, view)
	return [new_a, new_b, target_size]

func update_bloom_texture(rid: RID) -> void:
	bloom_texture_rid = rid

func update_foreground_mask(rid: RID) -> void:
	foreground_mask_rid = rid

func update_bloom_size(width: int, height: int) -> void:
	bloom_size = Vector2i(width, height)

func update_mask_size(width: int, height: int) -> void:
	mask_size = Vector2i(width, height)

func _make_blur_pc(size: Vector2i, dir: int, str_val: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(32)
	pc.encode_float(0,  1.0 / float(size.x))
	pc.encode_float(4,  1.0 / float(size.y))
	pc.encode_float(8,  str_val)
	pc.encode_s32(12,   size.x)
	pc.encode_s32(16,   size.y)
	pc.encode_s32(20,   dir)
	return pc

func _make_composite_pc(size: Vector2i) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(32)
	pc.encode_float(0,  1.0 / float(size.x))
	pc.encode_float(4,  1.0 / float(size.y))
	pc.encode_s32(8,    size.x)
	pc.encode_s32(12,   size.y)
	pc.encode_float(16, effect_threshold)
	pc.encode_float(20, foreground_threshold)
	pc.encode_float(24, foreground_edge_start)
	return pc

func _blur_uniforms(source_rid: RID, target_rid: RID) -> RID:
	var s := RDUniform.new()
	s.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	s.binding = 0
	s.add_id(sampler_rid)
	s.add_id(source_rid)

	var t := RDUniform.new()
	t.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	t.binding = 1
	t.add_id(target_rid)

	var u: Array[RDUniform] = [s, t]
	return UniformSetCacheRD.get_cache(blur_shader_rid, 0, u)

func _composite_uniforms(blur_rid: RID, color_rid: RID, mask_rid: RID) -> RID:
	var b := RDUniform.new()
	b.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	b.binding = 0
	b.add_id(sampler_rid)
	b.add_id(blur_rid)

	var c := RDUniform.new()
	c.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	c.binding = 1
	c.add_id(color_rid)

	var m := RDUniform.new()
	m.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	m.binding = 2
	m.add_id(sampler_rid)
	m.add_id(mask_rid)

	var u: Array[RDUniform] = [b, c, m]
	return UniformSetCacheRD.get_cache(composite_shader_rid, 0, u)

func _raster_uniforms(blur_rid: RID, mask_rid: RID) -> RID:
	var b := RDUniform.new()
	b.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	b.binding = 0
	b.add_id(sampler_rid)
	b.add_id(blur_rid)

	var m := RDUniform.new()
	m.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	m.binding = 1
	m.add_id(sampler_rid)
	m.add_id(mask_rid)

	var u: Array[RDUniform] = [b, m]
	return UniformSetCacheRD.get_cache(raster_shader_rid, 0, u)

func _make_raster_pc(size: Vector2i) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(32)
	pc.encode_float(0,  1.0 / float(size.x))
	pc.encode_float(4,  1.0 / float(size.y))
	pc.encode_float(8,  effect_threshold)
	pc.encode_float(12, foreground_threshold)
	pc.encode_float(16, foreground_edge_start)
	return pc

func _supports_storage(texture_rid: RID) -> bool:
	if force_raster:
		return false
	if not storage_support.has(texture_rid):
		if storage_support.size() > 16:
			storage_support.clear()
		var format: RDTextureFormat = rd.texture_get_format(texture_rid)
		storage_support[texture_rid] = format != null \
			and (format.usage_bits & RenderingDevice.TEXTURE_USAGE_STORAGE_BIT) != 0
	return storage_support[texture_rid]

func _ensure_raster_pipeline(framebuffer_format: int) -> void:
	if raster_pipeline.is_valid() and raster_pipeline_format == framebuffer_format:
		return
	if raster_pipeline.is_valid():
		rd.free_rid(raster_pipeline)

	# color = src * 0 + dst * src; alpha stays as it is.
	var attachment := RDPipelineColorBlendStateAttachment.new()
	attachment.enable_blend = true
	attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_SRC_COLOR
	attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
	attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	var attachments: Array[RDPipelineColorBlendStateAttachment] = [attachment]
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = attachments

	raster_pipeline = rd.render_pipeline_create(raster_shader_rid, framebuffer_format,
		RenderingDevice.INVALID_FORMAT_ID, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		RDPipelineRasterizationState.new(), RDPipelineMultisampleState.new(),
		RDPipelineDepthStencilState.new(), blend)
	raster_pipeline_format = framebuffer_format

func _composite_raster(color_image: RID, size: Vector2i) -> void:
	var textures: Array[RID] = [color_image]
	var passes: Array[RDFramebufferPass] = []
	var framebuffer := FramebufferCacheRD.get_cache_multipass(textures, passes, 1)
	if not framebuffer.is_valid():
		return

	_ensure_raster_pipeline(rd.framebuffer_get_format(framebuffer))
	if not raster_pipeline.is_valid():
		return

	var pc := _make_raster_pc(size)
	var draw_list := rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_DEFAULT_ALL)
	rd.draw_list_bind_render_pipeline(draw_list, raster_pipeline)
	rd.draw_list_bind_uniform_set(draw_list, _raster_uniforms(blur_temp_b_rid, mask_temp_b_rid), 0)
	rd.draw_list_set_push_constant(draw_list, pc, pc.size())
	rd.draw_list_draw(draw_list, false, 1, 3)
	rd.draw_list_end()

func _ensure_blur_textures(size: Vector2i) -> void:
	var r := _ensure_textures(size, current_blur_size, blur_temp_a_rid, blur_temp_b_rid)
	blur_temp_a_rid    = r[0]
	blur_temp_b_rid    = r[1]
	current_blur_size  = r[2]

func _ensure_mask_textures(size: Vector2i) -> void:
	var r := _ensure_textures(size, current_mask_size, mask_temp_a_rid, mask_temp_b_rid)
	mask_temp_a_rid    = r[0]
	mask_temp_b_rid    = r[1]
	current_mask_size  = r[2]

func _render_callback(callback_type, render_data) -> void:
	if rd == null:                                              return
	if not blur_shader_rid.is_valid():                          return
	if not composite_shader_rid.is_valid():                     return
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:  return
	if not bloom_texture_rid.is_valid():                        return
	if not foreground_mask_rid.is_valid():                      return
	if bloom_size.x == 0 or bloom_size.y == 0:                  return
	if mask_size.x  == 0 or mask_size.y  == 0:                  return

	var scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if scene_buffers == null: return

	var main_size := scene_buffers.get_internal_size()
	if main_size.x == 0 or main_size.y == 0: return

	var use_raster := not _supports_storage(scene_buffers.get_color_layer(0))
	if use_raster and not raster_shader_rid.is_valid(): return

	_ensure_blur_textures(bloom_size)
	_ensure_mask_textures(mask_size)

	var pc_bh := _make_blur_pc(bloom_size, 0, strength)
	var pc_bv := _make_blur_pc(bloom_size, 1, strength)
	var pc_mh := _make_blur_pc(mask_size,  0, mask_blur_strength)
	var pc_mv := _make_blur_pc(mask_size,  1, mask_blur_strength)
	var pc_c  := _make_composite_pc(main_size)

	var bgx: int = (bloom_size.x + 7) / 8
	var bgy: int = (bloom_size.y + 7) / 8
	var mgx: int = (mask_size.x  + 7) / 8
	var mgy: int = (mask_size.y  + 7) / 8
	var cgx: int = (main_size.x  + 7) / 8
	var cgy: int = (main_size.y  + 7) / 8

	var compute_list := rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(compute_list, blur_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, _blur_uniforms(bloom_texture_rid, blur_temp_a_rid), 0)
	rd.compute_list_set_push_constant(compute_list, pc_bh, pc_bh.size())
	rd.compute_list_dispatch(compute_list, bgx, bgy, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, blur_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, _blur_uniforms(blur_temp_a_rid, blur_temp_b_rid), 0)
	rd.compute_list_set_push_constant(compute_list, pc_bv, pc_bv.size())
	rd.compute_list_dispatch(compute_list, bgx, bgy, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, blur_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, _blur_uniforms(foreground_mask_rid, mask_temp_a_rid), 0)
	rd.compute_list_set_push_constant(compute_list, pc_mh, pc_mh.size())
	rd.compute_list_dispatch(compute_list, mgx, mgy, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, blur_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, _blur_uniforms(mask_temp_a_rid, mask_temp_b_rid), 0)
	rd.compute_list_set_push_constant(compute_list, pc_mv, pc_mv.size())
	rd.compute_list_dispatch(compute_list, mgx, mgy, 1)

	if not use_raster:
		for view_idx in range(scene_buffers.get_view_count()):
			var color_image: RID = scene_buffers.get_color_layer(view_idx)
			rd.compute_list_bind_compute_pipeline(compute_list, composite_pipeline)
			rd.compute_list_bind_uniform_set(compute_list, _composite_uniforms(blur_temp_b_rid, color_image, mask_temp_b_rid), 0)
			rd.compute_list_set_push_constant(compute_list, pc_c, pc_c.size())
			rd.compute_list_dispatch(compute_list, cgx, cgy, 1)

	rd.compute_list_end()

	if use_raster:
		for view_idx in range(scene_buffers.get_view_count()):
			_composite_raster(scene_buffers.get_color_layer(view_idx), main_size)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		if blur_shader_rid.is_valid():      rd.free_rid(blur_shader_rid)
		if composite_shader_rid.is_valid(): rd.free_rid(composite_shader_rid)
		if raster_pipeline.is_valid():      rd.free_rid(raster_pipeline)
		if raster_shader_rid.is_valid():    rd.free_rid(raster_shader_rid)
		if sampler_rid.is_valid():          rd.free_rid(sampler_rid)
		if blur_temp_a_rid.is_valid():      rd.free_rid(blur_temp_a_rid)
		if blur_temp_b_rid.is_valid():      rd.free_rid(blur_temp_b_rid)
		if mask_temp_a_rid.is_valid():      rd.free_rid(mask_temp_a_rid)
		if mask_temp_b_rid.is_valid():      rd.free_rid(mask_temp_b_rid)
