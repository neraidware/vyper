// The generic node-graph compositor.
//
// This is the shape `~/Notes/Vyper/node-graph.md` planned, built far enough to
// be USED rather than sketched: a text clip's per-piece styling is evaluated as
// a graph of nodes here, not as a field the rasterizer reads. The rasterizer
// asks this module what ink a character has and never learns what produced it.
//
// The taxonomy, and why the roles are separate (from the design note, which is
// the authority for this shape):
//
//	input      — a reusable DATA SOURCE: text, media, numeric. Emits its own
//	             type, never an image.
//	process    — data in → data out. The same data, annotated or transformed.
//	renderer   — the terminal that PROMOTES to image and emits exactly one output.
//	sink       — the track, where a composited result lands.
//
// The separation is not ceremony. A process node and a track both consume an
// image, and a text input emits TEXT, so a text chain can only reach a track
// through the step that rasterizes it. There is deliberately no `input → track`
// two-node chain, and the renderer is the only kind that produces an image.
//
// Edges are OPEN, not a hardcoded topology. Each node has a fixed number of
// input slots and each slot names any node and pin, which is what makes this a
// graph rather than a chain spelled with pointers — and it is also what makes
// cycles possible, so connect rejects them. A fixed `input → processes →
// renderer` layout could not cycle, and a cycle check on it would be theatre
// guarding nothing.
//
// TYPES ON PINS. `text` and `image` exist because the design names them and
// because they are the boundary this module exists to hold: a process that
// worked on text and one that worked on images would not be interchangeable, and
// a connection across that boundary is undefined rather than merely unusual.
package vyper

// Node_Kind is the closed set of node roles. Adding a kind is adding a case to
// node_pin_types and to the evaluator; there is no registry and no
// type-erased dispatch, because the set is ours and a switch says what is
// implemented rather than what is reachable.
Node_Kind :: enum {
	Text_Input,
	Style_Process,
	Text_Renderer,
}

// Node_Pin is the type a connection carries.
Node_Pin :: enum {
	Text,
	Image,
	// _COUNT is not a pin type; it exists so node_pin_types can state a kind's
	// arity without a second parallel table that could disagree with it.
	_COUNT,
}

// NODE_INPUT_SLOTS is how many inputs a node may take. Three is what the text
// topology needs (a renderer takes its source plus its styles) with room to
// spare; it is a per-node cost of one index, not a graph-wide cost.
NODE_INPUT_SLOTS :: 3

// GRAPH_SEEN_MAX bounds the visited set the cycle check uses. It is a stack guard
// on a graph walk, not a cap on what a graph may contain: connect allocates
// nothing, and the walk visits at most one entry per node. Sized well past any
// text graph's node count (pieces plus two).
GRAPH_SEEN_MAX :: 64

// Node_Input is one input slot: which node feeds it, and which of that node's
// outputs. NODE_NO_INPUT is an unconnected slot, which is legal — a process with
// no input yet is a graph under construction, not an error, and rejecting it
// would mean every edit had to wire both ends at once.
NODE_NO_INPUT :: -1

Node_Input :: struct {
	// from and to are node indices; pin is the type the FROM node emits, which is
	// the type this edge carries. A node has no slots and no input count: the
	// graph owns its edges, so nothing in a node's shape says how many things
	// feed it.
	//
	// That is not a detail. A per-node input ARRAY caps the shape at that many
	// inputs and makes a slot index mean "the k-th thing", which is a linear
	// chain wearing a graph's types: adding a fan-in is a struct change, and the
	// evaluator ends up walking positions rather than edges.
	from: int,
	to:   int,
	pin:  Node_Pin,
}

