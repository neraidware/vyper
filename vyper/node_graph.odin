package vyper

import mem "core:mem"

// Generic compositing DAG. Nodes own variable-length input/property ranges into
// flat graph storage: no fixed slot count and no allocation per node.

Node_Role :: enum {
	Invalid,
	Input,
	Process,
	Renderer,
	Sink,
}

Node_Operation :: enum {
	None,
	Media_Input,
	Text_Input,
	Subtitle_Input,
	Number_Input,
	Audio_Input,
	Crop,
	Scale,
	Translate,
	Zoom,
	Pan,
	Opacity,
	Text_Style,
	Color,
	Blend,
	Audio_Gain,
	Audio_Pitch,
	Audio_Time_Map,
	Text_Renderer,
	Media_Renderer,
	Audio_Renderer,
	Image_Output,
	Audio_Output,
}

Node_Data_Type :: enum {
	Invalid,
	Text,
	Text_Style,
	Image_Descriptor,
	Image,
	Audio_Stream,
	Audio,
	Number,
	Vector,
	Color,
	Boolean,
	Media_Asset,
}

Node_Pin :: enum {
	Text,
	Style,
	Image,
	Audio,
	Number,
	Vector,
}

Node_Property_Key :: enum {
	Text_Content,
	Media_Asset,
	Stream_Index,
	Number_Value,
	Character_Start,
	Character_Length,
	Reveal,
	Ink_Color,
	Crop_Left,
	Crop_Right,
	Crop_Top,
	Crop_Bottom,
	Scale_Value,
	Translate_X,
	Translate_Y,
	Zoom_Value,
	Pan_X,
	Pan_Y,
	Opacity_Value,
	Gain_Value,
	Pitch_Value,
	Time_Scale,
}

Node_Value_Kind :: enum {
	Invalid,
	Number,
	Integer,
	Boolean,
	Vector,
	Color,
	Text_Handle,
	Media_Asset,
	Reveal,
}

// Tagged POD value. The property key determines which variant is valid.
Node_Value :: struct {
	kind: Node_Value_Kind,
	number: f64,
	integer: i64,
	boolean: bool,
	vector: [4]f32,
	color: [4]u8,
	text: Session_Str_Handle,
	media_asset_id: u64,
	reveal: Text_Reveal,
}

// Independent from Node_Handle: keyframe channels belong to values, not nodes.
Node_Value_Id :: distinct u64

Node_Handle :: struct {
	index: int,
	gen: u32,
}

Node_Range :: struct {
	first: int,
	n: int,
}

// Each node has an arbitrary number of inputs and properties. The node stores
// ranges; the graph owns flat backing arrays so rows can move without per-node
// allocations or stale pointers.
Node_Input :: struct {
	pin: Node_Pin,
	source: Node_Handle,
	source_pin: Node_Pin,
	data_type: Node_Data_Type,
}

Node_Connection :: struct {
	target: Node_Handle,
	target_pin: Node_Pin,
	source: Node_Handle,
	source_pin: Node_Pin,
}

Node_Property :: struct {
	key: Node_Property_Key,
	value_id: Node_Value_Id,
	value: Node_Value,
}

Node_Property_Definition :: struct {
	owner: Node_Handle,
	property: Node_Property,
}

Compositor_Node :: struct {
	generation: u32,
	active: bool,
	operation: Node_Operation,
	inputs: Node_Range,
	properties: Node_Range,
}

Node_Graph :: struct {
	// The graph owns every byte of node/input/property/compile storage. Its
	// allocator control must not move after init: Dynamic_Arena's Allocator keeps
	// a pointer to this field. Persistent graphs therefore live behind stable
	// handles, never embedded by value in a growable array.
	arena: mem.Dynamic_Arena,
	initialized: bool,
	// Index zero is reserved. Connections store handles, never pointers into this
	// growable array.
	nodes: [dynamic]Compositor_Node,
	connections: [dynamic]Node_Connection,
	property_definitions: [dynamic]Node_Property_Definition,
	inputs: [dynamic]Node_Input,
	properties: [dynamic]Node_Property,
	topological_order: [dynamic]Node_Handle,
	reachable: [dynamic]bool,
	visit_marks: [dynamic]u32,
	visit_epoch: u32,
	visit_stack: [dynamic]Node_Handle,
	indegree: [dynamic]int,
	sink: Node_Handle,
	next_value_id: u64,
	generation: u64,
	compiled_generation: u64,
}

Text_Ink :: struct {
	drawn: bool,
	color: [3]u8,
}

