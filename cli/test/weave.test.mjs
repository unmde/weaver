import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { deflateRawSync } from "node:zlib";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const weaveBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/weave.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const weave = await import(`data:text/javascript;base64,${Buffer.from(weaveBundle.outputFiles[0].contents).toString("base64")}`);

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "weaver-archive-"));
  writeFileSync(join(root, "widget.tsx"), "export default widget({ name: \"Archive Test\", size: [100, 100] }, () => <text>hello</text>);\n");
  writeFileSync(join(root, "tsconfig.json"), "{\"compilerOptions\":{\"paths\":{\"@weaver/sdk\":[\"C:/private/sdk\"]}}}\n");
  writeFileSync(join(root, "safe.txt"), "safe asset\n");
  writeFileSync(join(root, "bundle.js"), "compiled output");
  writeFileSync(join(root, "widget.json"), "{\"legacy\":true}\n");
  mkdirSync(join(root, "dist"));
  writeFileSync(join(root, "dist", "bundle.js"), "generated");
  mkdirSync(join(root, "art"));
  writeFileSync(join(root, "art", "pixel.bin"), Buffer.from([0, 1, 2, 3]));
  return root;
}

const ZIP_LOCAL_HEADER = 0x04034b50;
const ZIP_CENTRAL_HEADER = 0x02014b50;
const ZIP_END = 0x06054b50;

function zipLayout(bytes) {
  const endOffset = bytes.length - 22;
  assert.equal(bytes.readUInt32LE(endOffset), ZIP_END);
  const centralOffset = bytes.readUInt32LE(endOffset + 16);
  const centralSize = bytes.readUInt32LE(endOffset + 12);
  const entryCount = bytes.readUInt16LE(endOffset + 10);
  const entries = [];
  let cursor = centralOffset;
  for (let index = 0; index < entryCount; index += 1) {
    assert.equal(bytes.readUInt32LE(cursor), ZIP_CENTRAL_HEADER);
    const nameLength = bytes.readUInt16LE(cursor + 28);
    const extraLength = bytes.readUInt16LE(cursor + 30);
    const commentLength = bytes.readUInt16LE(cursor + 32);
    const localOffset = bytes.readUInt32LE(cursor + 42);
    assert.equal(bytes.readUInt32LE(localOffset), ZIP_LOCAL_HEADER);
    const localNameLength = bytes.readUInt16LE(localOffset + 26);
    const localExtraLength = bytes.readUInt16LE(localOffset + 28);
    entries.push({
      path: bytes.subarray(cursor + 46, cursor + 46 + nameLength).toString("utf8"),
      method: bytes.readUInt16LE(cursor + 10),
      centralOffset: cursor,
      centralLength: 46 + nameLength + extraLength + commentLength,
      nameLength,
      localOffset,
      dataOffset: localOffset + 30 + localNameLength + localExtraLength,
      compressedSize: bytes.readUInt32LE(cursor + 20),
    });
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  assert.equal(cursor, endOffset);
  return { endOffset, centralOffset, centralSize, entries };
}

function insertAt(bytes, offset, inserted) {
  return Buffer.concat([bytes.subarray(0, offset), Buffer.from(inserted), bytes.subarray(offset)]);
}

function withPrefix(bytes) {
  const layout = zipLayout(bytes);
  const prefix = Buffer.from("hidden");
  const output = Buffer.concat([prefix, bytes]);
  for (const entry of layout.entries) output.writeUInt32LE(entry.localOffset + prefix.length, entry.centralOffset + prefix.length + 42);
  output.writeUInt32LE(layout.centralOffset + prefix.length, layout.endOffset + prefix.length + 16);
  return output;
}

function withGapBetweenLocals(bytes) {
  const layout = zipLayout(bytes);
  const locals = [...layout.entries].sort((left, right) => left.localOffset - right.localOffset);
  assert.ok(locals.length > 1);
  const gapOffset = locals[1].localOffset;
  const output = insertAt(bytes, gapOffset, [0]);
  const shiftedCentral = layout.centralOffset + 1;
  for (const entry of layout.entries) {
    const nextOffset = entry.localOffset >= gapOffset ? entry.localOffset + 1 : entry.localOffset;
    output.writeUInt32LE(nextOffset, shiftedCentral + (entry.centralOffset - layout.centralOffset) + 42);
  }
  output.writeUInt32LE(shiftedCentral, layout.endOffset + 1 + 16);
  return output;
}

function withCentralPayload(bytes, lengthFieldOffset) {
  const layout = zipLayout(bytes);
  const entry = layout.entries[0];
  const insertOffset = entry.centralOffset + 46 + entry.nameLength;
  const output = insertAt(bytes, insertOffset, [0]);
  output.writeUInt16LE(1, entry.centralOffset + lengthFieldOffset);
  output.writeUInt32LE(layout.centralSize + 1, layout.endOffset + 1 + 12);
  return output;
}

function withLocalExtra(bytes) {
  const layout = zipLayout(bytes);
  const first = [...layout.entries].sort((left, right) => left.localOffset - right.localOffset)[0];
  const output = insertAt(bytes, first.dataOffset, [0]);
  output.writeUInt16LE(1, first.localOffset + 28);
  const shiftedCentral = layout.centralOffset + 1;
  for (const entry of layout.entries) {
    const nextOffset = entry.localOffset === first.localOffset ? entry.localOffset : entry.localOffset + 1;
    output.writeUInt32LE(nextOffset, shiftedCentral + (entry.centralOffset - layout.centralOffset) + 42);
  }
  output.writeUInt32LE(shiftedCentral, layout.endOffset + 1 + 16);
  return output;
}

function withEndComment(bytes) {
  const layout = zipLayout(bytes);
  const comment = Buffer.from("comment");
  const output = Buffer.concat([bytes, comment]);
  output.writeUInt16LE(comment.length, layout.endOffset + 20);
  return output;
}

function replaceAllSameLength(bytes, fromText, toText) {
  const from = Buffer.from(fromText);
  const to = Buffer.from(toText);
  assert.equal(from.length, to.length);
  const output = Buffer.from(bytes);
  let replacements = 0;
  for (let offset = output.indexOf(from); offset !== -1; offset = output.indexOf(from, offset + to.length)) {
    to.copy(output, offset);
    replacements += 1;
  }
  assert.equal(replacements, 2);
  return output;
}

function reverseCentralEntries(bytes) {
  const layout = zipLayout(bytes);
  const records = layout.entries.map((entry) => bytes.subarray(entry.centralOffset, entry.centralOffset + entry.centralLength));
  return Buffer.concat([bytes.subarray(0, layout.centralOffset), ...records.reverse(), bytes.subarray(layout.endOffset)]);
}

function setUncompressedSize(bytes, paths, size) {
  const output = Buffer.from(bytes);
  for (const entry of zipLayout(output).entries.filter((candidate) => paths.includes(candidate.path))) {
    output.writeUInt32LE(size, entry.centralOffset + 24);
    output.writeUInt32LE(size, entry.localOffset + 22);
  }
  return output;
}

const CRC_TABLE = new Uint32Array(256).map((_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) value = (value & 1) !== 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});