// Compositor_Node is one node. Params are named per KIND rather than unioned:
// a renderer has no character range and a style process has no sink, and a union
// would put both shapes in every node to save a few bytes on a struct that
// lives in a session arena.
Compositor_Node :: struct {
	kind: Node_Kind,
	// input_start/input_len is the CHARACTER RANGE a Style_Process applies to, in
	// the text's own coordinates. A process that worked on ranges is what lets
	// several of them compose over one string: each annotates the characters it
	// owns and passes the rest through untouched, so "these three letters are
	// red, those two are blue" is two nodes on one input rather than a rewritten
	// string.
	input_start: int,
	input_len:   int,
	// reveal: which of THIS range's characters are drawn, in range-local
	// coordinates. See Text_Piece's reveal for why it is local.
	reveal: Text_Reveal,
	// color: the ink for this range's characters. RGB only; the raster's alpha is
	// the glyph's antialiased coverage, which the renderer supplies.
	color: [3]u8,
}

// Text_Ink is what the graph resolves a character to: whether it is drawn, and in
// what ink. It is deliberately not a text or an image — this is the annotation
// layer, one step before the renderer promotes anything.
Text_Ink :: struct {
	drawn: bool,
	color: [3]u8,
}

// TEXT_INK_DEFAULT is the ink a character gets when nothing overrides it: drawn,
// in the colour the rasterizer has always written.
TEXT_INK_DEFAULT :: Text_Ink {
	drawn = true,
	color = TEXT_INK_DEFAULT_RGB,
}

// TEXT_INK_DEFAULT_RGB is white — what every text clip painted before any of this
// existed, and what a chain with no style process must still produce.
TEXT_INK_DEFAULT_RGB :: [3]u8{255, 255, 255}

// Node_Graph is a set of nodes plus the node that emits. The sink is the node the
// timeline asks for; everything else exists to feed it.
Node_Graph :: struct {
	// nodes are dynamic because a graph is BUILT per evaluation: what a composited
	// clip contains is known only once its chain is resolved. The allocator is the
	// bake's, not the graph's.
	nodes: [dynamic]Compositor_Node,
	// edges are the graph's connectivity, flat and unordered. A node may take any
	// number of inputs and may feed any number of outputs, which is what lets a
	// clip be a LINE today and a DAG the moment the user restructures it, with
	// neither shape special-cased anywhere.
	edges: [dynamic]Node_Input,
	sink:  int,
}

// node_pin_emits is what a kind outputs, and node_pin_accepts is what it takes,
// as two predicates rather than one proc returning a set: the sets have one or
// two members, and a proc returning a slice would have to point into its own
// stack frame, which Odin refuses.
//
// The pairing is the design's rule made mechanical: a renderer emits an image
// and takes text, so text cannot reach a track except through the step that
// rasterizes it. There is no kind that both takes and emits an image except the
// renderer, which is what makes "input -> track" impossible by construction
// rather than by convention.
node_pin_emits :: proc(kind: Node_Kind) -> Node_Pin {
	switch kind {
	case .Text_Input, .Style_Process:
		return .Text
	case .Text_Renderer:
		return .Image
	}
	return .Text
}

node_pin_accepts :: proc(kind: Node_Kind, pin: Node_Pin) -> bool {
	switch kind {
	case .Text_Input, .Style_Process, .Text_Renderer:
		return pin == .Text
	}
	return false
}

// graph_connect wires `from`'s output into `to`, refusing a connection whose pin
// types differ and one that would close a cycle. Returns false and changes
// nothing on refusal, so a caller wiring a graph cannot end up half-connected.
//
// There is no slot argument, because there are no slots: a node takes whatever
// the graph gives it, and the edge says what type it carries. That is what lets a
// clip be a chain and later become a branching DAG without the graph noticing --
// the difference is in how many edges exist, not in what a node is shaped like.
//
// The cycle check walks backwards from `from` through existing edges: if it can
// reach `to`, then adding this edge gives `to` a path to itself. That is the
// only question, and asking it at connect time is what keeps the evaluator's
// assumption -- that walking the graph terminates -- true by construction rather
// than by a second pass that hopes the first was correct.
graph_connect :: proc(graph: ^Node_Graph, from, to: int) -> bool {
	if from < 0 || from >= len(graph.nodes) || to < 0 || to >= len(graph.nodes) || from == to {
		return false
	}
	emits := node_pin_emits(graph.nodes[from].kind)
	if !node_pin_accepts(graph.nodes[to].kind, emits) {
		return false
	}
	seen_buffer: [GRAPH_SEEN_MAX]bool
	seen := seen_buffer[:min(len(graph.nodes), GRAPH_SEEN_MAX)]
	// from->to closes a cycle iff `to` can ALREADY reach `from`. The walk starts
	// at the target for exactly that reason.
	if graph_reaches(graph, to, from, seen) {
		return false
	}
	append(&graph.edges, Node_Input{from = from, to = to, pin = emits})
	return true
}

