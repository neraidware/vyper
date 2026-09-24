package main

import "core:c"
import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"
import stb "vendor:stb/truetype"

// ---------------------------------------------------------------------------
// GPU pipeline/shader/texture setup: uniform layouts, renderer struct, and
// one-time creation of pipelines, the font atlas, and preview textures.
// ---------------------------------------------------------------------------

RectVertexUniforms :: struct {
	bounds: [4]f32,
	viewport: [2]f32,
	_padding: [2]f32,
}

RectFragmentUniforms :: struct {
	color: [4]f32,
	shape: [4]f32,
	mode:  [4]f32, // x: 0 = circular-arc corner, 1 = squircle
}

TextVertexUniforms :: struct {
	bounds:   [4]f32,
	viewport: [2]f32,
	_padding: [2]f32,
	uv:       [4]f32,
}

TextFragmentUniforms :: struct {
	color: [4]f32,
}

// ---------------------------------------------------------------------------
// Dynamic glyph atlas: one on-demand cache
// holding ANY glyph the face provides, rasterized at GLYPH_BAKE_PX (every UI
// size is below that; draws scale via fontSize/32 exactly like the old bake).
// Fixed-size cells keep re-layout trivial; the texture grid doubles when full
// and the upload pass re-bakes every cached glyph into the new texture (no
// CPU pixel mirror to keep in sync). The CPU side never touches the GPU:
// metrics are stbtt-derived and always available; only the deferred upload
// pass (render_ui_frame, no render pass open) materializes cell pixels.
// ---------------------------------------------------------------------------

// Every cached glyph is rasterized at this pixel height; UI text scales it
// with fontSize/32. A fixed cell covers the glyph plus bleed so LINEAR
// sampling at cell edges never crosses into a neighbor's ink.
GLYPH_BAKE_PX    :: 32
GLYPH_CELL_PX    :: 48
GLYPH_CELL_PAD   :: 4
// Atlas texture grid side in cells: 16 -> 768px, 32 -> 1536px, 64 -> 3072px.
GLYPH_CELLS0     :: 16
GLYPH_CELLS_MAX  :: 64
MAX_GLYPH_SLOTS  :: GLYPH_CELLS_MAX * GLYPH_CELLS_MAX
MAX_GLYPH_RUNES  :: 0x110000 // Unicode code point space, inclusive
// cell ordinal marker for metric-only glyphs (no ink: space, zero-width).
GLYPH_CELL_NONE :: ~u32(0)

// rune->cache map encoding: 0 = not seen yet, 1 = rune missing from the face
// (cached "no" so we don't re-probe stbtt every frame), n >= 2 = slot n-2.
GLYPH_MAP_MISSING :: 1

Glyph_Slot :: struct {
	rune: rune, // 0 = free slot (cache only grows, never evicts)
	cell: u32,  // atlas cell ordinal in the current grid
	adv:  f32,  // pen advance in bake px
	xoff: f32,  // ink left edge, pen-relative, bake px
	yoff: f32,  // ink top edge, baseline-relative (down = +), bake px
	w:    u16,  // bitmap size in bake px; 0 = no ink (metric-only glyph)
	h:    u16,
}

Glyph_Atlas :: struct {
	texture:          ^sdl.GPUTexture,
	sampler:          ^sdl.GPUSampler,
	font:             stb.fontinfo,
	font_ready:       bool,
	// Bake-space vertical metrics (GLYPH_BAKE_PX units): the face's true
	// baseline sits `ascent_bake` below the box top, not a full em down.
	// render_text centers on these so ink lines up with clay's measured box.
	ascent_bake:      f32,
	descent_bake:     f32,
	cells_x:          u32, // current grid side in cells
	generation:       u32, // bumped every grid re-create
	next_cell:        u32, // cells handed out so far
	needs_grow:       bool, // a cell beyond the current grid wants a re-create
	slot_count:       u32, // slots in use; the cache never shrinks
	baked_until_cell: u32, // cells whose pixels are resident in `texture`
	pix_generation:   u32, // generation the resident cells were baked for
	slots:            []Glyph_Slot, // [MAX_GLYPH_SLOTS]
	rune_map:         []u32, // [MAX_GLYPH_RUNES] direct-indexed
	pix:              []u8, // CPU grid (tex_px^2), the upload staging buffer
}

