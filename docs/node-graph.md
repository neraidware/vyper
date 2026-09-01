# Node-Graph Compositor — Design (idea level)

Eventually every clip is a *composited clip*: a graph of nodes shown in a clip
compositor window. Nodes connect; one connection path lands on a **track** node
and the composited result appears as a timeline clip for traditional editing.

Example — text:
```
text-input → text-renderer → track
```

Example — plain video:
```
media-input → media-renderer → track
```

Example — video with transforms:
```
media-input → crop → scale → media-renderer → track
```

Not a node graph; the *fast path* below.

## Node taxonomy

Four node kinds:

- **input** — a reusable *data source*: media input, text input, numeric input.
  Emits its native type. Reusable across many chains.
- **renderer** — a *terminal* that consumes typed inputs and emits the
  composited **image** a track needs. It is the type-promoting / rasterizing
  step. Each renderer pairs conceptually with the data it promotes
  (text-renderer rasterizes text→image; media-renderer emits the decoded
  image).
- **process** — data in → data out: crop, scale, move, rotate, color.
- **sink / output** — the **track** node; where a composited result lands.

## Why input and renderer stay separate

They are different roles, not ceremony:

- **Reusability / arity**: an input is a pure provider; one text (or media)
  input can feed several different renderers or chains without duplicating the
  source. A renderer is an aggregator/terminal — it has inputs for the data
  plus its params, and exactly one output.
- **Type promotion**: a process node and a track both consume an **image**. A
  text input emits `text`, not an image, so it can only reach the track through
  a renderer that rasterizes text→image. Merging input+renderer into "any node
  that outputs an image" would force every text consumer to also do text→image
  and would erase the reusable-data-source distinction.

So: no two-node chain is "input → track"; every input reaches a track through a
renderer that promotes its data to image. Only process nodes sit between.

## Node graph rules

- Late-style evaluation. Inputs evaluate; processes transform; the renderer
  emits the image; the sink evaluates last and feeds the timeline.
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
