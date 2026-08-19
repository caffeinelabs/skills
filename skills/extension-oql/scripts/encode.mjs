// Generic segment-image encoder — the producer side of src/columnar/Image.mo,
// for any column list a canister's layout() reports.
//
// A cell value is null, or by column type: '#nat'/'#int' a BigInt, '#float' a
// number, '#bool' a boolean, '#text' a string. The image carries the trailer
// footers (live count, nulls, min, max, 128-bit sum), computed here in the same
// pass that writes the blocks — the canister reads them rather than deriving
// them, which is what keeps its ingest O(columns).

const HEADER = 32,
	DIRENT = 16,
	TRAILER = 48;
const MAGIC = 0x4f514c53,
	VERSION = 1;
const U64 = 1n << 64n;
// A cell is a fixed 64-bit word, so a #nat must fit [0, 2^64) and an #int must
// fit [-2^63, 2^63) — exactly the bounds Table.valueToCell traps on in-canister.
// Reject out-of-range values here rather than let BigUint64 wrap them silently:
// the append path fails loudly for the same input, and an image must not be the
// one way to smuggle a corrupted value past that check.
const NAT_MAX = U64 - 1n,
	INT_MIN = -(1n << 63n),
	INT_MAX = (1n << 63n) - 1n;
const utf8 = new TextEncoder();

const bitmapWords = (rows) => Math.ceil(rows / 64);
const pad8 = (n) => Math.ceil(n / 8) * 8;
// '#bytes(w)' → w, or null for every other type. A #bytes cell is a Uint8Array
// of exactly w bytes; the block is [ bitmap | rows × w raw bytes, padded to 8 ]
// with directory kind 2 and the stride in the directory's u32 at offset 4.
export const bytesWidth = (t) => {
	const m = /^#bytes\((\d+)\)$/.exec(t);
	return m ? Number(m[1]) : null;
};

/// Exact image size for `rows` cell-rows over `colTypes` — what a batcher uses
/// to stay under the ingress cap. `textBytes[c]` is the running UTF-8 byte total
/// of column c (0 for fixed-width columns).
export function imageBytes(colTypes, rows, textBytes) {
	const bw = bitmapWords(rows);
	let body = HEADER + (DIRENT + TRAILER) * colTypes.length;
	for (let c = 0; c < colTypes.length; c++) {
		const w = bytesWidth(colTypes[c]);
		body +=
			w !== null
				? bw * 8 + pad8(rows * w)
				: colTypes[c] === "#text"
					? bw * 8 + (rows + 1) * 8 + pad8(textBytes[c])
					: bw * 8 + rows * 8;
	}
	return body;
}

export function utf8Len(s) {
	return utf8.encode(s).length;
}