glyph_atlas_init :: proc(a: ^Glyph_Atlas, allocator := context.allocator) -> bool {
	a.slots = make([]Glyph_Slot, MAX_GLYPH_SLOTS, allocator)
	if a.slots == nil {
		return false
	}
	a.rune_map = make([]u32, MAX_GLYPH_RUNES, allocator)
	if a.rune_map == nil {
		delete(a.slots, allocator)
		return false
	}
	a.cells_x = GLYPH_CELLS0
	a.pix = make([]u8, int(glyph_atlas_texture_px(a)) * int(glyph_atlas_texture_px(a)), allocator)
	if a.pix == nil {
		delete(a.slots, allocator)
		delete(a.rune_map, allocator)
		return false
	}
	a.pix_generation = ~u32(0) // nothing baked yet
	return true
}

glyph_atlas_destroy :: proc(a: ^Glyph_Atlas, allocator := context.allocator) {
	delete(a.slots, allocator)
	delete(a.rune_map, allocator)
	delete(a.pix, allocator)
	a^ = {}
}

glyph_atlas_texture_px :: proc(a: ^Glyph_Atlas) -> u32 {
	return a.cells_x * GLYPH_CELL_PX
}

glyph_atlas_capacity :: proc(a: ^Glyph_Atlas) -> u32 {
	return a.cells_x * a.cells_x
}

// glyph_atlas_slot resolves a rune to its cached slot (ok = true) if it was
// ensured before. False means "nothing cached": either never seen or known
// missing from the face.
glyph_atlas_slot :: proc(a: ^Glyph_Atlas, r: rune) -> (slot: u32, ok: bool) {
	ir := int(r)
	if ir < 0 || ir >= MAX_GLYPH_RUNES {
		return 0, false
	}
	v := a.rune_map[ir]
	if v == 0 || v == GLYPH_MAP_MISSING {
		return 0, false
	}
	return v - 2, true
}

// glyph_atlas_allocate_cell hands out the next cell ordinal. Crossing the
// current grid's capacity sets needs_grow; the deferred upload pass doubles
// the grid and re-bakes before any pixels are written. CPU-side cell state
// is legal up to MAX_GLYPH_SLOTS regardless of the current grid side.
glyph_atlas_allocate_cell :: proc(a: ^Glyph_Atlas, s: ^Glyph_Slot) {
	assert(a.next_cell < MAX_GLYPH_SLOTS, "glyph atlas: cell table full (raise GLYPH_CELLS_MAX)")
	s.cell = a.next_cell
	a.next_cell += 1
	if a.next_cell > a.cells_x * a.cells_x {
		a.needs_grow = true
	}
}

// glyph_atlas_grow_to_fit doubles the grid until it holds every allocated
// cell (or hits the max). Called by the deferred upload pass before pixels
// are materialized. Cells keep their ordinal -- only the grid side changes
// what texel address an ordinal maps to, and the full re-upload reads slot
// metrics fresh each re-create, so no CPU pixel state ever moves.
glyph_atlas_grow_to_fit :: proc(a: ^Glyph_Atlas) {
	for a.next_cell > a.cells_x * a.cells_x && a.cells_x < GLYPH_CELLS_MAX {
		a.cells_x *= 2
		a.generation += 1
	}
	// Grid is at max yet still short: the cell table itself is exhausted.
	assert(a.next_cell <= a.cells_x * a.cells_x, "glyph atlas: cells exceed the max grid")
	a.needs_grow = false
}

// glyph_atlas_cell_xy maps an ordinal cell index to its (x, y) in the
// current, row-major grid.
glyph_atlas_cell_xy :: proc(a: ^Glyph_Atlas, cell: u32) -> (x, y: u32) {
	assert(cell < glyph_atlas_capacity(a), "glyph atlas: cell ordinal past the grid")
	return cell % a.cells_x, cell / a.cells_x
}

