# Open decisions from the render-loop cadence run, with evidence

Three findings were left open after PRs #76, #77, #78 because they looked
like design calls. Evidence gathered 2026-09-05. One of them turned out to be
a bug with a one-line fix and zero impact on shipped examples, so it became
PR #79. The other two are real decisions and are laid out below with the
receipts and a recommendation.

## 1. A data-driven width has no supported route (finding 3)

Decision taken: option B. Landed as unmde/weaver#80 (stacked on #78).

### What happens today

`weaver check` requires every `class` to resolve statically to at most 32
literal strings (`cli/src/index.ts:835`), so it can validate every utility
before the widget runs. The resolver follows string literals, `const`
bindings, ternaries, `+` concatenation, and template literals whose holes are
themselves resolvable. A width computed from data, `w-[${px}px]`, resolves to
nothing and fails with:

```
class must resolve to at most 32 literal strings so weaver check can validate every utility
```

The message names the cap and not a route. Twenty agents building the same
progress bar produced six workarounds: `<canvas>` (14 runs), a 21-branch
ternary ladder of literal widths (3), a `w-N/20` fraction table (1), a
gradient hard stop at a computed fraction (1), and a 20-tick meter (1). All
twenty needed a data-driven width; none found the same door.

### What the runtime already does

- `compileClass` in `sdk/src/class-compiler.ts` runs at render time whenever
  an element's class string changes (`reconciler.ts:546-551`). It is the same
  compiler `check` uses. It parses `w-[43.7px]` to `{width: 43.7}` and rejects
  `w-[-5px]`, `w-[abcpx]`, `w-[1e3px]`, and `w-[15%]` with a named
  `UtilityError` and a suggestion. `w-[1000000px]` is accepted.
- An unknown utility at runtime throws through `runWidgetCallback`, which
  fails the widget onto its error surface. Capture reports it as
  `CaptureWidgetFailed` with the diagnostic. It is loud.
- Cost, measured with the compiler bundled in isolation: 1000 distinct
  dynamic class strings compile in 6.16 ms, about 6 µs each. A bar whose width
  changes once per second recompiles once per second.
- Twelve utilities accept a bracketed arbitrary value: `w`, `h`, `size`,
  `p`/`px`/`py`/…, `m`…, `gap`, `rounded`, `border`, `text`, `leading`,
  `tracking`, `grow`, `aspect`, `shadow`, `font`, `bg`/`from`/`via`/`to`.

### Options

**A. Keep the cap, fix the message.** Name the doors: `w-N/M` fractions for
quantized values, `<canvas>` for continuous geometry, the typed `background`
gradient hard stop. Zero runtime change. Agents still write 21-branch ladders
when the data is continuous, and every canvas bar is a semantic hole (no
node in the tree, pixels are its only receipt).

**B. Typed holes in arbitrary values (recommended).** Let a template hole
appear only inside a bracketed arbitrary value of a known utility, and only
when TypeScript types the hole as `number`: `w-[${px}px]` passes, `${cls}`
does not. `check` still knows every utility statically. The value is
validated at runtime by the same compiler, which already rejects bad values
loudly, at 6 µs per change. The check has a `TypeChecker` in hand already
(`cli/src/index.ts:2523`). Contract gains one sentence. This is the smallest
change that lets a progress bar be one `<stack>` with a real width.

**C. A `style` prop.** A parallel styling system for one use case. Two ways
to say width, two validators, two documentation surfaces. Not recommended.

### Evidence to run before B ships

A check unit test for the accepted and rejected hole shapes, and one capture
smoke where a `w-[${n}px]` bar re-renders across a tick and the snapshot
bounds move. Both are cheap and sit beside the tests added in #78.

## 2. `npx --no-install weaver` outside the repo tree (finding 6)

Decision taken: A and B together. Landed as unmde/weaver#82; the skill side is #81.

### What happens

