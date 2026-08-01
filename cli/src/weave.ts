import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { inflateRawSync } from "node:zlib";

const FORMAT_VERSION = 1;
// Bundle receipt (2026-07-29): the largest shipped source tree is
// retro-player-shell at 170,214 bytes across six files; its packed archive is
// 171,011 bytes and its largest file is 94,800 bytes. The 64 MiB source,
// archive, and unpacked tripwires leave >390x byte headroom; 16 MiB/file
// leaves >175x, and 1024 entries leaves >170x. Buffers/maps grow with actual
// input, so the unused allowance reserves no resident memory.
export const MAX_WEAVE_ARCHIVE_BYTES = 64 * 1024 * 1024;
const MAX_SOURCE_BYTES = 64 * 1024 * 1024;
const MAX_UNPACKED_BYTES = 64 * 1024 * 1024;
const MAX_FILE_BYTES = 16 * 1024 * 1024;
// The measured retro-player-shell weave.json is 414 bytes. 64 KiB leaves
// >150x format headroom and makes separate name/author byte caps redundant;
// the archive stores only the actual manifest bytes.
export const MAX_WEAVE_MANIFEST_BYTES = 64 * 1024;
const MAX_ENTRIES = 1024;
const UTF8_FLAG = 0x0800;
const ZIP_LOCAL_HEADER = 0x04034b50;
const ZIP_CENTRAL_HEADER = 0x02014b50;
const ZIP_END = 0x06054b50;
const DOS_DATE_1980_01_01 = 33;
const REGULAR_FILE_MODE = 0o100644;

export interface DeclaredSurface {
  providers: string[];
  origins: string[];
  capabilities: string[];
}

export interface WeaveManifest {
  formatVersion: 1;
  artifactId: string;
  sourceId: string;
  name: string;
  provenance: { author: string | null };
  lineage: { root: string; parent: string | null };
  declared: DeclaredSurface;
}

export interface PackedWeave {
  bytes: Buffer;
  manifest: WeaveManifest;
}

export interface OpenedWeave {
  manifest: WeaveManifest;
  files: ReadonlyMap<string, Buffer>;
}

interface SourceEntry { path: string; data: Buffer }
interface ZipEntry extends SourceEntry { crc: number; compressed: Buffer; method: 0 | 8; offset: number }

export function packWeave(sourceDirectory: string, name: string, declared: DeclaredSurface): PackedWeave {
  validateDisplayString(name, "widget name");
  const sourceEntries = collectSourceEntries(sourceDirectory);
  if (!sourceEntries.some((entry) => entry.path === "widget.tsx")) throw new Error("A .weave source must contain widget.tsx");
  const sourceId = `sha256:${sourceFingerprint(sourceEntries)}`;
  const identity: Omit<WeaveManifest, "artifactId"> = {
    formatVersion: FORMAT_VERSION,
    sourceId,
    name,
    provenance: { author: null },
    lineage: { root: sourceId, parent: null },
    declared: {
      providers: [...declared.providers],
      origins: [...declared.origins],
      capabilities: [...declared.capabilities],
    },
  };
  const manifest: WeaveManifest = { ...identity, artifactId: artifactIdentity(identity) };
  const archiveEntries: SourceEntry[] = [
    { path: "weave.json", data: manifestBytes(manifest) },
    ...sourceEntries.map((entry) => ({ path: `source/${entry.path}`, data: entry.data })),
  ];
  return { bytes: writeZip(archiveEntries), manifest };
}

export function openWeave(input: Uint8Array): OpenedWeave {
  const bytes = Buffer.from(input);
  if (bytes.length > MAX_WEAVE_ARCHIVE_BYTES) throw new Error(`Archive exceeds the ${formatMiB(MAX_WEAVE_ARCHIVE_BYTES)} .weave limit`);
  const entries = readZip(bytes);
  const manifestData = entries.get("weave.json");
  if (!manifestData) throw new Error("Archive is missing weave.json");
  const manifest = parseManifest(manifestData);
  const files = new Map<string, Buffer>();
  for (const [path, data] of entries) {
    if (!path.startsWith("source/")) continue;
    files.set(path.slice("source/".length), data);
  }
  if (!files.has("widget.tsx")) throw new Error("Archive is missing source/widget.tsx");
  const actualSourceId = `sha256:${sourceFingerprint([...files].map(([path, data]) => ({ path, data })))}`;
  if (manifest.sourceId !== actualSourceId) throw new Error(`Artifact source hash mismatch: expected ${manifest.sourceId}, got ${actualSourceId}`);
  if (manifest.lineage.parent === null && manifest.lineage.root !== manifest.sourceId) throw new Error("An original artifact's lineage root must equal its source identity");
  const actualArtifactId = artifactIdentity({
    formatVersion: manifest.formatVersion,
    sourceId: manifest.sourceId,
    name: manifest.name,
    provenance: manifest.provenance,
    lineage: manifest.lineage,
    declared: manifest.declared,
  });
  if (manifest.artifactId !== actualArtifactId) throw new Error(`Artifact metadata hash mismatch: expected ${manifest.artifactId}, got ${actualArtifactId}`);
  return { manifest, files };
}