// glyph_ensure returns the slot index for `r`, baking metrics on first
// sight (no pixels yet -- ink is rasterized on the deferred upload pass).
// A rune the face lacks resolves once to missing and never re-probes.
// "Unicode support" here is literally whatever the rasterizing face
// provides; no shaping, no fallback faces.
// glyph_atlas_read_metrics caches the face's bake-space ascent/descent so
// render_text can place the baseline at the true ink origin instead of a
// whole em below the box top (which pushed every line off-center).
glyph_atlas_read_metrics :: proc(a: ^Glyph_Atlas) {
	ascent, descent, _: c.int
	stb.GetFontVMetrics(&a.font, &ascent, &descent, nil)
	scale := stb.ScaleForPixelHeight(&a.font, GLYPH_BAKE_PX)
	a.ascent_bake = f32(ascent) * scale
	a.descent_bake = f32(descent) * scale
}

glyph_ensure :: proc(a: ^Glyph_Atlas, r: rune) -> (slot: u32, ok: bool, is_new: bool) {
	if s, cached := glyph_atlas_slot(a, r); cached {
		return s, true, false
	}
	ir := int(r)
	if ir < 0 || ir >= MAX_GLYPH_RUNES {
		return 0, false, false
	}
	if a.rune_map[ir] == GLYPH_MAP_MISSING {
		return 0, false, false
	}
	assert(a.slot_count < MAX_GLYPH_SLOTS, "glyph atlas: slot table full")
	if !a.font_ready {
		stb.InitFont(&a.font, raw_data(font_data), 0)
		glyph_atlas_read_metrics(a)
		a.font_ready = true
	}
	scale := stb.ScaleForPixelHeight(&a.font, GLYPH_BAKE_PX)
	if stb.FindGlyphIndex(&a.font, r) == 0 {
		a.rune_map[ir] = GLYPH_MAP_MISSING
		return 0, false, false
	}
	adv: c.int
	stb.GetCodepointHMetrics(&a.font, r, &adv, nil)
	box: [4]c.int
	stb.GetCodepointBitmapBox(&a.font, r, scale, scale, &box[0], &box[1], &box[2], &box[3])
	w := box[2] - box[0]
	h := box[3] - box[1]
	assert(w <= GLYPH_CELL_PX && h <= GLYPH_CELL_PX, "glyph atlas: baked glyph exceeds a cell")
	s := a.slot_count
	a.slot_count += 1
	g := &a.slots[s]
	g^ = Glyph_Slot {
		rune = r,
		cell = GLYPH_CELL_NONE,
		adv  = f32(adv) * scale,
		xoff = f32(box[0]),
		yoff = f32(box[1]),
		w    = u16(w),
		h    = u16(h),
	}
	if w > 0 && h > 0 {
		glyph_atlas_allocate_cell(a, g)
	}
	a.rune_map[ir] = u32(s) + 2
	return s, true, true
}

// gpu_renderer points at the single device renderer created at startup so
// subsystems spawned off the main thread -- the export worker's GPU compositor
// -- can reach the shared device/pipelines/samplers. Set once in main before
// any worker starts, and never repointed (the renderer outlives every worker).
gpu_renderer: ^GPU_Renderer

GPU_Renderer :: struct {
	device: ^sdl.GPUDevice,
	// format is the swapchain texture format. Offscreen render targets must use
	// the same format because a pipeline's color target description is fixed at
	// creation, and the shared pipelines were built for this one.
	format: sdl.GPUTextureFormat,
	pipeline: ^sdl.GPUGraphicsPipeline,
	text_pipeline: ^sdl.GPUGraphicsPipeline,
	preview_pipeline: ^sdl.GPUGraphicsPipeline,
	font: Glyph_Atlas,
	preview_textures: [MAX_PREVIEW_SLOTS]^sdl.GPUTexture,
	preview_sampler: ^sdl.GPUSampler,
	icon_textures: [Icon_Id]^sdl.GPUTexture,
	viewport: [2]f32,
	// Persistent upload staging, reused across frames. Creating and releasing a
	// transfer buffer per dirty slot per frame was a driver allocation churn on
	// the preview hot path; SDL's pair to that is one grow-only buffer with the
	// map cycled (see sdl-gpu-concepts-cycling). Capacity tracks the current
	// allocation so a same-size re-upload never touches the driver.
	preview_upload_tb:       ^sdl.GPUTransferBuffer,
	preview_upload_capacity: int,
	text_upload_tb:          ^sdl.GPUTransferBuffer,
	text_upload_capacity:    int,
}

