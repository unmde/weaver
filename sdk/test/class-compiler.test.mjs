import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { classUsesGradientBackground, compileClass } from "../src/class-compiler.ts";
import { tailwindColors } from "../src/tailwind-colors.js";

test("class compiler maps the frozen M1 utility surface", () => {
  assert.deepEqual(
    compileClass("p-4 gap-[3px] rounded-2xl bg-[#123]/50 text-[#abcdef] grow w-12 truncate"),
    {
      padding: 16,
      gap: 3,
      radius: 16,
      background: "#11223380",
      textColor: "#ABCDEFFF",
      grow: 1,
      width: 48,
      truncate: true,
    },
  );
});

test("linear gradient utilities compile to the canonical retained wire", () => {
  assert.equal(classUsesGradientBackground("p-2 bg-linear-to-r from-black to-white"), true);
  assert.equal(classUsesGradientBackground("bg-repeating-gradient-to-b from-black to-white"), true);
  assert.equal(classUsesGradientBackground("bg-black from-black to-white"), false);
  const compiled = compileClass("bg-gradient-to-tr from-red-500 from-10% via-white/50 via-[45%] to-blue-500 to-90%");
  const document = JSON.parse(compiled.backgroundGradient);
  assert.equal(document.v, 1);
  assert.equal(document.layers.length, 1);
  assert.deepEqual(document.layers[0].start, [0, 1]);
  assert.deepEqual(document.layers[0].end, [1, 0]);
  assert.deepEqual(document.layers[0].stops, [
    { offset: 0.1, color: "#FB2C36FF" },
    { offset: 0.45, color: "#FFFFFF80" },
    { offset: 0.9, color: "#2B7FFFFF" },
  ]);
  assert.equal(document.layers[0].spread, "pad");

  const repeating = JSON.parse(compileClass("bg-repeating-linear-to-r from-black to-white").backgroundGradient);
  assert.equal(repeating.layers[0].spread, "repeat");
});

test("gradient utilities reject incomplete axes and orphan stops", () => {
  assert.throws(() => compileClass("bg-gradient-to-r from-red-500"), /requires both from-<color> and to-<color>/);
  assert.throws(() => compileClass("from-red-500 to-blue-500"), /require bg-gradient-to-\*/);
});

test("unknown utilities carry an actionable fix-it", () => {
  assert.throws(() => compileClass("pad-13"), /Unknown class utility "pad-13"\. Did you mean "p-\[13px\]"\?/);
});

test("arbitrary uniform padding returns its compiled value", () => {
  assert.deepEqual(compileClass("p-[13px]"), { padding: 13 });
});

test("styling 01 accepts directional spacing sizing fractions and aspect ratios", () => {
  assert.deepEqual(
    compileClass("p-2 px-4 pt-[3px] m-2 -mx-1 mb-[5px] w-1/2 h-full min-w-12 max-w-[160px] min-h-4 max-h-20 aspect-[4/3]"),
    {
      padding: 8,
      paddingLeft: 16,
      paddingRight: 16,
      paddingTop: 3,
      marginTop: 8,
      marginRight: -4,
      marginBottom: 5,
      marginLeft: -4,
      widthPercent: 50,
      heightPercent: 100,
      minWidth: 48,
      maxWidth: 160,
      minHeight: 16,
      maxHeight: 80,
      aspectRatio: 4 / 3,
    },
  );
  assert.deepEqual(compileClass("px-4 p-2"), { padding: 8 });
  assert.deepEqual(compileClass("w-full w-12 w-auto h-1/4 size-[20px]"), { width: 20, height: 20 });
  assert.deepEqual(compileClass("aspect-video aspect-auto aspect-square"), { aspectRatio: 1 });
  assert.deepEqual(compileClass("w-0 h-[0px] max-w-0 max-h-[0px]"), {
    width: 0, height: 0, maxWidth: 0, maxHeight: 0,
  });
});

