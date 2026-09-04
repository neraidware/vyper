package main

// ---------------------------------------------------------------------------
// Shared UI layout constants. Centralizing the sizing/spacing/font/radius
// vocabulary that the Clay UI tree (ui.odin) and the overlay draw code
// (gpu_draw.odin) use, so the same visual treatment is defined once.
// Values keep the original look — these unify what was already consistent and
// name what was previously a bare literal.
// ---------------------------------------------------------------------------

// Spacing.
PANEL_PADDING :: 16   // PaddingAll on every card/panel.
TIMELINE_PADDING :: 12 // PaddingAll on the timeline container + open-file button.
CARD_GAP :: 8         // childGap inside every card/panel.
BUTTON_ROW_GAP :: 6   // childGap between sibling controls in a row.
SECTION_GAP :: 16     // childGap between major panels/columns.

// Button geometry.
BUTTON_HEIGHT :: f32(28)   // Small action buttons (transport, settings, menu rows).
BUTTON_H_PAD :: 10         // Padding{left/right} inside small buttons/fields.

// Corner radii (visual hierarchy: container > panel > widget > button).
RADIUS_CONTAINER :: 10
RADIUS_PANEL :: 8
RADIUS_WIDGET :: 6
RADIUS_BUTTON :: 4

// Font sizes.
FONT_RULER :: 11
FONT_TOOLTIP :: 12
FONT_SMALL :: 13 // secondary / labels / headers
FONT_NORMAL :: 14 // body text, buttons
FONT_DATA :: 15  // numeric/property values
FONT_HEADING :: 18 // track names, clip labels, big buttons

// Fixed structural sizes.
GUTTER_WIDTH :: 140        // Track-name / ruler-gutter column width.
CLIP_TILE_HEIGHT :: f32(56) // Height of one timeline clip tile.
CLIP_GRAB :: f32(7)        // Left/right edge grab band on a clip (duration resize).

// Text input field glyph size (shared by the popup layout and the caret draw).
TEXT_INPUT_FONT :: u16(18)
