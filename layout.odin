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
SWITCH_W :: f32(40)        // Binary toggle (switch_toggle) track width.
SWITCH_H :: f32(22)        // Binary toggle (switch_toggle) track height.
SWITCH_KNOB :: f32(16)     // Binary toggle (switch_toggle) knob diameter.
// Gain knob: circular dial sized to sit beside its dB value field in the
// clip card; the shader's exact circle needs cornerRadius = half the size.
KNOB_DIAMETER :: f32(30)
KNOB_VALUE_W :: 84         // gain value field width (keeps the knob row one line).
GAIN_KNOB_SWEEP_DEG :: 90.0    // pointer half-sweep from 12 o'clock (deg): -90 at min
                               // (9 o'clock) .. +90 at max (3 o'clock); 0 dB = straight up.
GAIN_KNOB_NEEDLE_LEN :: 0.75   // needle total length as a fraction of the diameter.
GAIN_KNOB_NEEDLE_W :: 2.5      // capsule thickness (px).
GAIN_KNOB_HUB_R :: 3.0         // center hub radius (px), anchors the needle.
// Opacity slider: a horizontal bar in the clip card. The container is the
// click target (tall, so it's easy to grab); TRACK_H is the visible bar inside
// it, vertically centered. The filled portion is the value.
OPACITY_TRACK_H :: f32(6)
TAB_H :: f32(24)           // Bottom-of-panel view-separator tab height.

// Corner radii (visual hierarchy: container > panel > widget > button).
RADIUS_CONTAINER :: 8
RADIUS_PANEL :: 6
RADIUS_WIDGET :: 4
RADIUS_BUTTON :: 2

// Font sizes.
FONT_RULER :: 11
FONT_TOOLTIP :: 12
FONT_SMALL :: 13 // secondary / labels / headers
FONT_NORMAL :: 14 // body text, buttons
FONT_DATA :: 15  // numeric/property values
FONT_HEADING :: 18 // track names, clip labels, big buttons

// Fixed structural sizes.
GUTTER_WIDTH :: 140        // Track-name / ruler-gutter column width.
CLIP_TILE_HEIGHT :: f32(36) // Height of one timeline clip tile. Shrunk from 56 so
                                // more tracks fit on screen; the track-name gutter
                                // is text-only now (duplicate/delete moved to the
                                // track context menu), so nothing in the row needs
                                // the old button-height budget.
TRACK_ROW_H :: CLIP_TILE_HEIGHT // One track row is exactly one clip tile tall, so
                                // the clip lane and its name gutter can never
                                // disagree on where a row ends. A track carrying
                                // keyframed clips grows by KF_ROW_H per lane (see
                                // kf_rows_for). Fixed (not measured) so track-list
                                // scroll geometry stays a pure function of the
                                // track count and their keyframe lane counts,
                                // never of layout timing.
TRACK_GAP_H :: 8           // Height of the insert gap above each track row.
// Keyframe lanes: one KF_ROW_H strip below a keyframed clip tile holds that
// clip's keyframe diamonds; a track row grows by KF_ROW_H per lane the tallest
// clip in it carries. A diamond is the 45°-rotated square SDF (KF_DIAMOND_ROT),
// corners rounded just enough to stay crisp.
KF_ROW_H :: f32(18)        // One keyframe lane height.
KF_DIAMOND_R :: f32(4)     // Half of the diamond's bounding square (8px across).
KF_DIAMOND_ROT :: [2]f32{0.70710678, 0.70710678} // cos/sin of 45°: squares up at the screen.
KF_DIAMOND_CORNER :: 2     // Diamond corner rounding, keeps a point on each axis.
KF_DIAMOND_BORDER :: 1     // 1px border, drawn inside the diamond.
KF_HIT_MARGIN :: f32(6)    // Diamond pick radius: pointer within this of a key's center selects it.
// Pointer travel (px) from a diamond press before the gesture counts as a drag.
// Below this the press is just a click and must never nudge the key, so the key
// only moves on a deliberate click+drag.
KF_DRAG_THRESHOLD_PX :: f32(3)
// Two diamond presses on the SAME key (track, clip, lane, frame) within this
// window are a double-click: the playhead jumps to that key's frame.
KF_DBL_CLICK_NS :: i64(400_000_000)
// Inspector "add keyframe" button: the same 45°-rotated-square keyframe look
// (KF_DIAMOND_* above), scaled to sit beside a property field. The painted
// diamond is the button's only graphics; the clay box beneath carries the id
// for hit-testing and adds a little click padding around the glyph. Sized to
// the timeline keyframe diamond so a created key reads exactly like its row
// did on the timeline.
KF_BTN_R :: KF_DIAMOND_R   // Half of the add-keyframe button diamond (8px across).
KF_BTN_PAD :: f32(3)       // Transparent click padding around the button diamond.
// Inspector add-keyframe buttons, one per keyable property in row order: the
// element ids are hit-tested in interaction.odin and painted as diamonds in
// gpu_draw.odin, so they live here as the single source of truth.
KF_ADD_BTN_IDS :: [11]string{
	"KfAddX", "KfAddY", "KfAddS",
	"KfAddCropL", "KfAddCropR", "KfAddCropT", "KfAddCropB",
	"KfAddGain",
	"KfAddTrans", "KfAddCrop",
	"KfAddModified",
}
// The whole-GROUP add-keyframe buttons: key every lane of a property section
// at once (transform = x+y, crop = l+r+t+b) instead of one lane. Drawn as a
// 2x2 diamond cluster in gpu_draw.odin to read as "all lanes" against the
// single per-lane diamond.
KF_GROUP_BTN_IDS :: []string{"KfAddTrans", "KfAddCrop"}

// KfAddModified keys EVERY geometry lane that was edited without a keyframe
// (Clip.geom_modified, set by clip_geom.odin) in one undo node. It is the
// answer to the question the per-lane diamonds create: a user who pans a plain
// clip with Alt+drag and then wants to animate it would otherwise have to
// click seven diamonds, and the reasonable assumption is that the gesture
// already recorded something. Disabled (not merely inert) when nothing is
// pending, so it is lit exactly when pressing it would do something.
KF_ADD_MODIFIED_ID :: "KfAddModified"
CLIP_GRAB :: f32(7)        // Left/right edge grab band on a clip (duration resize).
TSCROLLBAR_W :: f32(10)    // Width of the timeline's vertical scrollbar strip.
TSCROLLBAR_MIN_H :: f32(28) // Smallest rendered scrollbar thumb.

// App chrome: the top app bar and the editor column band that sits between it
// and the timeline (Media | Preview | Inspector).
APP_BAR_H :: f32(44)       // Top app bar strip (app name, project, help).
EDITOR_DIVIDER_H :: f32(16) // Grab strip between the editor column band and the timeline.
TIMELINE_BAR_H :: f32(36)  // Timeline bottom bar height (snap toggles, zoom).
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

// Preview overlay: the fit-to-window toggle floats in the preview's top-right
// corner, inset by this margin.
PREVIEW_FIT_MARGIN :: f32(8)

// Text input field glyph size (shared by the popup layout and the caret draw).
TEXT_INPUT_FONT :: u16(18)

// Command-line prompt (":") geometry: a pill bar half the window's width, one
// font-height tall plus half a font of vertical padding around the text, with
// a fully-round accent border.
CMDLINE_WIDTH_FRAC :: 0.5
CMDLINE_PAD_FRAC :: 0.5 // of TEXT_INPUT_FONT: padding above/below the text
