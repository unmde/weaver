# Focus Week — run report

**Condition:** B (write the whole widget first, capture only at the end, then loop).

**Runs:** `weaver check` 2 (both passed). `weaver capture` 5.

| capture | what it shows |
|---|---|
| `captures/01-initial.png` | first draft, initial state |
| `captures/02-after-clicks.png` | first draft, after 3 × "Log session" |
| `captures/03-initial.png` | final widget, initial state |
| `captures/04-after-clicks.png` | final widget, after 3 × "Log session" |
| `captures/05-reset.png` | final widget, 2 × "Log session" then "Reset week" (extra proof of the secondary button) |

All five receipts report `status: "ok"`, 46 nodes of 1024, no warnings beyond the
repo's own "uncommitted changes" provenance note.

## Defects fixed because I saw pixels or a snapshot

1. **Progress bar 2px short of the content box.** I had sized the canvas
   `w-[288px]` on the assumption that the root's 1px border eats into its
   content box. The snapshot's laid-out bounds proved otherwise: the root
   content box is `(15,14 290x172)`, so the bar's right edge stopped at x=303
   while the "3 / 20" label and the day row ended at x=305. Fixed to
   `w-[290px]`; the bar now ends at 305 (verified by pixel scan).
2. **Button row 2px short, same root cause.** "Reset week" ended at x=303
   against the 305 edge of everything above it. Widened the secondary button
   from 116px to 118px (164 + 8 + 118 = 290).
3. **Faint secondary text at 1× scale.** In the PNG the weekday letters
   (`text-[#f5f6f8]/35`), the header date and the "Sessions" label
   (`/45`) read washed out at real size. Raised all three to `/50`.
4. (Cosmetic, no measured change) The "N / 20" label became one template
   string instead of three text children. The rendered width was identical, so
   this is a code-tidiness change, not a fixed defect.

Nothing was clipped, overlapping, or misaligned in the vertical axis in either
draft: the root uses `justify-between`, and the four sections landed at
y=14/44.7/105.3/146 with the last ending exactly on the bottom padding edge.

## Spec items I could not meet

None. Every item is met and verified:

- 320×200, anchor top-right offset [24, 24], `subscribe: ["time"]` only, no
  network and no other provider.
- Header: "Focus week" left, "Fri, Sep 4" right, both `leading-[18px]` with
  `items-baseline`, so their boxes and baselines line up (the contract notes
  `items-baseline` is an end-alignment approximation; equal line heights make
  that approximation exact to within the descent difference).
- Seven Monday-first cells, each 36px wide with `justify-between` distributing
  the remainder, so the row always fills the content width edge to edge.
  Letter above count, zeros shown, today (Fri) highlighted with an
  `#ff7a59`/22 fill and an orange letter.
- Progress bar drawn on a `<canvas>` (the only way to express an arbitrary
  fraction, since `class` must resolve to static literals). The "N / 20" label
  is a sibling *above* the bar, so overlap is structurally impossible. The
  after-clicks capture measures the fill ending at x=58 out of 15..305 = 15%.
- Both buttons carry `hover:` and `pressed:` background swaps and explicit
  `accessibilityLabel`s. Snapshots show `role=button name="Log session"` and
  `name="Reset week"` exactly, and the action-driven captures show the hover
  channel actually swapping on the clicked button.
- Counts persist through `useStorage("sessions", …)`, a record keyed by the
  weekday short name that `TimeData.weekday` returns.
- Post-click state verified against the expected result: Friday 3, every other
  day 0, label "3 / 20", bar at 15%. Reset returns every day to 0 / 20.

## Confidence

**9 / 10.** Pixels, semantics and receipts all agree with the spec at the two
required states plus a reset state. The missing point is for what capture
cannot show me: the `pressed:` styles (no pressed-state capture exists) and
persistence across a real restart (capture always starts from an isolated
empty storage root).