rounded_rect_vertex_spirv := #load("shaders/rounded_rect.vert.spv")
rounded_rect_fragment_spirv := #load("shaders/rounded_rect.frag.spv")
text_vertex_spirv := #load("shaders/text.vert.spv")
text_fragment_spirv := #load("shaders/text.frag.spv")
preview_fragment_spirv := #load("shaders/preview.frag.spv")


create_gpu_renderer :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, width, height: c.int) -> (result: GPU_Renderer, ok: bool) {
	result.device = device
	result.format = format
	result.viewport = {f32(width), f32(height)}
	if !glyph_atlas_init(&result.font) {
		fmt.println("Could not allocate glyph atlas tables")
		return
	}
	// If a later step fails, release everything created so far. Every return
	// below leaves ok=false, so this block runs; the success path sets ok=true
	// and keeps every handle. GPU handles are driver-managed -- no host
	// allocator or tracking to catch a leak -- and device init/reinit failure
	// (the only path that reaches here) is exactly where silent resource
	// exhaustion shows up, so each created handle is released with the same
	// nil guard the caller's teardown uses.
	defer if !ok {
		glyph_atlas_destroy(&result.font)
		if result.pipeline != nil {
			sdl.ReleaseGPUGraphicsPipeline(device, result.pipeline)
		}
		if result.text_pipeline != nil {
			sdl.ReleaseGPUGraphicsPipeline(device, result.text_pipeline)
		}
		if result.preview_pipeline != nil {
			sdl.ReleaseGPUGraphicsPipeline(device, result.preview_pipeline)
		}
		if result.font.texture != nil {
			sdl.ReleaseGPUTexture(device, result.font.texture)
		}
		if result.font.sampler != nil {
			sdl.ReleaseGPUSampler(device, result.font.sampler)
		}
		for t in result.preview_textures {
			if t != nil {
				sdl.ReleaseGPUTexture(device, t)
			}
		}
		if result.preview_sampler != nil {
			sdl.ReleaseGPUSampler(device, result.preview_sampler)
		}
	}
	vertex_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(rounded_rect_vertex_spirv)), code = raw_data(rounded_rect_vertex_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1,
	}
	fragment_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(rounded_rect_fragment_spirv)), code = raw_data(rounded_rect_fragment_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_uniform_buffers = 1,
	}
	vertex_shader := sdl.CreateGPUShader(device, vertex_info)
	fragment_shader := sdl.CreateGPUShader(device, fragment_info)
	if vertex_shader == nil || fragment_shader == nil {
		fmt.println("GPU shader creation failed:", sdl.GetError())
		return
	}
	defer sdl.ReleaseGPUShader(device, vertex_shader)
	defer sdl.ReleaseGPUShader(device, fragment_shader)
	blend := sdl.GPUColorTargetBlendState{
		src_color_blendfactor = .SRC_ALPHA, dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA, color_blend_op = .ADD,
		src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA, alpha_blend_op = .ADD,
		color_write_mask = {.R, .G, .B, .A}, enable_blend = true, enable_color_write_mask = true,
	}
	target := sdl.GPUColorTargetDescription{format = format, blend_state = blend}
	pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = vertex_shader, fragment_shader = fragment_shader,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(device, pipeline_info)
	if pipeline == nil {
		fmt.println("GPU pipeline creation failed:", sdl.GetError())
		return
	}
	result.pipeline = pipeline
	text_vertex_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(text_vertex_spirv)), code = raw_data(text_vertex_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1,
	}
	text_fragment_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(text_fragment_spirv)), code = raw_data(text_fragment_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1, num_uniform_buffers = 1,
	}
	text_vertex_shader := sdl.CreateGPUShader(device, text_vertex_info)
	text_fragment_shader := sdl.CreateGPUShader(device, text_fragment_info)
	if text_vertex_shader == nil || text_fragment_shader == nil {
		fmt.println("Text shader creation failed:", sdl.GetError())
		return
	}
	defer sdl.ReleaseGPUShader(device, text_vertex_shader)
	defer sdl.ReleaseGPUShader(device, text_fragment_shader)
	text_pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = text_vertex_shader, fragment_shader = text_fragment_shader, primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1}, target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	text_pipeline := sdl.CreateGPUGraphicsPipeline(device, text_pipeline_info)
	if text_pipeline == nil {
		fmt.println("Text pipeline creation failed:", sdl.GetError())
		return
	}
	result.text_pipeline = text_pipeline

	preview_fragment_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(preview_fragment_spirv)), code = raw_data(preview_fragment_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1,
	}
	preview_fragment_shader := sdl.CreateGPUShader(device, preview_fragment_info)
	if preview_fragment_shader == nil {
		fmt.println("Preview shader creation failed:", sdl.GetError())
		return
	}
	defer sdl.ReleaseGPUShader(device, preview_fragment_shader)
	preview_pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = text_vertex_shader, fragment_shader = preview_fragment_shader, primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1}, target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	preview_pipeline := sdl.CreateGPUGraphicsPipeline(device, preview_pipeline_info)
	if preview_pipeline == nil {
		fmt.println("Preview pipeline creation failed:", sdl.GetError())
		return
	}
	result.preview_pipeline = preview_pipeline

	tex_px := glyph_atlas_texture_px(&result.font)
	font_texture := sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8_UNORM, usage = {.SAMPLER}, width = tex_px, height = tex_px, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
	font_sampler := sdl.CreateGPUSampler(device, sdl.GPUSamplerCreateInfo{min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE, max_lod = 1})
	if font_texture == nil || font_sampler == nil {
		fmt.println("Font texture or sampler creation failed:", sdl.GetError())
		return
	}
	result.font.texture = font_texture
	result.font.sampler = font_sampler
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		result.preview_textures[i] = sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = PREVIEW_W, height = PREVIEW_H, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
		if result.preview_textures[i] == nil {
			fmt.println("Preview texture creation failed:", sdl.GetError())
			return
		}
	}
	preview_sampler := sdl.CreateGPUSampler(device, sdl.GPUSamplerCreateInfo{min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE, max_lod = 1})
	if preview_sampler == nil {
		fmt.println("Preview sampler creation failed:", sdl.GetError())
		return
	}
	result.preview_sampler = preview_sampler
	ok = true
	return
}

