#!/usr/bin/env node
import { execFile } from "node:child_process";
// Ingest a CSV into a columnar table served by the ImportData mixin.
//
//   oql-ingest --canister <id> --target <name> --file <data.csv>
//              [--host <url>]        default http://127.0.0.1:4943 (local replica)
//              [--pem <identity.pem>] secp256k1 PEM; anonymous when omitted
//              [--batch-bytes <n>]   image size target, default 1.5 MB
//              [--index <col:kind>]  build+upload a region index after the data;
//                                    repeatable; kind is 'hash' (e.g. acct:hash)
//              [--in-flight <n>]     uploads outstanding at once, default 1. Every
//                                    upload names where its bytes belong, so the canister
//                                    places them in whatever order they execute; >1 stops
//                                    the wire idling for a round-trip per message, which
//                                    is what fills a block on mainnet. Applies to the
//                                    data segments and to an index segment's chunks.
//              [--index-seg <rows>]  rows per index segment (the M knob); the
//                                    producer builds one segment at a time, so
//                                    this caps its peak memory. Default 32,000,000
//                                    (~256 MB, ≈800 data segments at 40k rows/seg)
//
// The canister's layout() is the schema authority: the CSV header is matched to
// its column names, so the file's column order never matters. Interrupted runs
// just re-run — rows already loaded are skipped, and the mixin's expectFirstRow
// guard makes a double-send trap rather than duplicate. An index resumes the same
// way, from the rows its committed segments already cover.
//
// Re-running against a GROWN file is a DELTA load: only the rows past what the
// table holds are sent, and each index is EXTENDED over them by segments covering
// just those rows — never re-uploaded whole. Because that reopens every indexed
// column, the run has to name them all with --index; it is refused up front if it
// does not. Re-running against an unchanged file stays a no-op: nothing is sent
// and nothing is reopened.
import { createReadStream, statSync } from "node:fs";
import { rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs, promisify } from "node:util";
import {
	indexedColumns,
	ingestCsv,
	reopenIndexes,
	uploadIndex,
} from "./lib.mjs";

const USAGE = `oql-ingest — load a CSV into a columnar OQL table

  oql-ingest --canister <id> --target <name> --file <data.csv> [options]

Required
  --canister <id>        target canister: a principal, or a name from your
                         icp.yaml (resolved against -e, or the project's
                         default environment when run inside the project)
  --target <name>        the ImportData target name declared in the canister
  --file <data.csv>      the CSV to load; its header is matched to the table's
                         columns by name, so column order does not matter

Connection — the wire is icp-cli (every call is an \`icp canister call\`)
  -n, --network <name|url>  network to target: 'ic' (mainnet) or a name from your
                         icp.yaml; a raw URL also needs --root-key
  --root-key <val>       'mainnet', 'fetch', or a hex root key — required when
                         --network is a URL (e.g. a test replica)
  -e, --environment <e>  icp environment to resolve a canister NAME against
  --identity <name>      icp identity to sign with (default: your current one).
                         The endpoints are controller-only, so it must be a
                         controller of the canister
  Omit all four to use your icp defaults (local environment, current identity).

Indexes
  --index <col:kind>     build and upload an index for that column after the rows;
                         repeatable. kind is 'hash' (e.g. --index acct:hash)
  --index-seg <rows>     rows per index segment, default 32000000. The producer
                         builds one segment at a time, so this caps its memory

Throughput
  --batch-bytes <n>      target image size, default 1500000 (must stay under the
                         ~2 MiB ingress message limit)
  --in-flight <n>        uploads outstanding at once, default 1. Each names where
                         its bytes belong, so the canister places them in whatever
                         order they execute; >1 stops the wire idling for a
                         round-trip per message, which is what fills a block on
                         mainnet. Applies to data segments and to index chunks

  -h, --help             this message

An interrupted run just re-runs: rows already loaded are skipped, and an index
resumes from the rows its committed segments already cover.

Loading MORE data later is the same command against a grown file: only the new
rows are sent, and each index is extended over them by segments covering only
those rows. The load reopens every column the table already indexes, so the run
must name each of them with --index; it is refused before anything is sent if it
does not. Against an unchanged file the run is a no-op.`;

const die = (msg, code = 2) => {
	console.error(`oql-ingest: ${msg}`);
	process.exit(code);
};