TEXT_INK_DEFAULT_RGB :: [3]u8{255, 255, 255}

node_role :: proc(operation: Node_Operation) -> Node_Role {
	switch operation {
	case .None: return .Invalid
	case .Media_Input, .Text_Input, .Subtitle_Input, .Number_Input, .Audio_Input:
		return .Input
	case .Crop, .Scale, .Translate, .Zoom, .Pan, .Opacity, .Text_Style, .Color,
	     .Blend, .Audio_Gain, .Audio_Pitch, .Audio_Time_Map:
		return .Process
	case .Text_Renderer, .Media_Renderer, .Audio_Renderer:
		return .Renderer
	case .Image_Output, .Audio_Output:
		return .Sink
	}
	unreachable()
}

node_output_type :: proc(operation: Node_Operation, pin: Node_Pin) -> (Node_Data_Type, bool) {
	switch operation {
	case .None, .Image_Output, .Audio_Output:
		return .Invalid, false
	case .Media_Input:
		if pin == .Image { return .Image_Descriptor, true }
		if pin == .Audio { return .Audio_Stream, true }
		return .Invalid, false
	case .Text_Input, .Subtitle_Input:
		return .Text, pin == .Text
	case .Number_Input:
		return .Number, pin == .Number
	case .Crop, .Scale, .Translate, .Zoom, .Pan, .Opacity, .Color, .Blend:
		return .Image_Descriptor, pin == .Image
	case .Text_Style:
		return .Text_Style, pin == .Style
	case .Text_Renderer, .Media_Renderer:
		return .Image, pin == .Image
	case .Audio_Input, .Audio_Gain, .Audio_Pitch, .Audio_Time_Map:
		return .Audio_Stream, pin == .Audio
	case .Audio_Renderer:
		return .Audio, pin == .Audio
	}
	unreachable()
}

node_input_type :: proc(operation: Node_Operation, pin: Node_Pin) -> (Node_Data_Type, bool) {
	switch operation {
	case .None, .Media_Input, .Text_Input, .Subtitle_Input, .Number_Input, .Audio_Input:
		return .Invalid, false
	case .Text_Style:
		return .Text, pin == .Text
	case .Text_Renderer:
		if pin == .Text { return .Text, true }
		if pin == .Style { return .Text_Style, true }
		return .Invalid, false
	case .Crop, .Scale, .Translate, .Zoom, .Pan, .Opacity, .Color, .Blend, .Media_Renderer:
		return .Image_Descriptor, pin == .Image
	case .Audio_Gain, .Audio_Pitch, .Audio_Time_Map, .Audio_Renderer:
		return .Audio_Stream, pin == .Audio
	case .Image_Output:
		return .Image, pin == .Image
	case .Audio_Output:
		return .Audio, pin == .Audio
	}
	unreachable()
}

node_input_accepts_many :: proc(operation: Node_Operation, pin: Node_Pin) -> bool {
	return (operation == .Text_Renderer && pin == .Style) ||
		(operation == .Blend && pin == .Image)
}

node_property_type :: proc(operation: Node_Operation, key: Node_Property_Key) -> Node_Value_Kind {
	if operation == .Text_Input && key == .Text_Content { return .Text_Handle }
	if operation == .Media_Input && key == .Media_Asset { return .Media_Asset }
	if (operation == .Media_Input || operation == .Audio_Input) && key == .Stream_Index { return .Integer }
	if operation == .Number_Input && key == .Number_Value { return .Number }
	if operation == .Text_Style {
		if key == .Character_Start || key == .Character_Length { return .Integer }
		if key == .Reveal { return .Reveal }
		if key == .Ink_Color { return .Color }
	}
	if operation == .Crop && (key == .Crop_Left || key == .Crop_Right || key == .Crop_Top || key == .Crop_Bottom) {
		return .Number
	}
	if operation == .Scale && key == .Scale_Value { return .Number }
	if operation == .Translate && (key == .Translate_X || key == .Translate_Y) { return .Number }
	if operation == .Zoom && key == .Zoom_Value { return .Number }
	if operation == .Pan && (key == .Pan_X || key == .Pan_Y) { return .Number }
	if operation == .Opacity && key == .Opacity_Value { return .Number }
	if operation == .Color && key == .Ink_Color { return .Color }
	if operation == .Audio_Gain && key == .Gain_Value { return .Number }
	if operation == .Audio_Pitch && key == .Pitch_Value { return .Number }
	if operation == .Audio_Time_Map && key == .Time_Scale { return .Number }
	return .Invalid
}