// glyph_atlas_ensure_ascii prebakes the printable ASCII block (glyph_metrics
// for every rune + cells for the ones with ink), so the first frame has
// anything plain-text UI needs without a grow round-trip. The pixels
// themselves still arrive on the first deferred upload.
glyph_atlas_ensure_ascii :: proc(a: ^Glyph_Atlas) {
	for r in rune(0x20) ..= rune(0x7E) {
		glyph_ensure(a, r)
	}
}

// glyph_atlas_bake_pending_ink renders every cached glyph whose ink is not
// yet resident into the CPU grid, working ONLY from slot state -- a grid
// re-create means pix_generation != generation, so all slots re-bake after
// the grid is zeroed (never a second mirror to keep in sync).
glyph_atlas_bake_pending_ink :: proc(a: ^Glyph_Atlas) {
	if !a.font_ready {
		stb.InitFont(&a.font, raw_data(font_data), 0)
		glyph_atlas_read_metrics(a)
		a.font_ready = true
	}
	scale := stb.ScaleForPixelHeight(&a.font, GLYPH_BAKE_PX)
	tex_px := int(glyph_atlas_texture_px(a))
	if a.pix_generation != a.generation {
		mem.zero_slice(a.pix)
		a.baked_until_cell = 0
	}
	scratch: [GLYPH_CELL_PX * GLYPH_CELL_PX]u8
	for i in 0 ..< int(a.slot_count) {
		g := &a.slots[i]
		if g.w == 0 || g.h == 0 || g.cell < a.baked_until_cell {
			continue
		}
		stb.MakeCodepointBitmap(&a.font, &scratch[0], c.int(g.w), c.int(g.h), c.int(g.w), scale, scale, g.rune)
		cx, cy := glyph_atlas_cell_xy(a, g.cell)
		dst_base := (int(cy) * int(GLYPH_CELL_PX) + GLYPH_CELL_PAD) * tex_px + (int(cx) * int(GLYPH_CELL_PX) + GLYPH_CELL_PAD)
		for y in 0 ..< int(g.h) {
			for x in 0 ..< int(g.w) {
				a.pix[dst_base + y * tex_px + x] = scratch[y * int(g.w) + x]
			}
		}
	}
	a.baked_until_cell = a.next_cell
	a.pix_generation = a.generation
}