export function extractWeave(opened: OpenedWeave, destination: string): void {
  const root = resolve(destination);
  mkdirSync(root, { recursive: true });
  for (const [relativePath, data] of opened.files) {
    const target = resolve(root, ...relativePath.split("/"));
    if (!target.startsWith(`${root}${sep}`)) throw new Error(`Archive path escapes its install root: ${relativePath}`);
    mkdirSync(resolve(target, ".."), { recursive: true });
    writeFileSync(target, data, { flag: "wx" });
  }
  writeFileSync(join(root, "weave.json"), manifestBytes(opened.manifest), { flag: "wx" });
}

function collectSourceEntries(sourceDirectory: string): SourceEntry[] {
  const root = resolve(sourceDirectory);
  const output: SourceEntry[] = [];
  let totalBytes = 0;
  const visit = (directory: string, prefix: string): void => {
    const entries = readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name, "en"));
    for (const entry of entries) {
      const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (!isWeaveSourceEntryIncluded(entry.name, prefix === "")) continue;
      validateSourcePath(relativePath);
      const source = join(directory, entry.name);
      const stat = lstatSync(source);
      if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) {
        throw new Error(`Widget source contains a link or special file: ${relativePath}`);
      }
      if (stat.isDirectory()) {
        visit(source, relativePath);
        continue;
      }
      if (stat.size > MAX_FILE_BYTES) throw new Error(`${relativePath} exceeds the ${formatMiB(MAX_FILE_BYTES)} per-file limit`);
      const data = readFileSync(source);
      if (data.length > MAX_FILE_BYTES) throw new Error(`${relativePath} exceeds the ${formatMiB(MAX_FILE_BYTES)} per-file limit`);
      totalBytes += data.length;
      if (totalBytes > MAX_SOURCE_BYTES) throw new Error(`Widget source exceeds the ${formatMiB(MAX_SOURCE_BYTES)} unpacked limit`);
      output.push({ path: relativePath, data });
      if (output.length > MAX_ENTRIES - 1) throw new Error(`Widget source exceeds the ${MAX_ENTRIES - 1}-file limit`);
    }
  };
  visit(root, "");
  output.sort((a, b) => Buffer.from(a.path).compare(Buffer.from(b.path)));
  rejectCaseCollisions(output.map((entry) => entry.path));
  return output;
}

export function isWeaveSourceEntryIncluded(name: string, root: boolean): boolean {
  if ([".git", "node_modules"].includes(name) || name.toLowerCase().endsWith(".weave")) return false;
  return !root || !["bundle.js", "dist", "tsconfig.json", "weave.json", "widget.json"].includes(name);
}

function sourceFingerprint(entries: SourceEntry[]): string {
  const hash = createHash("sha256");
  const sorted = [...entries].sort((a, b) => Buffer.from(a.path).compare(Buffer.from(b.path)));
  for (const entry of sorted) {
    const path = Buffer.from(entry.path, "utf8");
    const header = Buffer.alloc(12);
    header.writeUInt32LE(path.length, 0);
    header.writeBigUInt64LE(BigInt(entry.data.length), 4);
    hash.update(header);
    hash.update(path);
    hash.update(entry.data);
  }
  return hash.digest("hex");
}

function artifactIdentity(identity: Omit<WeaveManifest, "artifactId">): string {
  const canonical: Omit<WeaveManifest, "artifactId"> = {
    formatVersion: identity.formatVersion,
    sourceId: identity.sourceId,
    name: identity.name,
    provenance: { author: identity.provenance.author },
    lineage: { root: identity.lineage.root, parent: identity.lineage.parent },
    declared: {
      providers: [...identity.declared.providers],
      origins: [...identity.declared.origins],
      capabilities: [...identity.declared.capabilities],
    },
  };
  return `sha256:${createHash("sha256").update(JSON.stringify(canonical), "utf8").digest("hex")}`;
}