let opt;
try {
	({ values: opt } = parseArgs({
		options: {
			canister: { type: "string" },
			target: { type: "string" },
			file: { type: "string" },
			network: { type: "string", short: "n" },
			"root-key": { type: "string" },
			environment: { type: "string", short: "e" },
			identity: { type: "string" },
			"batch-bytes": { type: "string", default: "1500000" },
			index: { type: "string", multiple: true, default: [] },
			"index-seg": { type: "string", default: "32000000" },
			"in-flight": { type: "string", default: "1" },
			help: { type: "boolean", short: "h", default: false },
		},
	}));
} catch (e) {
	// parseArgs throws for an unknown flag or a missing value; its message is precise
	// but it comes with a stack trace nobody wants as a first impression.
	die(`${e.message}\n\n${USAGE}`);
}
if (opt.help) {
	console.log(USAGE);
	process.exit(0);
}

// Everything checkable locally is checked BEFORE the agent is built. Otherwise the
// first failure is always a connection error from @dfinity/agent, whatever the actual
// mistake was — a missing file reported as an unreachable host.
for (const k of ["canister", "target", "file"]) {
	if (!opt[k]) die(`missing --${k}\n\n${USAGE}`);
}
// A principal ("ryjl3-tyaaa-…") or a canister name — a name resolves against
// -e, or against the default (local) environment of the project you run from.
if (!/^[a-zA-Z0-9_-]+$/.test(opt.canister))
	die(`--canister '${opt.canister}' is not a canister principal or name`);
try {
	if (!statSync(opt.file).isFile()) die(`--file '${opt.file}' is not a file`);
} catch (e) {
	if (e?.code === "ENOENT") die(`--file '${opt.file}' does not exist`);
	die(`--file '${opt.file}': ${e.message}`);
}
// Numeric options, checked rather than left to coerce: NaN would make the in-flight
// window's `pending.size >= inFlight` never true, so every message would be
// outstanding at once, and a 0 or negative batch size loops forever.
for (const [k, min] of [
	["batch-bytes", 1],
	["index-seg", 1],
	["in-flight", 1],
]) {
	const v = Number(opt[k]);
	if (!Number.isInteger(v) || v < min)
		die(`--${k} must be an integer >= ${min}, got '${opt[k]}'`);
}
const indexes = opt.index.map((spec) => {
	const [col, kind = "hash"] = spec.split(":");
	if (!col) die(`--index '${spec}' must be col:kind, e.g. acct:hash`);
	if (kind !== "hash")
		die(`--index '${spec}': kind must be 'hash', got '${kind}'`);
	return { col, kind };
});

// ── The wire: `icp canister call` ──────────────────────────────────────────
// Every message goes through icp-cli: arguments are written to a temp file in
// Candid TEXT form (--args-file), the response is read back from --json's
// `response_candid` and parsed for the handful of shapes the ImportData
// surface returns. Identity, networks and root keys are icp-cli's business —
// the connection flags pass straight through. The object below mirrors the
// agent-js value mapping lib.mjs expects: opt → []/[v], nat → BigInt,
// variant → { tag: value | null }.
const connArgs = [
	...(opt.network ? ["--network", opt.network] : []),
	...(opt["root-key"] ? ["--root-key", opt["root-key"]] : []),
	...(opt.environment ? ["--environment", opt.environment] : []),
	...(opt.identity ? ["--identity", opt.identity] : []),
];
const execFileP = promisify(execFile);
let argSeq = 0;

async function icpCall(method, argText, query) {
	const argsFile = join(tmpdir(), `oql-ingest-${process.pid}-${argSeq++}.args`);
	await writeFile(argsFile, argText);
	try {
		const { stdout } = await execFileP(
			"icp",
			[
				"canister",
				"call",
				opt.canister,
				method,
				"--args-file",
				argsFile,
				"--json",
				...(query ? ["--query"] : []),
				...connArgs,
			],
			{ maxBuffer: 64 * 1024 * 1024 },
		);
		const parsed = JSON.parse(stdout);
		if (typeof parsed.response_candid !== "string")
			throw new Error(`no candid in the response: ${stdout.slice(0, 200)}`);
		return parsed.response_candid;
	} catch (e) {
		// icp's stderr carries the real sentence (a canister trap, a controller
		// rejection, an unknown network); surface its last non-empty line.
		const lines = String(e?.stderr || e?.message || e)
			.trim()
			.split("\n")
			.filter((l) => l.trim());
		throw new Error(`${method}: ${lines[lines.length - 1] ?? "unknown error"}`);
	} finally {
		await rm(argsFile, { force: true });
	}
}