// glyph_atlas_recreate_texture doubles the grid and re-creates the GPU
// texture for the new size. The old texture is handed to the deferred
// release queue (freed next frame, after the last in-flight command buffer
// reading it -- same wrapping gap the text-slot release already accepts).
glyph_atlas_recreate_texture :: proc(a: ^Glyph_Atlas, device: ^sdl.GPUDevice) {
	glyph_atlas_grow_to_fit(a)
	old := a.texture
	tex_px := glyph_atlas_texture_px(a)
	a.texture = sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8_UNORM, usage = {.SAMPLER}, width = tex_px, height = tex_px, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
	assert(a.texture != nil, "glyph atlas: re-create failed")
	if old != nil {
		queue_text_texture_release(old)
	}
	delete(a.pix)
	a.pix = make([]u8, int(tex_px) * int(tex_px))
	a.pix_generation = ~u32(0) // force full re-bake into the new grid
}

// glyph_atlas_upload_if_dirty is the deferred upload hook (render_ui_frame,
// no render pass open yet). It grows + re-creates first when needed, bakes
// resident-awaiting cells into the CPU grid, then uploads the whole grid in
// one copy pass -- a full 1024px/1MB grid at most, far cheaper than framing
// dirty regions.
glyph_atlas_upload_if_dirty :: proc(a: ^Glyph_Atlas, device: ^sdl.GPUDevice, command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	if a.needs_grow {
		glyph_atlas_recreate_texture(a, device)
	}
	if a.texture == nil || (a.baked_until_cell == a.next_cell && a.pix_generation == a.generation) {
		return true
	}
	glyph_atlas_bake_pending_ink(a)
	n := int(glyph_atlas_texture_px(a)) * int(glyph_atlas_texture_px(a))
	transfer := sdl.CreateGPUTransferBuffer(device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = u32(n)})
	if transfer == nil {
		return false
	}
	mapped := sdl.MapGPUTransferBuffer(device, transfer, false)
	if mapped == nil {
		sdl.ReleaseGPUTransferBuffer(device, transfer)
		return false
	}
	mem.copy(mapped, raw_data(a.pix), n)
	sdl.UnmapGPUTransferBuffer(device, transfer)
	tex_px := glyph_atlas_texture_px(a)
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	defer sdl.EndGPUCopyPass(copy_pass)
	source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = tex_px, rows_per_layer = tex_px}
	destination := sdl.GPUTextureRegion{texture = a.texture, w = tex_px, h = tex_px, d = 1}
	sdl.UploadToGPUTexture(copy_pass, source, destination, false)
	sdl.ReleaseGPUTransferBuffer(device, transfer)
	return true
}

// upload_icons rasterizes every embedded SVG icon into its own small R8
// texture (uploaded together on the initial command buffer, before any frame).
upload_icons :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	for id in Icon_Id {
		rasterized, ok := rasterize_icon_svg(get_icon_svg(id))
		if !ok {
			fmt.println("Could not rasterize icon:", id)
			return false
		}
		defer delete(rasterized)
		texture := sdl.CreateGPUTexture(renderer.device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8_UNORM, usage = {.SAMPLER}, width = ICON_RASTER, height = ICON_RASTER, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
		if texture == nil {
			fmt.println("Could not create icon texture:", sdl.GetError())
			return false
		}
		transfer := sdl.CreateGPUTransferBuffer(renderer.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = ICON_RASTER * ICON_RASTER})
		if transfer == nil {
			sdl.ReleaseGPUTexture(renderer.device, texture)
			return false
		}
		mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, false)
		if mapped == nil {
			sdl.ReleaseGPUTexture(renderer.device, texture)
			sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
			return false
		}
		mapped_bytes := (cast([^]u8)mapped)[:ICON_RASTER * ICON_RASTER]
		assert(len(rasterized) == ICON_RASTER * ICON_RASTER, "upload_icons: rasterized icon size mismatch")
		copy(mapped_bytes, rasterized)
		sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
		copy_pass := sdl.BeginGPUCopyPass(command_buffer)
		source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = ICON_RASTER, rows_per_layer = ICON_RASTER}
		destination := sdl.GPUTextureRegion{texture = texture, w = ICON_RASTER, h = ICON_RASTER, d = 1}
		sdl.UploadToGPUTexture(copy_pass, source, destination, false)
		sdl.EndGPUCopyPass(copy_pass)
		sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
		renderer.icon_textures[id] = texture
	}
	return true
}