test("styling 01 utility families each have an accept case", () => {
  const cases = [
    ["px-1", { paddingLeft: 4, paddingRight: 4 }],
    ["py-[3px]", { paddingTop: 3, paddingBottom: 3 }],
    ["pt-1", { paddingTop: 4 }], ["pr-1", { paddingRight: 4 }],
    ["pb-1", { paddingBottom: 4 }], ["pl-1", { paddingLeft: 4 }],
    ["m-1", { marginTop: 4, marginRight: 4, marginBottom: 4, marginLeft: 4 }],
    ["mx-1", { marginLeft: 4, marginRight: 4 }],
    ["my-1", { marginTop: 4, marginBottom: 4 }],
    ["mt-1", { marginTop: 4 }], ["mr-1", { marginRight: 4 }],
    ["mb-1", { marginBottom: 4 }], ["ml-1", { marginLeft: 4 }],
    ["-m-[2px]", { marginTop: -2, marginRight: -2, marginBottom: -2, marginLeft: -2 }],
    ["w-full", { widthPercent: 100 }], ["h-3/4", { heightPercent: 75 }],
    ["w-4 w-auto", {}], ["h-full h-auto", {}],
    ["size-3", { width: 12, height: 12 }],
    ["size-[7px]", { width: 7, height: 7 }],
    ["size-full", { widthPercent: 100, heightPercent: 100 }],
    ["min-w-2", { minWidth: 8 }], ["min-h-[9px]", { minHeight: 9 }],
    ["max-w-10", { maxWidth: 40 }], ["max-h-[11px]", { maxHeight: 11 }],
    ["aspect-square", { aspectRatio: 1 }], ["aspect-video", { aspectRatio: 16 / 9 }],
    ["aspect-[3/2]", { aspectRatio: 1.5 }], ["aspect-[1.25]", { aspectRatio: 1.25 }],
    ["aspect-square aspect-auto", {}],
  ];
  for (const [utility, expected] of cases) assert.deepEqual(compileClass(utility), expected, utility);
});

test("cross-axis stretch is the explicit CSS-default utility", () => {
  assert.deepEqual(compileClass("items-start items-stretch"), { crossAlign: "stretch" });
});

test("styling 01 rejects malformed new utilities with fix-its", () => {
  assert.throws(() => compileClass("w-3/0"), /Unknown class utility "w-3\/0"\. Did you mean/);
  assert.throws(() => compileClass("w-0/1"), /Unknown class utility "w-0\/1"\. Did you mean/);
  assert.throws(() => compileClass("w-3/2"), /Unknown class utility "w-3\/2"\. Did you mean/);
  assert.throws(() => compileClass("aspect-[4/0]"), /Unknown class utility "aspect-\[4\/0\]"\. Did you mean/);
  assert.throws(() => compileClass("-pt-4"), /Unknown class utility "-pt-4"\. Did you mean/);
  assert.throws(() => compileClass("px-[-1px]"), /Unknown class utility "px-\[-1px\]"\. Did you mean/);
  assert.throws(() => compileClass("mx-[2rem]"), /Unknown class utility "mx-\[2rem\]"\. Did you mean/);
  assert.throws(() => compileClass("size-auto"), /Unknown class utility "size-auto"\. Did you mean/);
  assert.throws(() => compileClass("min-w-full"), /Unknown class utility "min-w-full"\. Did you mean/);
  assert.throws(() => compileClass("aspect-[0]"), /requires an aspect ratio greater than zero/);
  assert.throws(() => compileClass(`p-[${"9".repeat(400)}px]`), /non-finite or absurd numeric value/);
  assert.throws(() => compileClass("w-[1000001px]"), /non-finite or absurd numeric value/);
  assert.throws(() => compileClass("aspect-[1000001]"), /non-finite or absurd numeric value/);
});

test("styling 02 accepts complete flex utilities and rejects near misses", () => {
  const cases = [
    ["justify-around", { mainAlign: "around" }],
    ["justify-evenly", { mainAlign: "evenly" }],
    ["grow-3", { grow: 3 }],
    ["grow-[2.5]", { grow: 2.5 }],
    ["shrink", { shrink: 1 }],
    ["shrink-0", { shrink: 0 }],
    ["self-auto", { alignSelf: "auto" }],
    ["self-start", { alignSelf: "start" }],
    ["self-center", { alignSelf: "center" }],
    ["self-end", { alignSelf: "end" }],
    ["self-stretch", { alignSelf: "stretch" }],
    ["flex-wrap", { flexWrap: true }],
    ["flex-wrap flex-nowrap", { flexWrap: false }],
  ];
  for (const [utility, expected] of cases) assert.deepEqual(compileClass(utility), expected, utility);
  assert.throws(() => compileClass("justify-space-around"), /Unknown class utility/);
  assert.throws(() => compileClass("shrink-2"), /Unknown class utility/);
  assert.throws(() => compileClass("self-baseline"), /Unknown class utility/);
  assert.throws(() => compileClass("flex-wrap-reverse"), /Unknown class utility/);
  assert.throws(() => compileClass("grow-1000001"), /non-finite or absurd numeric value/);
  assert.throws(() => compileClass(`grow-[${"9".repeat(400)}]`), /non-finite or absurd numeric value/);
});

