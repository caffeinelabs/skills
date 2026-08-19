// The ingest pipeline, transport-agnostic: CSV records in, putSegment calls out.
// The CLI wires it to a mainnet/local canister through @dfinity/agent; a test
// wires it to a PocketIC actor. `actor` needs layout / rows / putSegment, the
// ImportData mixin's surface.
import { csvRecords } from "./csv.mjs";
import { buildImage, bytesWidth, imageBytes, utf8Len } from "./encode.mjs";
import { buildHashSegmentStreaming } from "./hash-segment.mjs";

// Decode one CSV field for a column type. An empty unquoted field is a null
// cell for every type; for '#text' a QUOTED empty field ("") stays the empty
// string, which is a real value.
function decodeField(type, field, where) {
	if (type === "#text")
		return field.text === "" && !field.quoted ? null : field.text;
	const s = field.text.trim();
	if (s === "") return null;
	{
		// '#bytes(w)': the CSV field is the cell's base64; must decode to exactly w bytes.
		const w = bytesWidth(type);
		if (w !== null) {
			const b = Uint8Array.from(Buffer.from(s, "base64"));
			if (b.length !== w)
				throw new Error(
					`${where}: base64 decodes to ${b.length} bytes, column is ${type}`,
				);
			return b;
		}
	}
	switch (type) {
		case "#nat": {
			const v = BigInt(s);
			// A cell is 64-bit; the same bounds Table.valueToCell traps on in-canister.
			// Caught here with the row/column for a clear message before the encoder.
			if (v < 0n) throw new Error(`${where}: ${s} is negative, column is #nat`);
			if (v > (1n << 64n) - 1n)
				throw new Error(
					`${where}: ${s} exceeds 2^64-1, too large for a #nat cell`,
				);
			return v;
		}
		case "#int": {
			const v = BigInt(s);
			if (v < -(1n << 63n) || v > (1n << 63n) - 1n)
				throw new Error(
					`${where}: ${s} is out of range for a 64-bit #int cell`,
				);
			return v;
		}
		case "#float": {
			const v = Number(s);
			if (Number.isNaN(v)) throw new Error(`${where}: '${s}' is not a number`);
			return v;
		}
		case "#bool": {
			const l = s.toLowerCase();
			if (l === "true" || l === "1") return true;
			if (l === "false" || l === "0") return false;
			throw new Error(`${where}: '${s}' is not a bool`);
		}
		default:
			throw new Error(`${where}: unsupported column type ${type}`);
	}
}

/// Upload rows as segment IMAGES: batch them until the next row would push the image
/// past `batchBytes`, then `putSegment` under the expect-first-row guard. This is the
/// whole data-side wire protocol in one place — image bytes, byte-paced batching,
/// ordered sends — so every producer speaks it identically: the CLI over a CSV and
/// the scale bench over a generator both call this. A second copy would let the tool
/// drift away from the numbers the bench reports.
///
/// `next()` yields the next row as an array of one value per column (`null` for a
/// null cell) and `null` when the source is exhausted; it may be async. `firstRow` is
/// where the table already stands, which is what `putSegment` is told to expect, so a
/// retried message traps instead of loading rows twice. Returns the new row count.
///
/// `beforeFirstSend` is awaited once, immediately before the first `putSegment`, and
/// not at all when there is nothing to send. That is where a DELTA load reopens the
/// table's committed indexes: the reopen has to precede the first image, because the
/// canister refuses to load into a table while any index is declared, and it must
/// equally not happen on a run that turns out to have no new rows — a reopened column
/// scans until an extension segment commits, and with no new rows there is no segment
/// left to send.
export async function uploadRows({
	actor,
	target,
	types,
	firstRow,
	next,
	batchBytes = 1_500_000,
	inFlight = 1,
	beforeFirstSend = () => {},
	onProgress = () => {},
}) {
	let sent = firstRow;
	let batch = [];
	let opened = false;
	const textBytes = types.map(() => 0);
	// Up to `inFlight` segments outstanding. Each carries the row it starts at, and the
	// canister holds one that arrives early until the gap before it fills, so the wire
	// does not idle for a round-trip per message. Positions are assigned here, in order,
	// whatever order the messages then execute in.
	const pending = new Set();

	// Await every outstanding send and surface the first failure. Awaiting one while
	// others are in flight would let their rejections escape unhandled.
	const settle = async () => {
		const all = [...pending];
		pending.clear();
		const results = await Promise.allSettled(all);
		const bad = results.find((r) => r.status === "rejected");
		if (bad) throw bad.reason;
	};

	const flush = async () => {
		if (batch.length === 0) return;
		if (!opened) {
			opened = true;
			await beforeFirstSend();
		}
		const image = buildImage(types, batch);
		const at = sent,
			count = batch.length;
		sent += count;
		batch = [];
		textBytes.fill(0);
		const p = actor.putSegment(target, BigInt(at), image).then((added) => {
			if (Number(added) !== count)
				throw new Error(`putSegment accepted ${added} of ${count} rows`);
			onProgress(at + count);
		});
		p.catch(() => {}); // the rejection is reported by settle(), not here
		pending.add(p);
		if (pending.size >= inFlight) await settle();
	};

	for (;;) {
		const row = await next();
		if (row === null || row === undefined) break;
		for (let c = 0; c < types.length; c++) {
			if (types[c] === "#text" && row[c] !== null)
				textBytes[c] += utf8Len(row[c]);
		}
		batch.push(row);
		if (imageBytes(types, batch.length, textBytes) >= batchBytes) await flush();
	}
	await flush();
	await settle();
	return sent;
}