// Candid text builders (arguments)…
const ctext = (v) =>
	`"${String(v).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
const BYTE = Array.from(
	{ length: 256 },
	(_, i) => `\\${i.toString(16).padStart(2, "0")}`,
);
function cblob(bytes) {
	const parts = new Array(bytes.length);
	for (let i = 0; i < bytes.length; i++) parts[i] = BYTE[bytes[i]];
	return `blob "${parts.join("")}"`;
}

// …and response parsers. Strict: an unrecognised shape dies loudly rather
// than feeding lib.mjs a wrong value.
const unesc = (v) => v.replace(/\\"/g, '"').replace(/\\\\/g, "\\");
const parseNat = (c) => {
	const m = /(\d[\d_]*)\s*:\s*nat/.exec(c);
	if (!m) throw new Error(`expected a nat, got: ${c.trim()}`);
	return BigInt(m[1].replace(/_/g, ""));
};
const parseBool = (c) => {
	if (/\btrue\b/.test(c)) return true;
	if (/\bfalse\b/.test(c)) return false;
	throw new Error(`expected a bool, got: ${c.trim()}`);
};
const parseOpt = (c, inner) => (/\bopt\b/.test(c) ? [inner(c)] : []);
const parseVariant = (c) => {
	const m =
		/variant\s*\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*(\d[\d_]*))?/.exec(c);
	if (!m) throw new Error(`expected a variant, got: ${c.trim()}`);
	return { [m[1]]: m[2] !== undefined ? BigInt(m[2].replace(/_/g, "")) : null };
};
const parseLayout = (c) => {
	if (!/\bopt\b/.test(c)) return [];
	const columns = [];
	const re =
		/name\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*colType\s*=\s*"((?:[^"\\]|\\.)*)"/g;
	let m = re.exec(c);
	while (m !== null) {
		columns.push({ name: unesc(m[1]), colType: unesc(m[2]) });
		m = re.exec(c);
	}
	return [{ columns }];
};

const actor = {
	layout: async (target) =>
		parseLayout(await icpCall("layout", `(${ctext(target)})`, true)),
	rows: async (target) =>
		parseOpt(await icpCall("rows", `(${ctext(target)})`, true), parseNat),
	loadedRows: async (target) =>
		parseOpt(await icpCall("loadedRows", `(${ctext(target)})`, true), parseNat),
	stagedSegments: async (target) =>
		parseOpt(
			await icpCall("stagedSegments", `(${ctext(target)})`, true),
			parseNat,
		),
	dropStagedSegments: async (target) =>
		parseNat(await icpCall("dropStagedSegments", `(${ctext(target)})`, false)),
	indexState: async (target, col) =>
		parseOpt(
			await icpCall("indexState", `(${ctext(target)}, ${ctext(col)})`, true),
			parseVariant,
		),
	indexCoverage: async (target, col) =>
		parseOpt(
			await icpCall("indexCoverage", `(${ctext(target)}, ${ctext(col)})`, true),
			parseNat,
		),
	putSegment: async (target, firstRow, image) =>
		parseNat(
			await icpCall(
				"putSegment",
				`(${ctext(target)}, ${firstRow} : nat, ${cblob(image)})`,
				false,
			),
		),
	putIndexChunk: async (
		target,
		col,
		_kind,
		firstRow,
		segLen,
		expectOffset,
		chunk,
	) =>
		parseNat(
			await icpCall(
				"putIndexChunk",
				`(${ctext(target)}, ${ctext(col)}, variant { hash }, ${firstRow} : nat, ${segLen} : nat, ${expectOffset} : nat, ${cblob(chunk)})`,
				false,
			),
		),
	commitIndex: async (target, col) =>
		parseNat(
			await icpCall("commitIndex", `(${ctext(target)}, ${ctext(col)})`, false),
		),
	reopenIndex: async (target, col) =>
		parseVariant(
			await icpCall("reopenIndex", `(${ctext(target)}, ${ctext(col)})`, false),
		),
	abortIndexUpload: async (target) =>
		parseBool(await icpCall("abortIndexUpload", `(${ctext(target)})`, false)),
};

// One handler for everything past this point: a canister trap, an unreachable host or a
// wrong identity should read as a sentence. `--debug` keeps the stack for a real bug.
const fail = (what, e) => {
	const msg = String(e?.message ?? e).split("\n")[0];
	console.error(`\noql-ingest: ${what}: ${msg}`);
	if (process.env.OQL_INGEST_DEBUG) console.error(e);
	process.exit(1);
};

// Which columns the table already indexes COMPLETELY. Loading more rows reopens every
// one of them — that is what lets the table be loaded at all — and each then scans
// until this run's segments cover the new rows, so a run that does not name one would
// strand it. Read here, before a byte is sent; the reopen itself waits until the load
// has actually found a new row, so a re-run over an unchanged file touches nothing.
const quoted = (cols) => cols.map((c) => `'${c}'`).join(", ");
let indexed = [];
try {
	indexed = await indexedColumns({ actor, target: opt.target });
} catch (e) {
	fail(`inspecting '${opt.target}'`, e);
}
const unnamed = indexed.filter((c) => !indexes.some((i) => i.col === c));

const t0 = performance.now();
let res;
try {
	res = await ingestCsv({
		actor,
		target: opt.target,
		csv: createReadStream(opt.file),
		batchBytes: Number(opt["batch-bytes"]),
		inFlight: Number(opt["in-flight"]),
		beforeFirstSend: async () => {
			if (unnamed.length > 0)
				die(
					`'${opt.target}' has more rows to load and a committed index on ${quoted(unnamed)}` +
						` — loading reopens every indexed column, and one this run does not rebuild is left scanning.` +
						` Add: ${unnamed.map((c) => `--index ${c}:hash`).join(" ")}`,
				);
			const reopened = await reopenIndexes({
				actor,
				target: opt.target,
				cols: indexed,
				onAbsorb: (col, left) =>
					process.stdout.write(
						`\rindexing '${col}' rows this canister appended itself: ${left.toLocaleString("en-US")} left   `,
					),
			});
			if (reopened.length > 0)
				console.log(
					`delta load: reopened the index on ${quoted(reopened)}` +
						` — scanned until the segments below cover the new rows`,
				);
		},
		onStaged: (n, dropped) =>
			console.log(
				`dropped ${n.toLocaleString("en-US")} segment(s) an interrupted run left` +
					` waiting on a gap (${dropped.toLocaleString("en-US")} rows, never counted) — resuming from the row count`,
			),
		onProgress: (n) =>
			process.stdout.write(
				`\r${n.toLocaleString("en-US")} rows in canister   `,
			),
	});
} catch (e) {
	fail(`loading '${opt.target}' from ${opt.file}`, e);
}
process.stdout.write("\r");
const s = (performance.now() - t0) / 1000;
console.log(
	`loaded ${res.loaded.toLocaleString("en-US")} rows` +
		(res.skipped
			? ` (skipped ${res.skipped.toLocaleString("en-US")} already present)`
			: "") +
		(res.appended
			? `, past ${res.appended.toLocaleString("en-US")} row(s) the canister appended itself`
			: "") +
		` in ${s.toFixed(1)} s — table now holds ${res.total.toLocaleString("en-US")}`,
);

// Region indexes, built off-chain and uploaded after the data: one CSV pass per
// index, streamed, holding at most `--index-seg` values at a time.
for (const { col, kind } of indexes) {
	let rows;
	try {
		rows = await uploadIndex({
			actor,
			target: opt.target,
			col,
			kind,
			csv: createReadStream(opt.file),
			rowsPerSeg: Number(opt["index-seg"]),
			inFlight: Number(opt["in-flight"]),
			onProgress: (done, tot) =>
				process.stdout.write(
					`\rindexing ${col}: ${tot ? Math.floor((100 * done) / tot) : 0}%   `,
				),
		});
	} catch (e) {
		fail(`building the ${kind} index on '${col}'`, e);
	}
	process.stdout.write("\r");
	console.log(
		`built ${kind} index on '${col}' over ${rows.toLocaleString("en-US")} rows`,
	);
}