function crc32(data) {
  let value = 0xffffffff;
  for (const byte of data) value = CRC_TABLE[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function compressedZip(entries) {
  const records = entries.map(({ path, data, trailing = Buffer.alloc(0) }) => ({
    path,
    data,
    name: Buffer.from(path),
    compressed: Buffer.concat([deflateRawSync(data, { level: 9 }), trailing]),
    checksum: crc32(data),
    localOffset: 0,
  }));
  const locals = [];
  let offset = 0;
  for (const entry of records) {
    entry.localOffset = offset;
    const header = Buffer.alloc(30);
    header.writeUInt32LE(ZIP_LOCAL_HEADER, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x0800, 6);
    header.writeUInt16LE(8, 8);
    header.writeUInt32LE(entry.checksum, 14);
    header.writeUInt32LE(entry.compressed.length, 18);
    header.writeUInt32LE(entry.data.length, 22);
    header.writeUInt16LE(entry.name.length, 26);
    locals.push(header, entry.name, entry.compressed);
    offset += header.length + entry.name.length + entry.compressed.length;
  }
  const centralOffset = offset;
  const central = [];
  for (const entry of records) {
    const header = Buffer.alloc(46);
    header.writeUInt32LE(ZIP_CENTRAL_HEADER, 0);
    header.writeUInt16LE(0x0314, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(0x0800, 8);
    header.writeUInt16LE(8, 10);
    header.writeUInt32LE(entry.checksum, 16);
    header.writeUInt32LE(entry.compressed.length, 20);
    header.writeUInt32LE(entry.data.length, 24);
    header.writeUInt16LE(entry.name.length, 28);
    header.writeUInt32LE((0o100644 << 16) >>> 0, 38);
    header.writeUInt32LE(entry.localOffset, 42);
    central.push(header, entry.name);
    offset += header.length + entry.name.length;
  }
  const end = Buffer.alloc(22);
  end.writeUInt32LE(ZIP_END, 0);
  end.writeUInt16LE(records.length, 8);
  end.writeUInt16LE(records.length, 10);
  end.writeUInt32LE(offset - centralOffset, 12);
  end.writeUInt32LE(centralOffset, 16);
  return Buffer.concat([...locals, ...central, end]);
}

function withControlCharacterAuthor(bytes) {
  return rewriteStoredEntrySameLength(bytes, "weave.json", (data) => {
    const output = Buffer.from(data);
    const author = Buffer.from('"author": null');
    const replacement = Buffer.from('"author": "\\n"');
    assert.equal(author.length, replacement.length);
    const authorOffset = output.indexOf(author);
    assert.notEqual(authorOffset, -1);
    replacement.copy(output, authorOffset);
    return output;
  });
}

function rewriteStoredEntrySameLength(bytes, path, transform) {
  const output = Buffer.from(bytes);
  const entry = zipLayout(output).entries.find((candidate) => candidate.path === path);
  assert.ok(entry);
  assert.equal(entry.method, 0);
  const data = output.subarray(entry.dataOffset, entry.dataOffset + entry.compressedSize);
  const replacement = Buffer.from(transform(data));
  assert.equal(replacement.length, data.length);
  replacement.copy(data);
  const checksum = crc32(data);
  output.writeUInt32LE(checksum, entry.centralOffset + 16);
  output.writeUInt32LE(checksum, entry.localOffset + 14);
  return output;
}

function withReorderedManifestObjects(bytes) {
  return rewriteStoredEntrySameLength(bytes, "weave.json", (data) => {
    const manifest = JSON.parse(data.toString("utf8"));
    return `${JSON.stringify({
      formatVersion: manifest.formatVersion,
      sourceId: manifest.sourceId,
      name: manifest.name,
      provenance: { author: manifest.provenance.author },
      lineage: { parent: manifest.lineage.parent, root: manifest.lineage.root },
      declared: {
        capabilities: manifest.declared.capabilities,
        origins: manifest.declared.origins,
        providers: manifest.declared.providers,
      },
      artifactId: manifest.artifactId,
    }, null, 2)}\n`;
  });
}

test(".weave packing is deterministic and contains source rather than build output", () => {
  const root = fixture();
  try {
    const declared = { providers: ["time"], origins: ["api.example.com"], capabilities: [] };
    const first = weave.packWeave(root, "Archive Test", declared);
    const second = weave.packWeave(root, "Archive Test", declared);
    const metadataVariant = weave.packWeave(root, "Archive Test", { ...declared, origins: ["other.example.com"] });
    assert.deepEqual(first.bytes, second.bytes);
    assert.match(first.manifest.artifactId, /^sha256:[0-9a-f]{64}$/);
    assert.match(first.manifest.sourceId, /^sha256:[0-9a-f]{64}$/);
    assert.notEqual(first.manifest.artifactId, first.manifest.sourceId);
    assert.equal(metadataVariant.manifest.sourceId, first.manifest.sourceId);
    assert.notEqual(metadataVariant.manifest.artifactId, first.manifest.artifactId);
    assert.equal(first.manifest.lineage.root, first.manifest.sourceId);
    assert.equal(first.manifest.lineage.parent, null);
    assert.ok(zipLayout(first.bytes).entries.every((entry) => entry.method === 0));
    const opened = weave.openWeave(first.bytes);
    const reordered = weave.openWeave(withReorderedManifestObjects(first.bytes));
    assert.equal(reordered.manifest.artifactId, first.manifest.artifactId);
    assert.deepEqual(opened.manifest.declared, declared);
    assert.deepEqual([...opened.files.keys()], ["art/pixel.bin", "safe.txt", "widget.tsx"]);
    assert.equal(opened.files.has("tsconfig.json"), false);
    assert.equal(opened.files.has("bundle.js"), false);
    assert.equal(opened.files.has("widget.json"), false);
    assert.equal(opened.files.has("dist/bundle.js"), false);

    const extracted = join(root, "extracted");
    weave.extractWeave(opened, extracted);
    assert.equal(readFileSync(join(extracted, "safe.txt"), "utf8"), "safe asset\n");
    assert.equal(JSON.parse(readFileSync(join(extracted, "weave.json"), "utf8")).artifactId, first.manifest.artifactId);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader rejects noncanonical ZIP framing and hidden bytes", () => {
  const root = fixture();
  try {
    const bytes = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] }).bytes;
    assert.throws(() => weave.openWeave(withPrefix(bytes)), /contiguous and start at byte zero/);
    assert.throws(() => weave.openWeave(withGapBetweenLocals(bytes)), /contiguous and start at byte zero/);
    assert.throws(() => weave.openWeave(withCentralPayload(bytes, 30)), /extra data or a comment/);
    assert.throws(() => weave.openWeave(withCentralPayload(bytes, 32)), /extra data or a comment/);
    assert.throws(() => weave.openWeave(withLocalExtra(bytes)), /local entry contains unsupported ZIP extra data/);
    assert.throws(() => weave.openWeave(withEndComment(bytes)), /ZIP comments are not valid/);
    const trailingCompressedData = compressedZip([
      { path: "source/widget.tsx", data: Buffer.from("widget"), trailing: Buffer.from("hidden") },
      { path: "weave.json", data: Buffer.from("{}") },
    ]);
    assert.throws(() => weave.openWeave(trailingCompressedData), /could not be decompressed/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader rejects file and descendant path collisions in either order", () => {
  const root = fixture();
  try {
    const bytes = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] }).bytes;
    const descendantFirst = replaceAllSameLength(
      replaceAllSameLength(bytes, "source/safe.txt", "source/abcdefgh"),
      "source/art/pixel.bin",
      "source/abcdefgh/xxxx",
    );
    assert.throws(() => weave.openWeave(descendantFirst), /also used as a directory/);
    assert.throws(() => weave.openWeave(reverseCentralEntries(descendantFirst)), /also used as a directory/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader enforces manifest and aggregate unpacked limits", () => {
  const root = fixture();
  try {
    const bytes = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] }).bytes;
    const oversizedManifest = setUncompressedSize(bytes, ["weave.json"], weave.MAX_WEAVE_MANIFEST_BYTES + 1);
    assert.throws(() => weave.openWeave(oversizedManifest), /manifest limit/);

    const aggregateOverflow = compressedZip([
      ...["a", "b", "c", "widget.tsx"].map((name) => ({ path: `source/${name}`, data: Buffer.alloc(16 * 1024 * 1024) })),
      { path: "weave.json", data: Buffer.from("{}") },
    ]);
    assert.throws(() => weave.openWeave(aggregateOverflow), /64 MiB unpacked limit/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave metadata rejects control-character display values", () => {
  const root = fixture();
  try {
    const declared = { providers: [], origins: [], capabilities: [] };
    const invalidDisplayValue = /without control, line-separator, or paragraph-separator characters/;
    assert.throws(() => weave.packWeave(root, "line one\nline two", declared), invalidDisplayValue);
    assert.throws(() => weave.packWeave(root, "safe\u202eevil", declared), invalidDisplayValue);
    assert.throws(() => weave.packWeave(root, "line\u2028separator", declared), invalidDisplayValue);
    assert.throws(() => weave.packWeave(root, "paragraph\u2029separator", declared), invalidDisplayValue);
    const bytes = weave.packWeave(root, "Archive Test", declared).bytes;
    assert.throws(() => weave.openWeave(withControlCharacterAuthor(bytes)), /provenance\.author.*without control, line-separator, or paragraph-separator characters/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader rejects traversal paths before extraction", () => {
  const root = fixture();
  try {
    const packed = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] });
    const malicious = Buffer.from(packed.bytes);
    const from = Buffer.from("source/safe.txt");
    const to = Buffer.from("source/../x.txt");
    assert.equal(from.length, to.length);
    let replacements = 0;
    for (let offset = malicious.indexOf(from); offset !== -1; offset = malicious.indexOf(from, offset + to.length)) {
      to.copy(malicious, offset);
      replacements += 1;
    }
    assert.equal(replacements, 2);
    assert.throws(() => weave.openWeave(malicious), /Unsafe archive path/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader rejects Unix symlink entries", () => {
  const root = fixture();
  try {
    const packed = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] });
    const malicious = Buffer.from(packed.bytes);
    const name = Buffer.from("source/safe.txt");
    const centralName = malicious.lastIndexOf(name);
    assert.notEqual(centralName, -1);
    const centralHeader = centralName - 46;
    assert.equal(malicious.readUInt32LE(centralHeader), 0x02014b50);
    malicious.writeUInt32LE((0o120777 << 16) >>> 0, centralHeader + 38);
    assert.throws(() => weave.openWeave(malicious), /link or special file/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test(".weave reader rejects corrupted payloads", () => {
  const root = fixture();
  try {
    const packed = weave.packWeave(root, "Archive Test", { providers: [], origins: [], capabilities: [] });
    const corrupted = Buffer.from(packed.bytes);
    const name = Buffer.from("source/safe.txt");
    const localName = corrupted.indexOf(name);
    assert.notEqual(localName, -1);
    const dataOffset = localName + name.length;
    corrupted[dataOffset] ^= 0xff;
    assert.throws(() => weave.openWeave(corrupted), /could not be decompressed|checksum is invalid/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