/// Stream `csv` into `target` on `actor`. The canister's layout() is the schema
/// authority: the CSV header is matched to it by name (extra CSV columns are
/// ignored, a missing one is an error), so column order in the file never
/// matters. Resumes automatically: rows already in the table are skipped, and
/// putSegment's expectFirstRow guard turns any double-send into a loud trap
/// instead of duplicated rows. Sequential by design — segments must land in
/// order.
///
/// The same skipping makes a GROWN file a delta load: the records the table already
/// holds are skipped and only the new ones are sent. What is skipped is counted in
/// FILE records (`loadedRows`) and what is sent is placed by store POSITION (`rows`) —
/// see below; on a table that has only ever been loaded the two are equal. `beforeFirstSend` (see
/// `uploadRows`) is where the caller reopens the indexes those new rows have to get
/// past, and it is not called when the file has not grown.
export async function ingestCsv({
	actor,
	target,
	csv,
	batchBytes = 1_500_000,
	inFlight = 1,
	beforeFirstSend = () => {},
	onProgress = () => {},
	onStaged = () => {},
}) {
	const [layout] = await actor.layout(target);
	if (!layout)
		throw new Error(`canister has no import target named '${target}'`);
	const types = layout.columns.map((c) => c.colType);

	// TWO cursors, and they are different numbers the moment the table has taken an
	// ordinary write. `already` is how many records of THIS FILE the table holds, so it
	// is what to skip; `at` is the store POSITION the next segment begins at, so it is
	// what `putSegment` is told to expect. Using one for both skips a source record per
	// appended row and puts every later record at a position it does not occupy — and
	// nothing downstream can catch that, because the counts still balance.
	//
	// A canister without `loadedRows` predates the distinction; it can only have rows
	// that came from a file, so the two cursors coincide there.
	const [at0] = await actor.rows(target);
	if (at0 === undefined)
		throw new Error(`rows('${target}') refused — is the caller a controller?`);
	const at = Number(at0);
	// `actor.loadedRows` is present whenever the actor was built from this tool's IDL, which
	// is every real canister — the method exists on the binding whether or not the canister
	// implements it, so this is NOT a version check. What it does cover is the stub actors
	// the tests wire up, which really do lack the method. A canister too old to answer makes
	// the CALL reject, and that must not be swallowed: falling back to `rows` for both
	// cursors is the bug the two cursors exist to fix.
	let already = at;
	if (actor.loadedRows) {
		let loaded0;
		try {
			[loaded0] = await actor.loadedRows(target);
		} catch (e) {
			throw new Error(
				`'${target}': the canister does not answer loadedRows, so a load cannot tell ` +
					`source records from store positions. Deploy a canister built with this version of the ` +
					`ImportData mixin. (${String(e.message ?? e).split("\n")[0]})`,
			);
		}
		if (loaded0 === undefined)
			throw new Error(
				`loadedRows('${target}') refused — is the caller a controller?`,
			);
		already = Number(loaded0);
	}

	// --- #4: staged segments from an interrupted parallel run. `rows()` is the contiguous
	// frontier and does not count them, so resuming straight away can emit a segment that
	// overlaps one still waiting — refused loudly, but the load is then stuck until they go.
	// Their rows were never counted, so dropping them is exactly the documented recovery, and
	// doing it here is what makes an interrupted `--in-flight` run simply re-runnable.
	if (actor.stagedSegments && actor.dropStagedSegments) {
		const [staged] = await actor.stagedSegments(target);
		if (staged !== undefined && Number(staged) > 0) {
			const dropped = await actor.dropStagedSegments(target);
			onStaged(Number(staged), Number(dropped));
		}
	}

	const records = csvRecords(csv);
	const first = await records[Symbol.asyncIterator]().next();
	if (first.done) throw new Error("empty CSV");
	const header = first.value.map((f) => f.text.trim());
	const pos = layout.columns.map((c) => {
		const i = header.indexOf(c.name);
		if (i < 0)
			throw new Error(
				`CSV is missing column '${c.name}' (header: ${header.join(", ")})`,
			);
		return i;
	});

	let lineNo = 1; // header was line 1
	let seen = 0; // data rows seen (for resume skipping)
	const it = records[Symbol.asyncIterator]();

	// Decode the next row the table still needs, skipping the ones it already has.
	const next = async () => {
		for (;;) {
			const { done, value: rec } = await it.next();
			if (done) return null;
			lineNo++;
			seen++;
			if (seen <= already) continue; // resume: this row is already in the table
			return types.map((t, c) => {
				const f = rec[pos[c]];
				if (f === undefined)
					throw new Error(`line ${lineNo}: only ${rec.length} fields`);
				return decodeField(
					t,
					f,
					`line ${lineNo}, column '${layout.columns[c].name}'`,
				);
			});
		}
	};

	const sent = await uploadRows({
		actor,
		target,
		types,
		firstRow: at,
		next,
		batchBytes,
		inFlight,
		beforeFirstSend,
		onProgress,
	});
	return {
		loaded: sent - at,
		skipped: Math.min(seen, already),
		total: sent,
		appended: at - already,
	};
}