graph_init :: proc(graph: ^Node_Graph) {
	if graph.initialized {
		return
	}
	mem.dynamic_arena_init(&graph.arena)
	allocator := mem.dynamic_arena_allocator(&graph.arena)
	graph.nodes = make([dynamic]Compositor_Node, allocator)
	graph.connections = make([dynamic]Node_Connection, allocator)
	graph.property_definitions = make([dynamic]Node_Property_Definition, allocator)
	graph.inputs = make([dynamic]Node_Input, allocator)
	graph.properties = make([dynamic]Node_Property, allocator)
	graph.topological_order = make([dynamic]Node_Handle, allocator)
	graph.reachable = make([dynamic]bool, allocator)
	graph.visit_marks = make([dynamic]u32, allocator)
	graph.visit_stack = make([dynamic]Node_Handle, allocator)
	graph.indegree = make([dynamic]int, allocator)
	append(&graph.nodes, Compositor_Node{}) // ID zero is "no node".
	graph.initialized = true
	if graph.next_value_id == 0 {
		graph.next_value_id = 1
	}
}

// node_graph_free_all is the graph's owner teardown. Its one allocator owns every
// node, input, property, and compile buffer, so freeing a graph is one free-all,
// not a delete for every field and node. Dynamic_Arena::destroy performs that
// free-all and releases its block bookkeeping.
node_graph_free_all :: proc(graph: ^Node_Graph) {
	if !graph.initialized {
		return
	}
	mem.dynamic_arena_destroy(&graph.arena)
	graph^ = {}
}

graph_node_add :: proc(graph: ^Node_Graph, operation: Node_Operation) -> Node_Handle {
	graph_init(graph)
	assert(operation != .None, "graph_node_add: operation must be named")
	index := len(graph.nodes)
	append(&graph.nodes, Compositor_Node{generation = 1, active = true, operation = operation})
	graph.generation += 1
	graph.compiled_generation = 0
	return Node_Handle{index = index, gen = 1}
}

graph_node_index_checked :: proc(graph: ^Node_Graph, handle: Node_Handle) -> (int, bool) {
	if handle.index <= 0 || handle.index >= len(graph.nodes) { return 0, false }
	node := graph.nodes[handle.index]
	return handle.index, node.active && node.generation == handle.gen
}

graph_node_index :: proc(graph: ^Node_Graph, handle: Node_Handle) -> int {
	index, ok := graph_node_index_checked(graph, handle)
	assert(ok, "graph_node_index: stale node handle")
	return index
}

graph_property_add :: proc(
	graph: ^Node_Graph,
	node_handle: Node_Handle,
	key: Node_Property_Key,
	value: Node_Value,
) -> (Node_Value_Id, bool) {
	node_index, ok := graph_node_index_checked(graph, node_handle)
	if !ok { return {}, false }
	want := node_property_type(graph.nodes[node_index].operation, key)
	if want == .Invalid || want != value.kind { return {}, false }
	for definition in graph.property_definitions {
		if definition.owner == node_handle && definition.property.key == key { return {}, false }
	}
	if graph.next_value_id == 0 { graph.next_value_id = 1 }
	value_id := Node_Value_Id(graph.next_value_id)
	graph.next_value_id += 1
	append(&graph.property_definitions, Node_Property_Definition{
		owner = node_handle,
		property = Node_Property{key = key, value_id = value_id, value = value},
	})
	graph.generation += 1
	graph.compiled_generation = 0
	return value_id, true
}

graph_connect :: proc(
	graph: ^Node_Graph,
	from: Node_Handle,
	from_pin: Node_Pin,
	to: Node_Handle,
	to_pin: Node_Pin,
) -> bool {
	from_index, from_ok := graph_node_index_checked(graph, from)
	to_index, to_ok := graph_node_index_checked(graph, to)
	if !from_ok || !to_ok { return false }
	emits, emits_ok := node_output_type(graph.nodes[from_index].operation, from_pin)
	accepts, accepts_ok := node_input_type(graph.nodes[to_index].operation, to_pin)
	if !emits_ok || !accepts_ok || emits != accepts { return false }
	if !node_input_accepts_many(graph.nodes[to_index].operation, to_pin) {
		for connection in graph.connections {
			if connection.target == to && connection.target_pin == to_pin { return false }
		}
	}
	if graph_reaches(graph, to, from) { return false }
	append(&graph.connections, Node_Connection{
		target = to,
		target_pin = to_pin,
		source = from,
		source_pin = from_pin,
	})
	graph.generation += 1
	graph.compiled_generation = 0
	return true
}