test("styling 03 accepts per-corner radii and border utilities", () => {
  const cases = [
    ["rounded-t-xl", { radiusTopLeft: 12, radiusTopRight: 12 }],
    ["rounded-r-[3px]", { radiusTopRight: 3, radiusBottomRight: 3 }],
    ["rounded-b", { radiusBottomLeft: 4, radiusBottomRight: 4 }],
    ["rounded-l-full", { radiusTopLeft: 9999, radiusBottomLeft: 9999 }],
    ["rounded-tl-lg", { radiusTopLeft: 8 }], ["rounded-tr-md", { radiusTopRight: 6 }],
    ["rounded-br-2xl", { radiusBottomRight: 16 }], ["rounded-bl-[7px]", { radiusBottomLeft: 7 }],
    ["border", { borderWidth: 1, borderColor: "#E5E7EBFF" }],
    ["border-2", { borderWidth: 2, borderColor: "#E5E7EBFF" }],
    ["border-[1.5px]", { borderWidth: 1.5, borderColor: "#E5E7EBFF" }],
    ["border-[#123]", { borderColor: "#112233FF" }],
    ["border-[#112233]/50", { borderColor: "#11223380" }],
  ];
  for (const [utility, expected] of cases) assert.deepEqual(compileClass(utility), expected, utility);
  assert.deepEqual(compileClass("rounded-xl rounded-t-[36px] rounded-b-[4px]"), {
    radius: 12, radiusTopLeft: 36, radiusTopRight: 36, radiusBottomLeft: 4, radiusBottomRight: 4,
  });
  assert.deepEqual(compileClass("rounded-t-xl rounded-lg"), { radius: 8 });
  assert.deepEqual(compileClass("border-[#123456] border-4"), { borderColor: "#123456FF", borderWidth: 4 });
});

test("styling 03 rejects malformed radii and borders", () => {
  for (const utility of ["rounded-x-lg", "rounded-t-7", "rounded-t-[-1px]", "border--1", "border-[2rem]", "border-[#12]"]) {
    assert.throws(() => compileClass(utility), /Unknown class utility/, utility);
  }
  assert.throws(() => compileClass("border-[#123456]/101"), /Color alpha must be between 0 and 100/);
});

test("styling 04 table pins Tailwind v4.3.3 sRGB8 spot values", () => {
  const families = ["red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan", "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose", "slate", "gray", "zinc", "neutral", "stone", "mauve", "olive", "mist", "taupe"];
  const shades = ["50", "100", "200", "300", "400", "500", "600", "700", "800", "900", "950"];
  const expectedKeys = [...families.flatMap((family) => shades.map((shade) => `${family}-${shade}`)), "white", "black", "transparent"].sort();
  assert.deepEqual(Object.keys(tailwindColors).sort(), expectedKeys);
  assert.equal(
    createHash("sha256").update(JSON.stringify(tailwindColors)).digest("hex"),
    "33fed15753dbaa945464a7346d1c9a54d61c6cf1b98387d1e6c82f6c3344b2b5",
  );
  assert.equal(tailwindColors["red-500"], "#FB2C36FF");
  assert.equal(tailwindColors["amber-400"], "#FFB900FF");
  assert.equal(tailwindColors["emerald-600"], "#009966FF");
  assert.equal(tailwindColors["sky-400"], "#00BCFFFF");
  assert.equal(tailwindColors["violet-700"], "#7008E7FF");
  assert.equal(tailwindColors["slate-400"], "#90A1B9FF");
  assert.equal(tailwindColors["gray-200"], "#E5E7EBFF");
  assert.equal(tailwindColors["zinc-900"], "#18181BFF");
  assert.equal(tailwindColors["mauve-500"], "#79697BFF");
  assert.equal(tailwindColors["taupe-950"], "#0C0A09FF");
});

test("styling 04 accepts named colors and alpha for every color channel", () => {
  assert.deepEqual(compileClass("bg-zinc-900 text-slate-400/70 border-red-500/25"), {
    background: "#18181BFF", textColor: "#90A1B9B3", borderColor: "#FB2C3640",
  });
  assert.deepEqual(compileClass("bg-white text-black border-transparent"), {
    background: "#FFFFFFFF", textColor: "#000000FF", borderColor: "#00000000",
  });
  assert.deepEqual(compileClass("bg-transparent/50 text-[#123456]/20"), {
    background: "#00000000", textColor: "#12345633",
  });
  assert.throws(() => compileClass("bg-red-975"), /Unknown class utility/);
  assert.throws(() => compileClass("text-slate-400/101"), /Color alpha must be between 0 and 100/);
});