/// Columns of `target` whose region index is COMPLETE — its segments cover every
/// loaded row. That is the state in which the column answers from the index and the
/// canister refuses any further `putSegment`, so it is exactly the set a DELTA load
/// has to reopen before the rows and re-cover after them. Empty for a table with no
/// rows, and for an actor without the resume surface (a stub that only records the
/// bytes a producer emits).
///
/// A column part-way through its FIRST index upload is deliberately not here: coverage
/// below the row count means it is still pending, holds no decl, and needs no reopen —
/// the load already gets past the gate and `uploadIndex` covers old and new in one pass.
///
/// Read-only, and taken before a byte is sent, so the caller can refuse a run that
/// would strand a column it does not name.
export async function indexedColumns({ actor, target }) {
	if (!actor.indexCoverage) return [];
	const [layout] = await actor.layout(target);
	if (!layout)
		throw new Error(`canister has no import target named '${target}'`);
	const [loaded] = await actor.rows(target);
	if (loaded === undefined)
		throw new Error(`rows('${target}') refused — is the caller a controller?`);
	const total = Number(loaded);
	if (total === 0) return [];
	const out = [];
	for (const c of layout.columns) {
		// EVERY column that has a region index, whatever state it is in — not just the
		// complete ones. A column mid-extension, or mid-first-upload, still needs this run to
		// finish it: leave it out and the run loads more rows, reports success, and leaves
		// that index partial for good.
		//
		// Readiness alone is the wrong test twice over. `coverage === rows()` stops being true
		// at the first ordinary write, so a complete index reads as unfinished; and `ready ===
		// false` is true of an interrupted extension, which reads as "no index here at all".
		if (actor.indexState) {
			const [st] = await actor.indexState(target, c.name);
			if (st === undefined)
				throw new Error(
					`indexState('${target}', '${c.name}') refused — is the caller a controller?`,
				);
			if (!("none" in st)) out.push(c.name);
			continue;
		}
		const [cov] = await actor.indexCoverage(target, c.name);
		if (cov === undefined)
			throw new Error(
				`indexCoverage('${target}', '${c.name}') refused — is the caller a controller?`,
			);
		if (Number(cov) === total) out.push(c.name);
	}
	return out;
}

