# Focus Week — build report

**Condition:** C (progressive capture)

**Runs:** `weaver check` 7 · `weaver capture` 6

## Defects fixed because I saw pixels or a snapshot

- **Day letters unreadable.** Slice 2's PNG showed `M T W T F S S` at `text-[#f5f6f8]/40`
  sitting almost invisible on the `bg-[#ffffff]/6` chips at 1x. Raised to `/55`.
- **Button row would have been clipped.** Slice 3's snapshot put the progress block's
  bottom edge at y=136.75 with the content box ending at y=184. That left 35.25 px after
  the 12 px gap, so the buttons were sized `h-[34px]` instead of the 40–44 px I had
  sketched. The slice 4 snapshot confirms the row ends at y=182.75 — inside the box,
  nothing clipped.
- **Equal-width day cells confirmed, not guessed.** The slice 2 snapshot showed each cell
  at exactly 34.857143 px spanning x=20 to x=300, which validated the `w-[0px] grow`
  basis-zero idiom over the fixed-width fallback I had as plan B.
- **Progress fill geometry proved before wiring storage.** Slice 3 was captured with a
  temporary seed of 6 sessions so the fill had a visible length to inspect; the reverted
  zero state and the after-clicks 15% fill both match.

One defect was caught by `weaver check`, not pixels, and is noted only for completeness:
`CanvasNeedsExplicitSize` rejected `w-full` on the progress canvas (a canvas has no
intrinsic size). Fixed with the measured content width, `w-[280px]`.

## Spec items not met

None.

## Verification

- `04-initial.png` — empty week, every cell `0`, label `0 / 20`, empty track.
- `05-after-clicks.png` (the required action file) — Friday `3`, all other days `0`,
  label `3 / 20`, fill at 15% of the 280 px track (42 px). Receipt `status: "ok"`.
- `06-after-reset.png` (my own action file: two logs then Reset week) — every cell back
  to `0`, label `0 / 20`. Both captures also show the button under the cursor painting
  its `hover:` background, so the native state swaps are live.
- Snapshot accessible names are exactly `Log session` and `Reset week`.
- `widget_nodes=46/1024`, `canvas_frame_budget_exceeded=0`.

## Confidence

9 / 10. Everything in the spec is verified against pixels, the semantic snapshot, and an
"ok" receipt. The reserved point is for things the headless renderer cannot show me: the
`pressed:` styles are declared and pass check but I never captured a frame mid-press, and
`useStorage` persistence across a real restart is exercised only through the capture
harness's isolated storage, not an actual `weaver up` cycle.
