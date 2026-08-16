import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { compileClass, UtilityError } from "../src/class-compiler.ts";

const contract = readFileSync(new URL("../CONTRACT.md", import.meta.url), "utf8").replaceAll("\r\n", "\n");
const declarations = readFileSync(new URL("../index.d.ts", import.meta.url), "utf8").replaceAll("\r\n", "\n");
const reconciler = readFileSync(new URL("../src/reconciler.ts", import.meta.url), "utf8").replaceAll("\r\n", "\n");
const consolidated = contract.slice(contract.indexOf("## Consolidated v0.4 authoring tables"));

function firstColumnAfter(header) {
  const start = consolidated.indexOf(header);
  const table = consolidated.slice(start, consolidated.indexOf("\n\n", start));
  return table
    .split("\n")
    .slice(2)
    .map((line) => line.split("|")[1].trim().replaceAll("`", ""));
}

test("consolidated v0.4 element and class tables are complete and ordered", () => {
  assert.deepEqual(firstColumnAfter("| Element |"), [
    "<column>", "<row>", "<stack>", "<panel>", "<text>",
    "<icon>", "<image>", "<button>", "<slider>", "<canvas>",
  ]);
  assert.deepEqual(firstColumnAfter("| Class family |"), [
    "spacing", "sizing", "flex", "radii", "borders",
    "colors", "typography", "effects", "overflow", "native state",
  ]);
});

test("consolidated class table representatives compile and omitted families stay loud", () => {
  const representatives = [
    "p-2 px-[3px] -mt-1 gap-[5px]",
    "w-1/2 h-auto size-[20px] min-w-2 max-h-[80px] aspect-[4/3]",
    "items-baseline justify-evenly grow-[2.5] shrink-0 self-stretch flex-wrap",
    "rounded-tl-3xl rounded-r-[7px]",
    "border-2 border-mauve-500/40",
    "bg-taupe-950 text-[#abcdef]/75",
    "text-3xl font-bold font-[Display] text-right leading-[18px] tracking-[0.1em] line-clamp-2 tabular-nums truncate",
    "shadow-inner shadow-amber-400/30 text-shadow-lg opacity-70",
    "overflow-hidden",
    "hover:bg-zinc-800 hover:text-white pressed:opacity-70 pressed:border-[#abc]",
  ];
  for (const authored of representatives) assert.doesNotThrow(() => compileClass(authored), authored);
  for (const authored of ["bg-gradient-to-r", "transition-colors", "absolute", "hover:p-2"]) {
    assert.throws(() => compileClass(authored), UtilityError, authored);
  }
});

function declarationBlock(source, pattern, label) {
  const match = source.match(pattern);
  assert.ok(match, `missing ${label}`);
  return match[0];
}

function providerOverloads(source, hook) {
  return source.match(new RegExp(`^export function ${hook}\\(name: "[^"]+"\\): [^;]+;`, "gm")) ?? [];
}

test("public Signal and provider declarations match their runtime source", () => {
  const signalPattern = /^export interface Signal<out T> \{[\s\S]*?^\}/m;
  assert.equal(
    declarationBlock(declarations, signalPattern, "public Signal declaration"),
    declarationBlock(reconciler, signalPattern, "runtime Signal declaration"),
  );
  for (const hook of ["useProvider", "useProviderSignal"]) {
    assert.deepEqual(providerOverloads(declarations, hook), providerOverloads(reconciler, hook));
  }
});
