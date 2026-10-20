# Overnight log (20 to 21 Oct 2026)

Finished at 01:15. Every item below is done, built green on CI and pushed. Working through Kryštof's feedback from 22:47, most important first. Each finished piece is committed and pushed.

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
- **Motion blur** is its own clip tool (wind icon, next to Adjust), out of Adjust. Strength slider plus direction (both ways / forward / backward). Old projects carry their motion blur over automatically.
- **Motion blur speed**: the frame engine was working on the source frames (4K from the iPhone camera). It now works at the output size for export and at 60 % of it in the editor, scaled back up. That is roughly 4 to 10 times less work per frame, so the editor should keep up frame by frame. Same change for smooth slow motion.
- **Apply to all / Pick clips**: under Motion blur, Adjust, Speed, Volume and Mask. "All clips" copies right away. "Pick clips" closes the panel; the timeline spreads the clips apart, you tap the ones you want (lime with a check, the source clip has a dashed outline and a star), then Apply. "All" picks every clip. Undo works as one step.
- **Keyframes for text and overlays**: with an overlay selected, the diamond adds / removes a keyframe for its position, scale, rotation and opacity (hold it for smooth / linear, delete, previous / next). Moving the overlay or the opacity slider edits the keyframe under the playhead, or adds one, same as clips. Diamonds show on the overlay's block in the timeline.
- **Social layouts**: instead of a dimmed box, the preview now shows a see-through copy of the app's real screen (Reels, TikTok, Shorts, Stories): the side buttons with counts, avatar + username, caption lines, music line, top bar, Stories header and reply bar, positioned from your reference screenshots. It appears while you move a title, briefly when you pick an app, and the dropdown has "Always show" to keep it on.
- **Mask**: new Edge controls (softness, shrink / grow, invert) and Background (blur, darken, black & white). New "Use the cut-out elsewhere": Transparent video (subject only, HEVC with alpha .mov, works in Final Cut, DaVinci, CapCut, Keynote) or Matte (white subject on black, H.264). Both use the more accurate person model at higher detail, then Save or share (Files, AirDrop, etc.). Mask settings are also in Apply to.
- **Czech**: went through every string again and rewrote it in the Czech people actually use for editing (keyframe stays keyframe, motion blur, tracking, bitrate; "Překrytí", "Prolínačka", "Viněta", "Resetovat", progress as nouns like "Stahování 45 %" instead of "Stahuji"). Engine errors and the default project name ("Project 21. 10. 9:00" / "Projekt …") are now translated too.
- **New text**: adding text opens its panel with the keyboard already up; the word "Text" clears as soon as you start typing (and comes back if you leave it empty).
- **Apply to for overlays**: the overlay panel has Apply to as well: copies a text's look (font, colors, size, outline, box, animation) plus blend, opacity and "behind subject" to all overlays or the ones you tap in the overlay lane. Position is never copied.
- **Video overlays have sound** now, with a volume slider in their panel (0 mutes).
- Panel tweaks from simulator checks: Apply to buttons no longer get cut off; mask panel scrolls.
- **Snapping to the app layout**: while you move a title or the captions, its edges snap (with a tick and a guide line) to the edge of the area the picked app leaves free: left of the button column, above the username / caption, below the top bar. It is only a magnet, you can still put things anywhere.
- Fixed two untranslated buttons in the Speed panel (Add at playhead, Delete).
- **Fit / Fill all**: hold Fit or Fill in the clip toolbar for "Fit all clips" / "Fill all clips".

## Decisions
- No tap-to-select on the preview any more (you said: don't guess). Selection is only in the timeline. The hit-testing code stays in the model, unused, in case you want it back.
- Adjust copies what you see at the playhead (if the source clip has keyframes, their current value), and overwrites the target clips' color in all their keyframes. Transform (position / scale) is never copied.
- Speed copies the speed or curve, keep pitch and smooth slow motion; captions and overlays follow their footage as usual.
- PNG sequence / GIF: skipped in favor of HEVC with alpha. One .mov keeps full quality and frame timing, imports straight into every editor, and is far smaller than hundreds of PNGs. GIF has only 1-bit transparency and looks bad.
- The cut-out / matte files cover the clip's trimmed source (speed changes are not baked in), long side up to 1920 px.
- Motion blur in Czech stays "Motion blur" (like keyframe), since that is what Czech editors say.
- Stabilize and Track are not in Apply to: they are measured per clip.
- With nothing selected, a gesture still moves the clip at the playhead and selects it (like CapCut's main track). Overlays and captions never move unless selected.

## Skipped / for the morning
- **Test on the iPhone** (can't be done from here; the simulator has no Video Toolbox frame engine and no real keyboard):
  1. Motion blur: does it now play frame by frame in the editor? Does the export look as good as before?
  2. Typing text / caption lines: panel shrinks above the keyboard, preview stays visible.
  3. Drag a panel slowly by its handle: no more jumping.
  4. Selection rule: with an overlay selected, then a clip selected, then nothing selected.
  5. Pick clips: Motion blur → Pick clips → tap clips → Apply.
  6. Mask → Transparent video → open it in DaVinci or CapCut to check the alpha.
- **Feedback email**: the Send feedback button stays hidden until you tell me which address to use.
- **App Store Connect**: create the two in-app purchases (free "7-day Free Trial" and the 149 Kč unlock). Not touched.
- **Outro clip**: waiting for your video.