test("styling 05 accepts every text-pack utility family", () => {
  const cases = [
    ["text-left", { textAlign: "start" }],
    ["text-center", { textAlign: "center" }],
    ["text-right", { textAlign: "end" }],
    ["text-[13px]", { fontScale: 13 / 14 }],
    ["leading-tight", { lineHeight: 1.25 }],
    ["leading-6", { lineHeight: 24 / 14 }],
    ["leading-[19px]", { lineHeight: 19 / 14 }],
    ["leading-[1.7]", { lineHeight: 1.7 }],
    ["tracking-tighter", { letterSpacing: 14 * -0.05 }],
    ["tracking-wide", { letterSpacing: 14 * 0.025 }],
    ["tracking-[-1.5px]", { letterSpacing: -1.5 }],
    ["tracking-[0.08em]", { letterSpacing: 14 * 0.08 }],
    ["line-clamp-3", { lineClamp: 3 }],
    ["line-clamp-3 line-clamp-none", { lineClamp: 0 }],
    ["tabular-nums", { tabularNums: true }],
    ["tabular-nums normal-nums", { tabularNums: false }],
  ];
  for (const [utility, expected] of cases) assert.deepEqual(compileClass(utility), expected, utility);
  assert.deepEqual(compileClass("leading-6 text-[12px] tracking-wide"), {
    lineHeight: 2, fontScale: 12 / 14, letterSpacing: 12 * 0.025,
  });
  assert.deepEqual(compileClass("text-[12px] tracking-wide leading-6"), {
    fontScale: 12 / 14, letterSpacing: 12 * 0.025, lineHeight: 2,
  });

  const namedPairs = {
    xs: [12, 16], sm: [14, 20], base: [16, 24], lg: [18, 28],
    xl: [20, 28], "2xl": [24, 32], "3xl": [30, 36], "4xl": [36, 40],
  };
  for (const [name, [size, leading]] of Object.entries(namedPairs)) {
    assert.deepEqual(compileClass(`text-${name}`), { fontScale: size / 14, lineHeight: leading / size }, `text-${name}`);
  }
  assert.deepEqual(compileClass("leading-tight text-sm"), { lineHeight: 1.25, fontScale: 1 });
  assert.deepEqual(compileClass("text-sm leading-tight"), { fontScale: 1, lineHeight: 1.25 });
  assert.deepEqual(
    compileClass("text-sm text-[20px]"),
    { fontScale: 20 / 14, lineHeight: 1 },
    "arbitrary font-size retains text-sm's authored 20px line-height",
  );
});

test("styling 05 rejects malformed text-pack utilities", () => {
  for (const utility of [
    "text-[0px]", "text-[13pt]", "text-middle", "leading-[0]", "leading-[-2px]",
    "tracking-[wide]", "tracking-[1rem]", "line-clamp-0", "line-clamp-1.5", "tabular-num",
  ]) assert.throws(() => compileClass(utility), /Unknown class utility/, utility);
  assert.throws(() => compileClass(`tracking-[${"9".repeat(400)}px]`), /non-finite or absurd numeric value/);
  assert.throws(() => compileClass(`line-clamp-${"9".repeat(400)}`), /non-finite or absurd numeric value/);
});

test("styling 06 accepts every shadow utility family", () => {
  const cases = [
    ["shadow-sm", { shadow: "0 1 2 0 #0000000D", shadowInset: false }],
    ["shadow", { shadow: "0 1 3 0 #0000001A", shadowInset: false }],
    ["shadow-md", { shadow: "0 4 6 -1 #0000001A", shadowInset: false }],
    ["shadow-lg", { shadow: "0 10 15 -3 #0000001A", shadowInset: false }],
    ["shadow-xl", { shadow: "0 20 25 -5 #0000001A", shadowInset: false }],
    ["shadow-inner", { shadow: "0 2 4 0 #0000000F", shadowInset: true }],
    ["shadow-[2px_-3px_8px_-1px_#12345678]", { shadow: "2 -3 8 -1 #12345678", shadowInset: false }],
    ["shadow-none", { shadow: "", shadowInset: false }],
    ["text-shadow-sm", { textShadow: "0 1 1 #00000026" }],
    ["text-shadow", { textShadow: "0 1 2 #00000026" }],
    ["text-shadow-md", { textShadow: "0 2 4 #00000026" }],
    ["text-shadow-lg", { textShadow: "0 4 8 #00000026" }],
    ["text-shadow-none", { textShadow: "" }],
  ];
  for (const [utility, expected] of cases) assert.deepEqual(compileClass(utility), expected, utility);
  assert.deepEqual(compileClass("shadow-red-500/40 shadow-md"), {
    shadow: "0 4 6 -1 #FB2C3666", shadowInset: false,
  });
  assert.deepEqual(compileClass("shadow-md shadow-[#123]/50"), {
    shadow: "0 4 6 -1 #11223380", shadowInset: false,
  });
});