function manifestBytes(manifest: WeaveManifest): Buffer {
  return Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, "utf8");
}

function writeZip(sourceEntries: SourceEntry[]): Buffer {
  const entries: ZipEntry[] = [];
  const locals: Buffer[] = [];
  let offset = 0;
  for (const source of [...sourceEntries].sort((a, b) => Buffer.from(a.path).compare(Buffer.from(b.path)))) {
    validateArchivePath(source.path);
    const name = Buffer.from(source.path, "utf8");
    if (source.path === "weave.json" && source.data.length > MAX_WEAVE_MANIFEST_BYTES) throw new Error(`weave.json exceeds the ${formatKiB(MAX_WEAVE_MANIFEST_BYTES)} manifest limit`);
    const method: 0 | 8 = 0;
    const compressed = source.data;
    const crc = crc32(source.data);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(ZIP_LOCAL_HEADER, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(UTF8_FLAG, 6);
    header.writeUInt16LE(method, 8);
    header.writeUInt16LE(0, 10);
    header.writeUInt16LE(DOS_DATE_1980_01_01, 12);
    header.writeUInt32LE(crc, 14);
    header.writeUInt32LE(compressed.length, 18);
    header.writeUInt32LE(source.data.length, 22);
    header.writeUInt16LE(name.length, 26);
    header.writeUInt16LE(0, 28);
    locals.push(header, name, compressed);
    entries.push({ ...source, crc, compressed, method, offset });
    offset += header.length + name.length + compressed.length;
  }

  const centralOffset = offset;
  const central: Buffer[] = [];
  for (const entry of entries) {
    const name = Buffer.from(entry.path, "utf8");
    const header = Buffer.alloc(46);
    header.writeUInt32LE(ZIP_CENTRAL_HEADER, 0);
    header.writeUInt16LE(0x0314, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(UTF8_FLAG, 8);
    header.writeUInt16LE(entry.method, 10);
    header.writeUInt16LE(0, 12);
    header.writeUInt16LE(DOS_DATE_1980_01_01, 14);
    header.writeUInt32LE(entry.crc, 16);
    header.writeUInt32LE(entry.compressed.length, 20);
    header.writeUInt32LE(entry.data.length, 24);
    header.writeUInt16LE(name.length, 28);
    header.writeUInt16LE(0, 30);
    header.writeUInt16LE(0, 32);
    header.writeUInt16LE(0, 34);
    header.writeUInt16LE(0, 36);
    header.writeUInt32LE((REGULAR_FILE_MODE << 16) >>> 0, 38);
    header.writeUInt32LE(entry.offset, 42);
    central.push(header, name);
    offset += header.length + name.length;
  }

  const centralSize = offset - centralOffset;
  const end = Buffer.alloc(22);
  end.writeUInt32LE(ZIP_END, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(centralOffset, 16);
  end.writeUInt16LE(0, 20);
  const archive = Buffer.concat([...locals, ...central, end]);
  if (archive.length > MAX_WEAVE_ARCHIVE_BYTES) throw new Error(`Packed archive exceeds the ${formatMiB(MAX_WEAVE_ARCHIVE_BYTES)} .weave limit`);
  return archive;
}

function readZip(bytes: Buffer): Map<string, Buffer> {
  const endOffset = findEndRecord(bytes);
  const disk = bytes.readUInt16LE(endOffset + 4);
  const centralDisk = bytes.readUInt16LE(endOffset + 6);
  const diskEntries = bytes.readUInt16LE(endOffset + 8);
  const totalEntries = bytes.readUInt16LE(endOffset + 10);
  const centralSize = bytes.readUInt32LE(endOffset + 12);
  const centralOffset = bytes.readUInt32LE(endOffset + 16);
  if (disk !== 0 || centralDisk !== 0 || diskEntries !== totalEntries) throw new Error("Multi-disk ZIP archives are not valid .weave files");
  if (totalEntries === 0 || totalEntries > MAX_ENTRIES) throw new Error(`Archive must contain between 1 and ${MAX_ENTRIES} files`);
  if (centralOffset + centralSize !== endOffset) throw new Error("Archive central directory is malformed");

  const output = new Map<string, Buffer>();
  const seen = new Set<string>();
  const ranges: Array<[number, number]> = [];
  let cursor = centralOffset;
  let totalBytes = 0;
  for (let index = 0; index < totalEntries; index += 1) {
    requireRange(bytes, cursor, 46, "central directory entry");
    if (bytes.readUInt32LE(cursor) !== ZIP_CENTRAL_HEADER) throw new Error("Archive central directory signature is invalid");
    const madeBy = bytes.readUInt16LE(cursor + 4);
    const flags = bytes.readUInt16LE(cursor + 8);
    const method = bytes.readUInt16LE(cursor + 10);
    const crc = bytes.readUInt32LE(cursor + 16);
    const compressedSize = bytes.readUInt32LE(cursor + 20);
    const uncompressedSize = bytes.readUInt32LE(cursor + 24);
    const nameLength = bytes.readUInt16LE(cursor + 28);
    const extraLength = bytes.readUInt16LE(cursor + 30);
    const commentLength = bytes.readUInt16LE(cursor + 32);
    const diskStart = bytes.readUInt16LE(cursor + 34);
    const externalAttributes = bytes.readUInt32LE(cursor + 38);
    const localOffset = bytes.readUInt32LE(cursor + 42);
    requireRange(bytes, cursor + 46, nameLength + extraLength + commentLength, "central directory payload");
    const path = decodeUtf8(bytes.subarray(cursor + 46, cursor + 46 + nameLength), "archive path");
    validateArchivePath(path);
    if (extraLength !== 0 || commentLength !== 0) throw new Error(`Archive entry contains unsupported ZIP extra data or a comment: ${path}`);
    if (seen.has(path.toLowerCase())) throw new Error(`Archive contains a duplicate or case-colliding path: ${path}`);
    seen.add(path.toLowerCase());
    if ((flags & ~UTF8_FLAG) !== 0) throw new Error(`Archive entry uses unsupported ZIP flags: ${path}`);
    if (method !== 0 && method !== 8) throw new Error(`Archive entry uses unsupported compression method ${method}: ${path}`);
    if (diskStart !== 0) throw new Error("Multi-disk ZIP archives are not valid .weave files");
    if ((madeBy >>> 8) === 3) {
      const fileType = (externalAttributes >>> 16) & 0o170000;
      if (fileType !== 0 && fileType !== 0o100000) throw new Error(`Archive contains a link or special file: ${path}`);
    }
    if (uncompressedSize > MAX_FILE_BYTES) throw new Error(`${path} exceeds the ${formatMiB(MAX_FILE_BYTES)} per-file limit`);
    if (path === "weave.json" && uncompressedSize > MAX_WEAVE_MANIFEST_BYTES) throw new Error(`weave.json exceeds the ${formatKiB(MAX_WEAVE_MANIFEST_BYTES)} manifest limit`);
    totalBytes += uncompressedSize;
    if (totalBytes > MAX_UNPACKED_BYTES) throw new Error(`Archive exceeds the ${formatMiB(MAX_UNPACKED_BYTES)} unpacked limit`);

    requireRange(bytes, localOffset, 30, "local file header");
    if (bytes.readUInt32LE(localOffset) !== ZIP_LOCAL_HEADER) throw new Error(`Archive local header is invalid: ${path}`);
    const localFlags = bytes.readUInt16LE(localOffset + 6);
    const localMethod = bytes.readUInt16LE(localOffset + 8);
    const localCrc = bytes.readUInt32LE(localOffset + 14);
    const localCompressedSize = bytes.readUInt32LE(localOffset + 18);
    const localUncompressedSize = bytes.readUInt32LE(localOffset + 22);
    const localNameLength = bytes.readUInt16LE(localOffset + 26);
    const localExtraLength = bytes.readUInt16LE(localOffset + 28);
    requireRange(bytes, localOffset + 30, localNameLength + localExtraLength, "local file header payload");
    const localPath = decodeUtf8(bytes.subarray(localOffset + 30, localOffset + 30 + localNameLength), "local archive path");
    if (localExtraLength !== 0) throw new Error(`Archive local entry contains unsupported ZIP extra data: ${path}`);
    if (localPath !== path || localFlags !== flags || localMethod !== method || localCrc !== crc || localCompressedSize !== compressedSize || localUncompressedSize !== uncompressedSize) {
      throw new Error(`Archive local and central metadata disagree: ${path}`);
    }
    const dataOffset = localOffset + 30 + localNameLength + localExtraLength;
    requireRange(bytes, dataOffset, compressedSize, "compressed file data");
    const dataEnd = dataOffset + compressedSize;
    if (dataEnd > centralOffset) throw new Error(`Archive file overlaps its central directory: ${path}`);
    ranges.push([localOffset, dataEnd]);
    const compressed = bytes.subarray(dataOffset, dataEnd);
    let data: Buffer;
    try {
      if (method === 0) {
        data = Buffer.from(compressed);
      } else {
        // Node's runtime returns this shape for `info: true`, although the
        // current @types/node sync overload still declares a bare Buffer.
        const inflated = inflateRawSync(compressed, { info: true, maxOutputLength: Math.max(1, uncompressedSize) }) as unknown as {
          buffer: Buffer;
          engine: { bytesWritten: number };
        };
        if (inflated.engine.bytesWritten !== compressed.length) throw new Error("trailing compressed data");
        data = Buffer.from(inflated.buffer);
      }
    } catch {
      throw new Error(`Archive entry could not be decompressed: ${path}`);
    }
    if (data.length !== uncompressedSize) throw new Error(`Archive entry size is invalid: ${path}`);
    if (crc32(data) !== crc) throw new Error(`Archive entry checksum is invalid: ${path}`);
    output.set(path, data);
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  if (cursor !== endOffset) throw new Error("Archive central directory entry count is invalid");
  rejectCaseCollisions([...output.keys()]);
  ranges.sort((a, b) => a[0] - b[0]);
  let expectedOffset = 0;
  for (const [start, end] of ranges) {
    if (start !== expectedOffset) throw new Error("Archive local file records must be contiguous and start at byte zero");
    expectedOffset = end;
  }
  if (expectedOffset !== centralOffset) throw new Error("Archive local file records do not end at the central directory");
  return output;
}

function findEndRecord(bytes: Buffer): number {
  if (bytes.length < 22) throw new Error("File is not a complete ZIP archive");
  const exactOffset = bytes.length - 22;
  if (bytes.readUInt32LE(exactOffset) === ZIP_END) {
    if (bytes.readUInt16LE(exactOffset + 20) !== 0) throw new Error("ZIP comments are not valid in a .weave file");
    return exactOffset;
  }
  const minimum = Math.max(0, bytes.length - 65_557);
  for (let offset = bytes.length - 22; offset >= minimum; offset -= 1) {
    if (bytes.readUInt32LE(offset) !== ZIP_END) continue;
    const commentLength = bytes.readUInt16LE(offset + 20);
    if (offset + 22 + commentLength === bytes.length) throw new Error("ZIP comments are not valid in a .weave file");
  }
  throw new Error("File is not a complete ZIP archive");
}

function parseManifest(data: Buffer): WeaveManifest {
  let value: unknown;
  try { value = JSON.parse(decodeUtf8(data, "weave.json")); }
  catch { throw new Error("weave.json is not valid UTF-8 JSON"); }
  if (!isRecord(value)) throw new Error("weave.json must contain an object");
  if (value.formatVersion !== FORMAT_VERSION) throw new Error(`Unsupported .weave format version: ${String(value.formatVersion)}`);
  requireKeys(value, ["formatVersion", "artifactId", "sourceId", "name", "provenance", "lineage", "declared"], "weave.json");
  if (!isArtifactId(value.artifactId)) throw new Error("weave.json artifactId must be a sha256 identity");
  if (!isArtifactId(value.sourceId)) throw new Error("weave.json sourceId must be a sha256 identity");
  if (typeof value.name !== "string") throw new Error("weave.json name must be a string");
  validateDisplayString(value.name, "weave.json name");
  if (!isRecord(value.provenance)) throw new Error("weave.json provenance must be an object");
  requireKeys(value.provenance, ["author"], "weave.json provenance");
  if (value.provenance.author !== null) {
    if (typeof value.provenance.author !== "string") throw new Error("weave.json provenance.author must be a string or null");
    validateDisplayString(value.provenance.author, "weave.json provenance.author");
  }
  if (!isRecord(value.lineage)) throw new Error("weave.json lineage must be an object");
  requireKeys(value.lineage, ["root", "parent"], "weave.json lineage");
  if (!isArtifactId(value.lineage.root) || (value.lineage.parent !== null && !isArtifactId(value.lineage.parent))) throw new Error("weave.json lineage identities must be sha256 identities or null");
  if (!isRecord(value.declared)) throw new Error("weave.json declared surface must be an object");
  requireKeys(value.declared, ["providers", "origins", "capabilities"], "weave.json declared surface");
  for (const field of ["providers", "origins", "capabilities"] as const) {
    if (!Array.isArray(value.declared[field]) || value.declared[field].some((item) => typeof item !== "string")) throw new Error(`weave.json declared.${field} must be a string array`);
  }
  return value as unknown as WeaveManifest;
}

function validateSourcePath(path: string): void {
  validatePortablePath(path, "source path");
  if (path === "weave.json") throw new Error("weave.json is reserved for artifact metadata");
}

function validateArchivePath(path: string): void {
  validatePortablePath(path, "archive path");
  if (path !== "weave.json" && !path.startsWith("source/")) throw new Error(`Archive contains a file outside weave.json and source/: ${path}`);
}

function validatePortablePath(path: string, kind: string): void {
  if (path.length === 0 || Buffer.byteLength(path, "utf8") > 512) throw new Error(`Invalid ${kind}: ${path || "<empty>"}`);
  if (path !== path.normalize("NFC") || path.includes("\\") || path.includes("\0") || path.startsWith("/") || path.includes(":") || path.endsWith("/") || /[<>"|?*]|[\u0000-\u001f]/.test(path)) throw new Error(`Unsafe ${kind}: ${path}`);
  const parts = path.split("/");
  if (parts.some((part) => part === "" || part === "." || part === ".." || part.endsWith(".") || part.endsWith(" ") || Buffer.byteLength(part, "utf8") > 255 || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part))) throw new Error(`Unsafe ${kind}: ${path}`);
}

function rejectCaseCollisions(paths: string[]): void {
  const seen = new Map<string, string>();
  const files = new Map<string, string>();
  for (const path of paths) {
    const fileKey = path.normalize("NFC").toLowerCase();
    const previousFile = files.get(fileKey);
    if (previousFile !== undefined) {
      if (previousFile === path) throw new Error(`Archive contains a duplicate path: ${path}`);
      throw new Error(`Paths collide on a case-insensitive filesystem: ${previousFile} and ${path}`);
    }
    files.set(fileKey, path);
    const parts = path.split("/");
    for (let length = 1; length <= parts.length; length += 1) {
      const spelling = parts.slice(0, length).join("/");
      const folded = spelling.normalize("NFC").toLowerCase();
      const previous = seen.get(folded);
      if (previous !== undefined && previous !== spelling) throw new Error(`Paths collide on a case-insensitive filesystem: ${previous} and ${spelling}`);
      seen.set(folded, spelling);
    }
  }
  for (const path of paths) {
    const parts = path.split("/");
    for (let length = 1; length < parts.length; length += 1) {
      const ancestor = parts.slice(0, length).join("/").normalize("NFC").toLowerCase();
      const file = files.get(ancestor);
      if (file !== undefined) throw new Error(`Archive file path is also used as a directory: ${file} and ${path}`);
    }
  }
}

function validateDisplayString(value: string, label: string): void {
  if (value.trim() === "" || /[\p{C}\p{Zl}\p{Zp}]/u.test(value)) {
    throw new Error(`${label} must be a non-empty string without control, line-separator, or paragraph-separator characters`);
  }
}

function requireKeys(value: Record<string, unknown>, keys: string[], label: string): void {
  const expected = new Set(keys);
  const actual = Object.keys(value);
  if (actual.some((key) => !expected.has(key)) || keys.some((key) => !(key in value))) throw new Error(`${label} has unknown or missing fields`);
}

function requireRange(bytes: Buffer, offset: number, length: number, label: string): void {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || offset + length > bytes.length) throw new Error(`Archive ${label} is truncated`);
}

function decodeUtf8(data: Uint8Array, label: string): string {
  try { return new TextDecoder("utf-8", { fatal: true }).decode(data); }
  catch { throw new Error(`${label} is not valid UTF-8`); }
}

function isArtifactId(value: unknown): value is string {
  return typeof value === "string" && /^sha256:[0-9a-f]{64}$/.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function formatMiB(bytes: number): string { return `${bytes / (1024 * 1024)} MiB`; }
function formatKiB(bytes: number): string { return `${bytes / 1024} KiB`; }

const CRC_TABLE = new Uint32Array(256).map((_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) value = (value & 1) !== 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});

function crc32(data: Uint8Array): number {
  let value = 0xffffffff;
  for (const byte of data) value = CRC_TABLE[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}
