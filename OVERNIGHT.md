# Overnight log (20 to 21 Oct 2026)

Working through Kryštof's feedback from 22:47, most important first. Each finished piece is committed and pushed.

## Plan (in order)
1. Panels: fix jumpy bottom sheets when dragged slowly
2. Selection rule: fingers on the preview only move what is selected in the timeline
3. New text and media: plain white text, no shadow, no fade in/out
4. Typing text: keep the preview visible (compact editor above the keyboard)
5. Captions: tapping a caption opens the Text tab scrolled to that line
6. Motion blur: its own clip tool (not in Adjust), smoother preview
7. Apply to all clips / pick clips mode (timeline multi-select), used across panels
8. Keyframes for text and overlay move / scale / rotate
9. Social safe zones: real platform layouts (icons, username, caption zones)
10. Mask: edge softness, grow / shrink, invert; export the cut-out subject (transparent video) and a black & white matte
11. Czech translation: full rewrite in natural video-editing Czech, "keyframe" stays keyframe

## Done
- **Panels**: the drag handle now measures in screen space, so a slowly dragged panel no longer jitters (it was measuring in its own moving coordinates).
- **Selection rule**: the preview moves only what is selected in the timeline. Selected overlay → overlay. Captions selected → captions. Selected clip → that clip (only while the playhead is on it, otherwise nothing). Nothing selected → the clip at the playhead. Tapping the preview only plays / pauses.
- **Captions track selection**: tapping a caption in the timeline selects the captions (lime outline), opens the Text tab, scrolls to that line and starts editing it. With captions selected the toolbar shows Edit text, Style, Reset (when moved / turned) and Done; close the panel and drag / pinch / twist on the preview to place them.
- **Plain new text**: new text is plain white (no shadow, no outline, no box, no animation). Text, pictures and videos no longer fade in / out.
- **Typing**: while the keyboard is up the panel shrinks to just the text field (with a Done button) right above the keyboard, and the preview shrinks to fit above it. Works for text overlays and caption lines.

## Decisions
- No tap-to-select on the preview any more (you said: don't guess). Selection is only in the timeline. The hit-testing code stays in the model, unused, in case you want it back.
- With nothing selected, a gesture still moves the clip at the playhead and selects it (like CapCut's main track). Overlays and captions never move unless selected.

## Skipped / for the morning