graph_reaches :: proc(graph: ^Node_Graph, start, target: Node_Handle) -> bool {
	if start == target { return true }
	resize(&graph.visit_marks, len(graph.nodes))
	graph.visit_epoch += 1
	if graph.visit_epoch == 0 {
		for i in 0 ..< len(graph.visit_marks) { graph.visit_marks[i] = 0 }
		graph.visit_epoch = 1
	}
	clear(&graph.visit_stack)
	append(&graph.visit_stack, start)
	graph.visit_marks[start.index] = graph.visit_epoch
	cursor := 0
	for cursor < len(graph.visit_stack) {
		current := graph.visit_stack[cursor]
		cursor += 1
		for connection in graph.connections {
			if connection.source != current { continue }
			if connection.target == target { return true }
			if graph.visit_marks[connection.target.index] != graph.visit_epoch {
				graph.visit_marks[connection.target.index] = graph.visit_epoch
				append(&graph.visit_stack, connection.target)
			}
		}
	}
	return false
}

graph_compile :: proc(graph: ^Node_Graph) -> bool {
	graph_init(graph)
	active_count := 0
	for node_index in 1 ..< len(graph.nodes) {
		if graph.nodes[node_index].active { active_count += 1 }
	}
	resize(&graph.indegree, len(graph.nodes))
	for i in 0 ..< len(graph.indegree) { graph.indegree[i] = 0 }
	for connection in graph.connections {
		source_index, source_ok := graph_node_index_checked(graph, connection.source)
		target_index, target_ok := graph_node_index_checked(graph, connection.target)
		if !source_ok || !target_ok { return false }
		emits, emits_ok := node_output_type(graph.nodes[source_index].operation, connection.source_pin)
		accepts, accepts_ok := node_input_type(graph.nodes[target_index].operation, connection.target_pin)
		if !emits_ok || !accepts_ok || emits != accepts { return false }
		graph.indegree[target_index] += 1
	}
	for definition in graph.property_definitions {
		owner_index, owner_ok := graph_node_index_checked(graph, definition.owner)
		if !owner_ok { return false }
		want := node_property_type(graph.nodes[owner_index].operation, definition.property.key)
		if want == .Invalid || want != definition.property.value.kind { return false }
	}
	if graph_node_role_checked(graph, graph.sink) != .Sink { return false }

	clear(&graph.topological_order)
	clear(&graph.visit_stack)
	for node_index in 1 ..< len(graph.nodes) {
		if graph.nodes[node_index].active && graph.indegree[node_index] == 0 {
			append(&graph.visit_stack, Node_Handle{index = node_index, gen = graph.nodes[node_index].generation})
		}
	}
	queue_index := 0
	for queue_index < len(graph.visit_stack) {
		current := graph.visit_stack[queue_index]
		queue_index += 1
		append(&graph.topological_order, current)
		for connection in graph.connections {
			if connection.source == current {
				graph.indegree[connection.target.index] -= 1
				if graph.indegree[connection.target.index] == 0 { append(&graph.visit_stack, connection.target) }
			}
		}
	}
	if len(graph.topological_order) != active_count { return false }

	clear(&graph.inputs)
	clear(&graph.properties)
	for node_index in 1 ..< len(graph.nodes) {
		node := &graph.nodes[node_index]
		if !node.active { continue }
		node.inputs = Node_Range{first = len(graph.inputs)}
		for connection in graph.connections {
			if connection.target.index == node_index {
				data_type, ok := node_input_type(node.operation, connection.target_pin)
				assert(ok, "graph_compile: input type changed after validation")
				append(&graph.inputs, Node_Input{
					pin = connection.target_pin,
					source = connection.source,
					source_pin = connection.source_pin,
					data_type = data_type,
				})
				node.inputs.n += 1
			}
		}
		node.properties = Node_Range{first = len(graph.properties)}
		for definition in graph.property_definitions {
			if definition.owner.index == node_index {
				append(&graph.properties, definition.property)
				node.properties.n += 1
			}
		}
	}

	resize(&graph.reachable, len(graph.nodes))
	for i in 0 ..< len(graph.reachable) { graph.reachable[i] = false }
	clear(&graph.visit_stack)
	append(&graph.visit_stack, graph.sink)
	graph.reachable[graph.sink.index] = true
	cursor := 0
	for cursor < len(graph.visit_stack) {
		current := graph.visit_stack[cursor]
		cursor += 1
		for input in graph_node_inputs(graph^, current) {
			if !graph.reachable[input.source.index] {
				graph.reachable[input.source.index] = true
				append(&graph.visit_stack, input.source)
			}
		}
	}
	graph.compiled_generation = graph.generation
	return true
}