// graph_inputs_into collects the edges feeding `node`, in edge order. It is a
// scan because a composited clip is a handful of nodes and the alternative --
// per-node adjacency lists -- is the slot array again under another name.
graph_inputs_into :: proc(graph: ^Node_Graph, node: int) -> [dynamic]Node_Input {
	found := make([dynamic]Node_Input, 0, len(graph.edges))
	defer delete(found)
	for edge in graph.edges {
		if edge.to == node {
			append(&found, edge)
		}
	}
	return found
}

// graph_reaches reports whether `target` is reachable from `start` by following
// edges backwards.
//
// `seen` is the caller's, so a rejected connection allocates nothing: connect runs
// on every edge a user drags, and a walk that allocated a visited set per attempt
// would allocate per drag.
//
// Recursive because a graph's depth is its longest chain -- a handful of nodes for
// a clip -- and an explicit stack would be machinery for a depth that does not
// exist. `seen` is what makes it terminate on a malformed graph rather than on
// trust.
graph_reaches :: proc(graph: ^Node_Graph, start, target: int, seen: []bool) -> bool {
	if start == target {
		return true
	}
	if start < 0 || start >= len(graph.nodes) || start >= len(seen) || seen[start] {
		return false
	}
	seen[start] = true
	for edge in graph.edges {
		if edge.from == start && graph_reaches(graph, edge.to, target, seen) {
			return true
		}
	}
	return false
}

// graph_eval_text evaluates the graph for a text of `character_count` characters,
// resolving each character's ink into `out` and returning how many it filled.
//
// `out` and `order` are the caller's, sized before the call. Evaluation runs once
// per bake and allocates nothing, so both are reused across bakes like every
// other per-bake scratch in the rasterizer -- `order` included, because a walk
// that collected its own order would allocate per evaluation.
//
// Late-binding in the design's sense: the input supplies the characters, the
// processes annotate, and the renderer is what materialises an answer. It walks
// backwards from the sink, because the sink is the only node whose output anyone
// asked for; a node nothing upstream of the sink reaches is never evaluated.
graph_eval_text :: proc(
	graph: ^Node_Graph,
	character_count: int,
	out: []Text_Ink,
	order: ^[dynamic]int,
) -> int {
	count := min(character_count, len(out))
	// Nothing is drawn until a process says so. This is what makes a character in
	// a GAP -- one no piece claims -- come out unpainted, because no process ever
	// touches it. The alternative (defaulting to drawn, and having processes only
	// subtract) would need a process to also subtract from the gaps, which is the
	// same rule written twice and would let a gap be drawn by a piece that
	// overlaps its neighbour.
	//
	// The implicit-piece case, a clip with no pieces at all, is NOT a gap: it is
	// handled by text_pieces_ink building one whole-text process, so the fast path
	// still draws everything through the same graph as everything else.
	for i in 0 ..< count {
		out[i] = {}
	}
	clear(order)
	if graph.sink < 0 || graph.sink >= len(graph.nodes) {
		return count
	}
	seen_buffer: [GRAPH_SEEN_MAX]bool
	seen := seen_buffer[:min(len(graph.nodes), GRAPH_SEEN_MAX)]
	graph_eval_order(graph, graph.sink, order, seen)
	for node in order^ {
		switch graph.nodes[node].kind {
		case .Text_Input, .Text_Renderer:
			// The input supplies characters and the renderer emits the image; neither
			// annotates anything, so there is nothing to do at this layer. The
			// renderer is what consumes the result.
		case .Style_Process:
			style := graph.nodes[node]
			for local in 0 ..< style.input_len {
				index := style.input_start + local
				if index < 0 || index >= count {
					// A range past the end of the text is not an error: the text can be
					// shorter than the pieces describing it, and drawing what exists is
					// the whole of what this layer has to decide.
					continue
				}
				// An unset reveal on a node means ALL of the node's own characters,
				// the same rule session_piece_push normalises on the way in. Both
				// exist because a zero reveal cannot mean both "everything" and
				// "nothing": the store settles it at construction, and a node built
				// directly (by a future structural edit) settles it here.
				if style.reveal != (Text_Reveal{}) &&
				   !text_reveal_contains(style.reveal, local) {
					out[index].drawn = false
					continue
				}
				out[index].drawn = true
				out[index].color = style.color
			}
		}
	}
	return count
}