test("styling 06 rejects malformed shadow utilities", () => {
  for (const utility of [
    "shadow-2xl", "shadow-[0_2px_4px]", "shadow-[0_2px_-4px_0_#000]",
    "shadow-[0_2rem_4px_0_#000]", "shadow-[0_2px_4px_0_#12]", "text-shadow-xl",
  ]) assert.throws(() => compileClass(utility), /Unknown class utility/, utility);
  assert.throws(() => compileClass("shadow-red-500/101"), /Color alpha must be between 0 and 100/);
});

test("styling 07 accepts built-in and bundled font families", () => {
  assert.deepEqual(compileClass("font-sans"), { fontFamily: "sans" });
  assert.deepEqual(compileClass("font-mono"), { fontFamily: "mono" });
  assert.deepEqual(compileClass("font-[CozetteVector] font-semibold"), {
    fontFamily: "CozetteVector", fontWeight: "semibold",
  });
});

test("styling 07 rejects malformed font family utilities", () => {
  for (const utility of ["font-[]", "font-[has space]", "font-[-leading]", "font-[name.ttf]"]) {
    assert.throws(() => compileClass(utility), /Unknown class utility/, utility);
  }
});

test("styling 09 accepts bounded overflow", () => {
  assert.deepEqual(compileClass("overflow-hidden"), { overflowHidden: true });
  assert.deepEqual(compileClass("rounded-tl-xl overflow-hidden"), {
    radiusTopLeft: 12,
    overflowHidden: true,
  });
});

test("styling 09 rejects unsupported overflow policies", () => {
  for (const utility of ["overflow-visible", "overflow-auto", "overflow-clip", "overflow-hidden-x"]) {
    assert.throws(() => compileClass(utility), /Unknown class utility/, utility);
  }
});

test("styling 11 accepts every hover and pressed visual channel", () => {
  const cases = [
    ["hover:bg-zinc-800", { hoverBackground: "#27272AFF" }],
    ["hover:text-[#abc]/50", { hoverTextColor: "#AABBCC80" }],
    ["hover:opacity-75", { hoverOpacity: 0.75 }],
    ["hover:border-red-500/40", { hoverBorderColor: "#FB2C3666" }],
    ["hover:shadow-md", { hoverShadow: "0 4 6 -1 #0000001A", hoverShadowInset: false }],
    ["pressed:bg-black", { pressedBackground: "#000000FF" }],
    ["pressed:text-white", { pressedTextColor: "#FFFFFFFF" }],
    ["pressed:opacity-60", { pressedOpacity: 0.6 }],
    ["pressed:border-[#12345678]", { pressedBorderColor: "#12345678" }],
    ["pressed:shadow-inner", { pressedShadow: "0 2 4 0 #0000000F", pressedShadowInset: true }],
    ["pressed:shadow-[0_2px_4px_0_#0000004d]", { pressedShadow: "0 2 4 0 #0000004D", pressedShadowInset: false }],
    ["pressed:shadow-none", { pressedShadow: "none", pressedShadowInset: false }],
  ];
  for (const [utility, expected] of cases) assert.deepEqual(compileClass(utility), expected, utility);
  assert.deepEqual(
    compileClass("bg-zinc-900 hover:bg-zinc-800 pressed:bg-black hover:opacity-90 pressed:opacity-70"),
    { background: "#18181BFF", hoverBackground: "#27272AFF", pressedBackground: "#000000FF", hoverOpacity: 0.9, pressedOpacity: 0.7 },
  );
  assert.deepEqual(
    compileClass("pressed:shadow-lg pressed:shadow-[#123]/50 pressed:shadow-inner"),
    { pressedShadow: "0 2 4 0 #11223380", pressedShadowInset: true },
  );
});

test("styling 11 rejects unsupported state channels with the supported-form fix-it", () => {
  for (const utility of [
    "hover:p-2", "hover:border-2", "hover:text-sm", "hover:shadow-[0_2px_4px]",
    "pressed:rounded-lg", "pressed:font-bold", "pressed:bg-red-975", "pressed:opacity-101",
  ]) {
    assert.throws(
      () => compileClass(utility),
      /supports only (?:hover|pressed):bg-<color>, (?:hover|pressed):text-<color>, (?:hover|pressed):opacity-N, (?:hover|pressed):border-<color>, or (?:hover|pressed):shadow-\*/,
      utility,
    );
  }
});