/// Build one image over row-major `rows` (arrays of decoded cells, one per
/// column in layout order).
export function buildImage(colTypes, rows) {
	const ncols = colTypes.length;
	const n = rows.length;
	const bw = bitmapWords(n);

	// Pre-encode text cells: their packed size decides the block layout.
	const textCells = colTypes.map((t, c) =>
		t === "#text"
			? rows.map((r) => (r[c] === null ? null : utf8.encode(r[c])))
			: null,
	);
	const textTotal = textCells.map((cells) =>
		cells === null
			? 0
			: cells.reduce((a, b) => a + (b === null ? 0 : b.length), 0),
	);

	const bodyLen = imageBytes(colTypes, n, textTotal);
	const buf = new Uint8Array(bodyLen);
	const view = new DataView(buf.buffer);

	view.setUint32(0, MAGIC, true);
	view.setUint16(4, VERSION, true);
	view.setUint32(8, n, true);
	view.setUint16(12, ncols, true);
	view.setBigUint64(24, BigInt(bodyLen), true);

	const trailerBase = HEADER + DIRENT * ncols;
	let off = HEADER + (DIRENT + TRAILER) * ncols;

	for (let c = 0; c < ncols; c++) {
		const t = colTypes[c];
		const isText = t === "#text";
		const bw2 = bytesWidth(t);
		const blockLen =
			bw2 !== null
				? bw * 8 + pad8(n * bw2)
				: isText
					? bw * 8 + (n + 1) * 8 + pad8(textTotal[c])
					: bw * 8 + n * 8;

		const d = HEADER + DIRENT * c;
		buf[d] = bw2 !== null ? 2 : isText ? 1 : 0;
		buf[d + 1] = isText ? 8 : 0;
		if (bw2 !== null) view.setUint32(d + 4, bw2, true);
		view.setUint32(d + 8, off, true);
		view.setUint32(d + 12, blockLen, true);

		// Block: [ validity bitmap | values ] — and the footer over the same pass.
		let live = 0,
			nulls = 0,
			min = null,
			max = null,
			sumI = 0n,
			sumF = 0;
		const valuesBase = off + bw * 8;

		if (bw2 !== null) {
			// [ bitmap | rows × w raw bytes ] — counts only; null cells stay zeroed
			// (the buffer starts zero-filled), matching what flush writes.
			for (let i = 0; i < n; i++) {
				const v = rows[i][c];
				if (v === null) {
					nulls++;
					continue;
				}
				if (v.length !== bw2)
					throw new Error(
						`column ${c} (#bytes(${bw2})): a cell is ${v.length} bytes`,
					);
				buf.set(v, valuesBase + i * bw2);
				buf[off + (i >> 3)] |= 1 << (i & 7);
				live++;
			}
		} else if (isText) {
			const dataBase = valuesBase + (n + 1) * 8;
			let running = 0;
			for (let i = 0; i < n; i++) {
				view.setBigUint64(valuesBase + i * 8, BigInt(running), true);
				const bytes = textCells[c][i];
				if (bytes === null) {
					nulls++;
					continue;
				}
				buf.set(bytes, dataBase + running);
				running += bytes.length;
				buf[off + (i >> 3)] |= 1 << (i & 7);
				live++;
			}
			view.setBigUint64(valuesBase + n * 8, BigInt(running), true);
			// no zone map and no sum for text, matching what flush writes
		} else {
			for (let i = 0; i < n; i++) {
				const v = rows[i][c];
				if (v === null) {
					nulls++;
					continue;
				}
				buf[off + (i >> 3)] |= 1 << (i & 7);
				live++;
				const cellOff = valuesBase + i * 8;
				switch (t) {
					case "#nat":
						if (v < 0n || v > NAT_MAX)
							throw new Error(
								`column ${c} (#nat): ${v} is out of range [0, 2^64) — narrow it in the producer or use a heap backend`,
							);
						view.setBigUint64(cellOff, v, true);
						sumI += v;
						if (min === null || v < min) min = v;
						if (max === null || v > max) max = v;
						break;
					case "#int":
						if (v < INT_MIN || v > INT_MAX)
							throw new Error(
								`column ${c} (#int): ${v} is out of range [-2^63, 2^63) — narrow it in the producer or use a heap backend`,
							);
						view.setBigUint64(cellOff, BigInt.asUintN(64, v), true);
						sumI += v;
						if (min === null || v < min) min = v;
						if (max === null || v > max) max = v;
						break;
					case "#float":
						view.setFloat64(cellOff, v, true);
						sumF += v;
						// NaN sorts GREATEST, matching Cell.lt and Predicate.compare in the canister.
						// Plain `<`/`>` are false in both directions against NaN, which leaves it out of
						// the footer entirely — and a zone map built from that footer prunes away the
						// rows a `>` predicate matches. min is the smallest non-NaN, or NaN when every
						// value is one. A CSV cannot carry a NaN (the decoder rejects a non-numeric
						// field), so this is for a caller using the encoder directly, and to keep the
						// two folds identical.
						if (Number.isNaN(v)) {
							if (min === null) min = v;
							max = v;
						} else {
							if (min === null || Number.isNaN(min) || v < min) min = v;
							if (max === null || (!Number.isNaN(max) && v > max)) max = v;
						}
						break;
					case "#bool":
						view.setBigUint64(cellOff, v ? 1n : 0n, true);
						sumI += v ? 1n : 0n; // a bool column sums its true count
						if (min === null || (!v && min)) min = v;
						if (max === null || (v && !max)) max = v;
						break;
					default:
						throw new Error(`unsupported column type ${t}`);
				}
			}
		}

		// Trailer: min/max in the column's own cell encoding, sum as 128-bit two's
		// complement (float: the running float sum's IEEE-754 bits in the low word).
		const tr = trailerBase + TRAILER * c;
		view.setBigUint64(tr, BigInt(live), true);
		view.setBigUint64(tr + 8, BigInt(nulls), true);
		if (min !== null && !isText) {
			if (t === "#float") {
				view.setFloat64(tr + 16, min, true);
				view.setFloat64(tr + 24, max, true);
			} else if (t === "#bool") {
				view.setBigUint64(tr + 16, min ? 1n : 0n, true);
				view.setBigUint64(tr + 24, max ? 1n : 0n, true);
			} else {
				view.setBigUint64(tr + 16, BigInt.asUintN(64, min), true);
				view.setBigUint64(tr + 24, BigInt.asUintN(64, max), true);
			}
		}
		if (t === "#float") view.setFloat64(tr + 32, sumF, true);
		else {
			const u = BigInt.asUintN(128, sumI);
			view.setBigUint64(tr + 32, u % U64, true);
			view.setBigUint64(tr + 40, u / U64, true);
		}

		off += blockLen;
	}
	return buf;
}