// graph_eval_order appends `node` and everything feeding it to `out`, sources
// first, so one forward pass evaluates a chain in the order it was built.
graph_eval_order :: proc(
	graph: ^Node_Graph,
	node: int,
	out: ^[dynamic]int,
	seen: []bool,
) {
	if node < 0 || node >= len(graph.nodes) || node >= len(seen) || seen[node] {
		return
	}
	seen[node] = true
	for edge in graph.edges {
		if edge.to == node {
			graph_eval_order(graph, edge.from, out, seen)
		}
	}
	append(out, node)
}

// text_graph_build wires a clip's piece list into the text topology the design
// note gives as its worked example, `text-input -> text-renderer -> track`, with
// a Style_Process per piece:
//
//	text_input ──┬─> style(piece 1) ─┐
//	            ├─> style(piece 2) ─┼─> text_renderer
//	            └─> style(piece N) ─┘
//
// Each style branches off the INPUT and fans into the renderer rather than
// chaining, and that is what makes per-piece styling compose: a process that
// worked on ranges could equally chain, but the fan shape is the one the design
// describes, and it is a DAG rather than a list -- so the cycle check has
// something real to reject.
//
// The input and the renderer are MATERIALIZED here rather than assumed, because
// the design's central claim is that they are separate roles and a text chain
// has no other route to an image. An implicit pair would make that claim
// untested: nothing would stop a process from growing an image output later.
//
// Returns false when a piece's range is malformed (negative length, or a start
// past the end of the text), which is a caller bug rather than a user error and
// so is reported, not repaired.
text_graph_build :: proc(graph: ^Node_Graph, character_count: int, pieces: Text_Pieces_Range) -> bool {
	// Every node goes into ONE array that the graph then owns. A build that
	// appends the input to a local and the styles to graph.nodes produces two
	// half-graphs, which is what the sink index then points into the wrong one.
	//
	// The array is built locally and MOVED in by assignment with no defer: freeing
	// a local by its own scope AND the graph by its later free is the same
	// allocation freed twice.
	nodes := make([dynamic]Compositor_Node, 0, pieces.n+2)
	append(&nodes, Compositor_Node{kind = .Text_Input})
	clear(&graph.edges)
	for piece in session_piece_view(pieces) {
		if piece.len < 0 || piece.start < 0 || piece.start > character_count {
			delete(nodes)
			return false
		}
		append(
			&nodes,
			Compositor_Node {
				kind = .Style_Process,
				input_start = piece.start,
				input_len = piece.len,
				reveal = piece.reveal,
				color = piece.color,
			},
		)
	}
	renderer := len(nodes)
	append(&nodes, Compositor_Node{kind = .Text_Renderer})
	graph.nodes = nodes
	graph.sink = renderer
	for style in 1 ..< renderer {
		if !graph_connect(graph, 0, style) {
			return false
		}
		if !graph_connect(graph, style, renderer) {
			return false
		}
	}
	// The renderer also takes the text itself, so a chain with no styles still
	// evaluates rather than being a sink fed by nothing.
	return graph_connect(graph, 0, renderer)
}

// text_graph_free releases the nodes a build allocated.
text_graph_free :: proc(graph: ^Node_Graph) {
	delete(graph.nodes)
	delete(graph.edges)
	graph.sink = -1
}