graph_node_role_checked :: proc(graph: ^Node_Graph, handle: Node_Handle) -> Node_Role {
	if node_index, ok := graph_node_index_checked(graph, handle); ok {
		return node_role(graph.nodes[node_index].operation)
	}
	return .Invalid
}

graph_node_inputs :: proc(graph: Node_Graph, handle: Node_Handle) -> []Node_Input {
	assert(handle.index > 0 && handle.index < len(graph.nodes), "graph_node_inputs: out of bounds")
	node := graph.nodes[handle.index]
	assert(node.active && node.generation == handle.gen, "graph_node_inputs: stale handle")
	return graph.inputs[node.inputs.first:node.inputs.first+node.inputs.n]
}

graph_node_properties :: proc(graph: Node_Graph, handle: Node_Handle) -> []Node_Property {
	assert(handle.index > 0 && handle.index < len(graph.nodes), "graph_node_properties: out of bounds")
	node := graph.nodes[handle.index]
	assert(node.active && node.generation == handle.gen, "graph_node_properties: stale handle")
	return graph.properties[node.properties.first:node.properties.first+node.properties.n]
}

graph_property :: proc(graph: Node_Graph, handle: Node_Handle, key: Node_Property_Key) -> (Node_Property, bool) {
	for property in graph_node_properties(graph, handle) {
		if property.key == key { return property, true }
	}
	return {}, false
}

graph_eval_text :: proc(graph: ^Node_Graph, character_count: int, out: []Text_Ink) -> int {
	assert(graph.compiled_generation == graph.generation, "graph_eval_text: compile candidate before evaluation")
	count := min(character_count, len(out))
	for index in 0 ..< count { out[index] = {} }
	for handle in graph.topological_order {
		if !graph.reachable[handle.index] || graph.nodes[handle.index].operation != .Text_Style { continue }
		start_property, has_start := graph_property(graph^, handle, .Character_Start)
		length_property, has_length := graph_property(graph^, handle, .Character_Length)
		reveal_property, has_reveal := graph_property(graph^, handle, .Reveal)
		color_property, has_color := graph_property(graph^, handle, .Ink_Color)
		assert(has_start && has_length && has_reveal && has_color, "Text_Style node is missing required property")
		start := int(start_property.value.integer)
		length := int(length_property.value.integer)
		for local in 0 ..< length {
			index := start + local
			if index < 0 || index >= count { continue }
			if !text_reveal_contains(reveal_property.value.reveal, local) {
				out[index].drawn = false
				continue
			}
			out[index].drawn = true
			out[index].color = [3]u8{color_property.value.color[0], color_property.value.color[1], color_property.value.color[2]}
		}
	}
	return count
}

text_graph_build :: proc(graph: ^Node_Graph, character_count: int, pieces: Text_Pieces_Range) -> bool {
	graph_init(graph)
	text_input := graph_node_add(graph, .Text_Input)
	style_start := len(graph.nodes)
	for piece in session_piece_view(pieces) {
		if piece.len < 0 || piece.start < 0 || piece.start > character_count { return false }
		style := graph_node_add(graph, .Text_Style)
		_, start_ok := graph_property_add(
			graph, style, .Character_Start,
			Node_Value{kind = .Integer, integer = i64(piece.start)},
		)
		_, length_ok := graph_property_add(
			graph, style, .Character_Length,
			Node_Value{kind = .Integer, integer = i64(piece.len)},
		)
		_, reveal_ok := graph_property_add(
			graph, style, .Reveal,
			Node_Value{kind = .Reveal, reveal = piece.reveal},
		)
		_, color_ok := graph_property_add(
			graph, style, .Ink_Color,
			Node_Value{
				kind = .Color,
				color = [4]u8{piece.color[0], piece.color[1], piece.color[2], 255},
			},
		)
		if !start_ok || !length_ok || !reveal_ok || !color_ok { return false }
	}
	renderer := graph_node_add(graph, .Text_Renderer)
	output := graph_node_add(graph, .Image_Output)
	graph.sink = output
	for style_index in style_start ..< renderer.index {
		style := Node_Handle{index=style_index, gen=graph.nodes[style_index].generation}
		if !graph_connect(graph, text_input, .Text, style, .Text) ||
			!graph_connect(graph, style, .Style, renderer, .Style) { return false }
	}
	if !graph_connect(graph, text_input, .Text, renderer, .Text) ||
		!graph_connect(graph, renderer, .Image, output, .Image) { return false }
	return graph_compile(graph)
}
