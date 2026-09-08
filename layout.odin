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
TRACK_ROW_H :: f32(64)     // Height of one full timeline track row (fixed, so track
                           // list scroll geometry is a pure function of the track
                           // count and never re-derived from laid-out boxes).
TRACK_GAP_H :: 18          // Height of the insert gap above each track row.
CLIP_GRAB :: f32(7)        // Left/right edge grab band on a clip (duration resize).
TSCROLLBAR_W :: f32(10)    // Width of the timeline's vertical scrollbar strip.
TSCROLLBAR_MIN_H :: f32(28) // Smallest rendered scrollbar thumb.

// App chrome: the top app bar and the editor column band that sits between it
// and the timeline (Media | Preview | Inspector).
APP_BAR_H :: f32(44)       // Top app bar strip (app name, project, help).
TIMELINE_BAR_H :: f32(36)  // Timeline toolbar above the ruler (snaps, zoom).
INSPECTOR_MIN_W :: 296     // Right inspector column width bounds.
INSPECTOR_MAX_W :: 356
FIELD_H :: f32(30)         // Inline property field (X/Y/Scale/crop) height.
LABEL_W :: f32(58)         // Text label width inside a property field.

// Media bin grid (file-manager style thumbnail cells).
MEDIA_CELL_W :: f32(120)  // Base cell width; columns derive from the bin width.
MEDIA_ITEM_PAD :: f32(4)  // Inner padding of a cell.
MEDIA_THUMB_H :: 68       // Thumbnail area height inside a cell (16:9 box above the label).
MEDIA_LABEL_H :: f32(16)  // Basename line height under the thumbnail.
MEDIA_BIN_MIN_W :: 210    // MediaBin column sizing bounds (wider than before so the
MEDIA_BIN_MAX_W :: 360    // grid can reach 2 columns without cramping).

// Text input field glyph size (shared by the popup layout and the caret draw).
TEXT_INPUT_FONT :: u16(18)