/// Reopen every column in `cols` that has a committed region index, so rows loaded
/// after it can be covered by FURTHER index segments instead of a re-upload of the
/// whole base — 826 MB and minutes of it at 100M rows. Returns the columns that
/// actually moved; a column with no committed index, or one an interrupted run already
/// reopened, answers false and is skipped.
///
/// Call this from `uploadRows`'s `beforeFirstSend`: it must run before the first data
/// segment, since dropping the decls is what lets the table be loaded at all, and it
/// must not run when there is nothing to load — a reopened column scans until an
/// extension segment commits, and with no new rows there is no segment left to send.
export async function reopenIndexes({
	actor,
	target,
	cols,
	onAbsorb = () => {},
}) {
	if (!actor.reopenIndex) return [];
	const done = [];
	for (const col of cols) {
		// A chunk per call. Rows the canister appended between ingests are not in any file,
		// so the canister indexes them itself — and the gap is however many it wrote, which
		// is unbounded, so it comes back `absorbing` until it is through. Driven from here
		// rather than by a canister timer: an upgrade drops a timer, and the cursor is the
		// column's own coverage, so an interrupted run just calls again.
		for (;;) {
			const r = await actor.reopenIndex(target, col);
			if ("reopened" in r) {
				done.push(col);
				break;
			}
			if ("none" in r) break; // no committed index on this column
			onAbsorb(col, Number(r.absorbing));
		}
	}
	return done;
}

/// Upload and commit ONE index segment covering `[firstRow, firstRow + rows)`,
/// reading each value through `keyAt(local)` for `local` in `[0, rows)`. This is the
/// whole on-the-wire protocol in one place — segment bytes, ordered chunks under the
/// expect-offset guard (a retried chunk traps rather than duplicating), then
/// `commitIndex` — so every producer speaks it identically: the CLI over a CSV and
/// the scale bench over a generator both call this. Returns the segment's byte
/// length.
///
/// The caller owns the row source and the segment size, and must emit segments in
/// ascending order with no gap: they have to tile `[0, rows_loaded)` before the
/// column serves, and the canister traps on a gap or overlap. Only the commit that
/// completes the tiling flips the column ready; until then queries scan, which is a
/// correct superset.
export async function putIndexSegment({
	actor,
	target,
	col,
	colType,
	firstRow,
	rows,
	keyAt,
	chunkBytes = 1_500_000,
	inFlight = 1,
}) {
	const seg = buildHashSegmentStreaming(colType, firstRow, rows, keyAt);
	const segLen = seg.length;
	// A segment's bytes are reserved by its first chunk, so each chunk names its own
	// offset and they need no ordering between them — several can be on the wire at once.
	// The canister refuses an overlapping chunk, so a re-send still fails loudly.
	const pending = new Set();
	const settle = async () => {
		const all = [...pending];
		pending.clear();
		const results = await Promise.allSettled(all);
		const bad = results.find((r) => r.status === "rejected");
		if (bad) throw bad.reason;
	};
	try {
		for (let off = 0; off < segLen; off += chunkBytes) {
			const end = Math.min(off + chunkBytes, segLen);
			const at = off;
			const p = actor
				.putIndexChunk(
					target,
					col,
					{ hash: null },
					BigInt(firstRow),
					BigInt(segLen),
					BigInt(at),
					seg.subarray(at, end),
				)
				.then((filled) => {
					if (Number(filled) !== end)
						throw new Error(
							`putIndexChunk at ${at} reported ${filled}, expected ${end}`,
						);
				});
			p.catch(() => {}); // reported by settle(), not as an unhandled rejection
			pending.add(p);
			if (pending.size >= inFlight) await settle();
		}
		await settle(); // every byte must be in before the commit
		await actor.commitIndex(target, col);
	} catch (e) {
		// Drop the half-uploaded segment: while one is staged the canister refuses a
		// different one, so leaving it would make the retry fail on the staging rather
		// than on whatever went wrong here. The failure this is recovering from is what
		// the caller must see, so an abort that itself fails does not replace it.
		if (actor.abortIndexUpload) {
			try {
				await actor.abortIndexUpload(target);
			} catch {}
		}
		throw e;
	}
	return segLen;
}

