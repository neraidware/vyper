# Node-Graph Compositor — Design (idea level)

Eventually every clip is a *composited clip*: a graph of nodes shown in a clip
compositor window. Nodes connect; one connection path lands on a **track** node
and the composited result appears as a timeline clip for traditional editing.

Example — text:
```
text-input → track
```

Example — plain video:
```
media-input → track
```

Example — video with transforms:
```
media-input → crop → scale → move → rotate → track
```

Not a node graph; the *fast path* below.

## Node taxonomy (keep it plain)

Three node kinds only:

- **source** — emits data: media input, text input, numeric input.
- **process** — data in → data out: crop, scale, move, rotate, color,
  text→image rasterizer.
- **sink / output** — the **track** node; where a composited result lands.

There is **no separate "renderer" node**. A process node is already "data in →
rendered image out"; a dedicated renderer added ceremony but no data. The sink
*is* the output.

## Node graph rules

- Late-style evaluation. Sources evaluate; processes transform; sink evaluates
  last and feeds the timeline.
- Detect and block cycles. Nodes form a DAG.
- One sink is the boundary: the subgraph between sources and one sink defines a
  reusable **composited asset**. The timeline holds **instances** (reference +
  position + trim + duration). Placing it twice reuses the graph, not clones it.

## Typed pins

Ports carry a data type; connect only where types match (else undefined):

- `text` (constant value)
- `image` / `video stream` (time-varying)
- `audio stream` (time-varying)
- `number` / `vector` (control values)

Media input emits a time-varying stream that addresses a **source frame range**
(temporal dimension). Text input is a constant. The evaluator handles both.

## Audio lives in the graph

Audio is not a separate disconnected system. Media input exposes an audio pin
(or forks into audio process nodes) so audio mixes inside the compositor,
matching the timeline model.

## Fast path — not every clip is a graph

Plain "media → track, no effect" is ~90% of clips. Forcing a DAG on each adds
allocation, frame-cache pressure, and latency, and complicates the current fast
decode+preview path. Keep the direct path for plain clips; attach a node chain
**only** when non-trivial (effects, generators). A composited clip is a clip
encoded as a small subgraph, not the universal representation.

## Fits the current model

`Clip.generator` (from the earlier text-generator step) already marks a clip
whose output is synthesized rather than decoded from a file. A composited clip
generalizes that: its render output is produced by its node subgraph.