From any directory inside the repo, including `examples/clock`, `npx
--no-install weaver` resolves the workspace bin (`node_modules/.bin/weaver`
→ `cli/bin/weaver.js`, version 0.1.0) and works. From `/tmp`, where every
experiment widget lived, npm walks up, finds no workspace, and consults the
registry:

```
npm error npx canceled due to missing packages and no YES option: ["weaver@0.3.1"]
```

That `weaver@0.3.1` is not ours. The public npm package `weaver` is an
"Interactive process management system" last published 2022-06-28. Without
`--no-install`, `npx weaver` in a widget directory would download and run a
stranger's package. `--no-install` is the only thing standing between an agent
following the skill and that outcome, and its failure message reads like our
CLI is missing. `weaver` is not on `PATH` (`which weaver`: not found), and
`weaver init` prints `Next: weaver check <dir>` as if it were.

Scoped names are free on the registry: `@weaver/cli`, `@weaver/sdk`, and
`@weaver/weaver` all return 404. The root `package.json` is `private: true`,
so nothing publishes today.

### Options

**A. Link the bin during setup (recommended, do now).** `npm run build`
already exists; add `npm link --workspace cli` (or a documented one-time
`npm link`) so `weaver` is on `PATH` for anyone who has built the repo. The
skill and `init`'s "Next:" line then say `weaver check <dir>` and mean it.
Keep `npx --no-install` as a fallback in the skill for unlinked checkouts,
with a sentence that it only works inside the repo tree.

**B. Rename the CLI package to a scoped name.** `@weaver/cli` with bin
`weaver`. Kills the registry collision permanently, so a future `npx
@weaver/cli` can never run someone else's code. Independent of A and worth
doing before anything publishes; irrelevant to the agents' failure until then.

**C. Absolute path in the skill.** `node <repo>/cli/bin/weaver.js`. Works
everywhere, ugly, and every doc that says `weaver …` still lies.

Recommendation: A now, B before first publish.

## 3. Small boxes get ~2px corner rounding (finding 4): a bug, fixed in #79

### What happens

Weaver maps an unset radius to `null` when projecting a painted box
(`runtime/src/main.zig:943`, `if (retained.radius > 0) … else null`), and
Native SDK reads `null` as "use the theme radius", whose smallest token is
6 px (`tokens.zig:385`). `rounded-[0px]` sets 0, which the same test treats
as unset. So every painted box without a `rounded-*` class is rounded, and
`rounded-[0px]` cannot turn it off. On a 320 px card that is invisible. On a
14 px progress segment it is a scallop, which is what two Opus agents saw and
one redesigned its bar around.

### Receipt

Probe `canvas-probe/../round`: five 8 px bars. Per-column count of accent
pixels, first 48 columns:

| Variant | master | unset-radius-is-zero |
|---|---|---|
| 20 gapless `grow` segments in a `rounded-full overflow-hidden` track | `468888888888863468888…` | `468888888888888888888…` |
| same, `rounded-[0px]` on each segment | `468888888888863468888…` | `888888888888888888888…` |
| same, no radius class | `468888888888863468888…` | `888888888888888888888…` |
| single fill | `468888888888888888888…` | `888888888888888888888…` |
| 20 `w-[14px]` segments | `468888888888634688888…` | `888888888888888888888…` |

On master every segment boundary loses two to four rows at both ends. With the
fix, only the track's own `rounded-full` clip rounds anything.

### Impact on shipped examples

Same widget sources, same fixtures, same clock, two runtime binaries built
from the same commit with only line 943 changed:

| Example | Pixels changed |
|---|---|
| clock | 0 of 42,240 |
| pomodoro | 0 of 103,200 |
| weather | 0 of 67,840 |
| system | 0 of 66,640 |
| now-playing | 0 of 52,800 |
| round probe | 796 of 38,400 |

Every shipped example specifies its radii. Nothing depends on the theme
default. The decision "unset radius means 0, like CSS" has no cost, so it is
not a decision. PR #79 makes the change, adds a runtime test that a painted
box without a rounded utility projects radius 0, and states the default in
the contract.