// One segment's worth of decoded values, held in a TYPED buffer: the CSV is read
// once, sequentially, but a segment's values are needed twice (the builder tallies
// per-key counts, then scatters positions), so they have to be held somewhere. A
// plain array of 32M BigInts would cost gigabytes in boxing alone; this is 9 B/row —
// the value word plus a non-null flag — which is what makes `--index-seg` a
// meaningful memory bound rather than a rough one.
function segBuffer(colType, n) {
	// Checked here because this is where the number becomes an allocation: a string
	// '900' sizes the arrays but never equals `held`, so the caller keeps writing past
	// the end, where a typed array drops the value and reads back `undefined` — an
	// undefined key encodes as something wrong rather than failing.
	if (!Number.isSafeInteger(n) || n < 1)
		throw new Error(
			`rows per index segment must be an integer >= 1, got ${JSON.stringify(n)}`,
		);
	const mask = new Uint8Array(n);
	const vals =
		colType === "#nat"
			? new BigUint64Array(n)
			: colType === "#int"
				? new BigInt64Array(n)
				: colType === "#float"
					? new Float64Array(n)
					: colType === "#bool"
						? new Uint8Array(n)
						: new Array(n); // #text: the strings themselves
	// Out of range is a producer bug, and a silent one: a typed array swallows the
	// write and reads back `undefined`, which the segment builder would encode as a key.
	const bound = (i) => {
		if (!(i >= 0 && i < n))
			throw new Error(`index-segment buffer: row ${i} is outside [0, ${n})`);
	};
	return {
		set(i, v) {
			bound(i);
			if (v === null) {
				mask[i] = 0;
			} else {
				mask[i] = 1;
				vals[i] = colType === "#bool" ? (v ? 1 : 0) : v;
			}
		},
		at(i) {
			bound(i);
			return mask[i] === 0
				? null
				: colType === "#bool"
					? vals[i] === 1
					: vals[i];
		},
	};
}

/// Build a region index over `col` and upload it as SEGMENTS, STREAMING the CSV:
/// values are buffered only up to `rowsPerSeg`, so the producer's peak memory is one
/// segment's worth however many rows the table holds. Collecting the whole column
/// first would put an array proportional to the TABLE in the producer — the very
/// thing segmenting the index exists to avoid, and the reason a 10B-row load is
/// possible at all.
///
/// The CSV must list the rows in the order they were loaded: a segment's postings are
/// store positions. `kind` is 'hash'. Returns the total rows covered.
///
/// Resumes like the data side: the column's committed segments tile `[0, covered)`,
/// so an interrupted run restarts at `covered` — those source rows are skipped and the
/// next segment starts exactly where the coverage guard demands. Any partial segment
/// the interrupted run left staged is dropped first; while one is staged the canister
/// refuses a different one.
///
/// A DELTA load is the same code path with nothing added: the reopen left `covered`
/// at the old base's end and the row count has grown past it, so the segments emitted
/// from there EXTEND the base rather than replace it, and the commit that reaches the
/// new row count puts the column back in service.
export async function uploadIndex({
	actor,
	target,
	col,
	kind,
	csv,
	rowsPerSeg = 32_000_000,
	chunkBytes = 1_500_000,
	inFlight = 1,
	onProgress = () => {},
}) {
	if (kind !== "hash")
		throw new Error(`index kind '${kind}' is not supported (only 'hash')`);
	const [layout] = await actor.layout(target);
	if (!layout)
		throw new Error(`canister has no import target named '${target}'`);
	const ci = layout.columns.findIndex((c) => c.name === col);
	if (ci < 0) throw new Error(`'${col}' is not a column of '${target}'`);
	const colType = layout.columns[ci].colType;
	const [loaded] = await actor.rows(target);
	const total = loaded === undefined ? 0 : Number(loaded);

	// Where a previous run got to. `indexCoverage` and `abortIndexUpload` are the
	// mixin's resume surface; a stub actor that only records the bytes a producer emits
	// has neither, and starts from row 0.
	// Rows the table holds that did NOT come from a file — the canister's own appends. After
	// a reopen the base covers them, so they sit inside `covered` while occupying no CSV
	// record: `covered` is a POSITION, not a record offset, and the two differ by exactly
	// this.
	let ownRows = 0;
	if (actor.loadedRows) {
		const [l] = await actor.loadedRows(target);
		if (l !== undefined) ownRows = total - Number(l);
	}

	// Where a previous run got to. `indexCoverage` and `abortIndexUpload` are the mixin's
	// resume surface; a stub actor that only records the bytes a producer emits has neither,
	// and starts from row 0.
	let covered = 0;
	if (actor.indexCoverage) {
		const [c] = await actor.indexCoverage(target, col);
		if (c === undefined)
			throw new Error(
				`indexCoverage('${target}', '${col}') refused — is the caller a controller?`,
			);
		covered = Number(c);
	}

	// What state this column's index is in decides whether an upload is possible at all.
	let state = null;
	if (actor.indexState) {
		const [st] = await actor.indexState(target, col);
		if (st === undefined)
			throw new Error(
				`indexState('${target}', '${col}') refused — is the caller a controller?`,
			);
		state = st;
	}
	if (state && "ready" in state) {
		// Complete already. Extending it traps ("already fully committed"), which is what a
		// re-run over an UNCHANGED file did once the canister had appended a row: no new rows
		// meant no reopen, and this went ahead regardless. A re-run is documented as a no-op,
		// so be one. The appended rows are not stranded — the next run that actually loads
		// reopens the column, and the reopen absorbs them.
		return covered;
	}
	if (ownRows > 0 && state && ("none" in state || "building" in state)) {
		// The file cannot describe this table. Rows the canister appended sit at positions no
		// record covers, and a base built from the file tiles upward from 0, so it runs onto
		// one of them and claims it holds a file value. There is no arithmetic fix: subtracting
		// the appended count only works once those rows are already INSIDE the coverage, which
		// is what a reopen's absorb arranges and which a column with no complete base has never
		// had. Run it twice without this and the second run indexes the last record at the
		// appended row's position, then marks that base ready.
		throw new Error(
			`'${col}' has no complete index and '${target}' holds ${ownRows} row(s) the canister ` +
				`appended itself, which no CSV record describes. Build this index on-chain instead, which ` +
				`walks the table's own rows: dropIndexBase('${target}', '${col}', ${covered}) to clear the ` +
				`${covered} row(s) already committed, then buildIndex('${target}', ['${col}'], hash)`,
		);
	}
	if (actor.indexCoverage) {
		if (total > 0 && covered === total) return covered; // every loaded row is already indexed
		await actor.abortIndexUpload(target);
	}
	// CSV records the base already covers. Skipping `covered` of them instead would skip one
	// record per appended row and then label the rest with positions they do not occupy:
	// load A,B,C — append X — absorb — load D,E leaves coverage at 4, and skipping 4 records
	// indexes E at position 4, which holds D. Every query on the extension is then wrong.
	const skip = covered - ownRows;

	const records = csvRecords(csv);
	const head = await records[Symbol.asyncIterator]().next();
	if (head.done) throw new Error("empty CSV");
	const header = head.value.map((f) => f.text.trim());
	const pos = header.indexOf(col);
	if (pos < 0) throw new Error(`CSV is missing column '${col}'`);

	const buf = segBuffer(colType, rowsPerSeg);
	let firstRow = covered,
		held = 0,
		lineNo = 1,
		seen = 0;
	async function flush() {
		if (held === 0) return;
		await putIndexSegment({
			actor,
			target,
			col,
			colType,
			firstRow,
			rows: held,
			keyAt: (r) => buf.at(r),
			chunkBytes,
			inFlight,
		});
		firstRow += held;
		held = 0;
		onProgress(firstRow, total);
	}
	for await (const rec of records) {
		lineNo++;
		seen++;
		if (seen <= skip) continue; // resume: this record is in a committed segment
		buf.set(
			held,
			decodeField(colType, rec[pos], `line ${lineNo}, column '${col}'`),
		);
		held++;
		if (held === rowsPerSeg) await flush();
	}
	await flush();
	return firstRow;
}
