// Producer side of src/columnar/HashSegment.mo: builds a #hash index SEGMENT,
// byte-identical to the Motoko reference `HashSegment.build` for the same column
// values over the same row range. The conformance test diffs the two.
//
// A segment covers the row range [firstRow, firstRow + rows) of one column; its
// postings hold ABSOLUTE store positions (firstRow + local index), so the reader
// unions a column's segments with no remapping. A producer builds one segment at
// a time, capping its peak memory at one segment's worth of any table size.
//
// A cell value is null, or by column type: '#nat'/'#int' a BigInt, '#bool' a
// boolean, '#text' a string. '#float' is not supported (its hash needs bits the
// read path can't derive without a scratch Region — deferred in the canister too).

const HEADER = 64,
	BUCKET = 24;
const MAGIC = 0x4f514948,
	VERSION = 1; // "OQIH"
const MASK64 = (1n << 64n) - 1n;
const utf8 = new TextEncoder();

const pad8 = (n) => Math.ceil(n / 8) * 8;

// splitmix64's finaliser — bit-identical to src/columnar/Hash.mo (HashSegment).
function mix(x) {
	x &= MASK64;
	x = ((x ^ (x >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK64;
	x = ((x ^ (x >> 27n)) * 0x94d049bb133111ebn) & MASK64;
	return (x ^ (x >> 31n)) & MASK64;
}
function hashText(bytes) {
	let h = mix(BigInt(bytes.length));
	for (let i = 0; i < bytes.length; i += 8) {
		let w = 0n;
		for (let j = 0; j < 8 && i + j < bytes.length; j++)
			w |= BigInt(bytes[i + j]) << BigInt(8 * j);
		h = mix(h ^ w);
	}
	return h;
}

// The raw 64-bit key word for a fixed cell — the same bits the column store holds.
function cellBits(keyType, v) {
	switch (keyType) {
		case "#nat":
			if (v < 0n || v > MASK64) throw new Error(`#nat key ${v} out of range`);
			return v & MASK64;
		case "#int":
			return BigInt.asUintN(64, v);
		case "#bool":
			return v ? 1n : 0n;
		default:
			throw new Error(`hash segment: unsupported key type ${keyType}`);
	}
}

// Lexicographic byte order, matching Motoko's Blob.compare.
function bytesLess(a, b) {
	const n = Math.min(a.length, b.length);
	for (let i = 0; i < n; i++) {
		if (a[i] !== b[i]) return a[i] < b[i];
	}
	return a.length < b.length;
}

// Build a hash index SEGMENT from a STREAMING row source over the range
// [firstRow, firstRow + rows): `rows` count + `keyAt(r)` returning the cell value
// (or null) for LOCAL index r in [0, rows). The postings it emits are ABSOLUTE
// (firstRow + r). Two passes over the source — pass 1 tallies per-key COUNTS (one
// record per distinct key, never per row), pass 2 scatters each position straight
// into the output buffer. Peak memory is the segment buffer plus the distinct-key
// records; the row set is never materialised. Output is byte-identical to the
// Motoko reference `HashSegment.build` over the same range, so the conformance
// test still guards it.
export function buildHashSegmentStreaming(keyType, firstRow, rows, keyAt) {
	const isText = keyType === "#text";

	// Pass 1: distinct keys + counts (bits/bytes captured once), and the null tally.
	let nullCount = 0;
	const map = new Map(); // mapKey -> { count, bits, bytes? }
	for (let r = 0; r < rows; r++) {
		const v = keyAt(r);
		if (v === null || v === undefined) {
			nullCount++;
			continue;
		}
		let mapKey,
			bits,
			bytes = null;
		if (isText) {
			bytes = utf8.encode(v);
			mapKey = `t:${v}`;
			bits = hashText(bytes);
		} else {
			bits = cellBits(keyType, v);
			mapKey = `b:${bits.toString()}`;
		}
		let e = map.get(mapKey);
		if (!e) {
			e = { count: 0, bits, bytes };
			map.set(mapKey, e);
		}
		e.count++;
	}

	const keys = [...map.values()];
	keys.sort(
		isText
			? (a, b) =>
					bytesLess(a.bytes, b.bytes) ? -1 : bytesLess(b.bytes, a.bytes) ? 1 : 0
			: (a, b) => (a.bits < b.bits ? -1 : a.bits > b.bits ? 1 : 0),
	);
	const distinct = keys.length;

	// Open-address in key-dir order (deterministic, matching the canister).
	let shift = 0,
		nbuckets = 1;
	while (nbuckets < distinct * 2) {
		nbuckets *= 2;
		shift++;
	}
	const occupant = new Int32Array(nbuckets).fill(-1);
	const slotOf = new Array(distinct);
	let maxProbe = 0;
	for (let i = 0; i < distinct; i++) {
		const home = Number(
			(isText ? keys[i].bits : mix(keys[i].bits)) % BigInt(nbuckets),
		);
		let p = 0,
			slot = home;
		while (occupant[slot] !== -1) {
			p++;
			slot = (slot + 1) % nbuckets;
		}
		occupant[slot] = i;
		slotOf[i] = slot;
		if (p + 1 > maxProbe) maxProbe = p + 1;
	}

	// Run starts: the null run occupies [0, nullCount), then keys in key-dir order.
	let start = nullCount;
	for (let i = 0; i < distinct; i++) {
		keys[i]._start = start;
		keys[i]._cur = start;
		start += keys[i].count;
	}

	// Layout.
	const bucketsOff = HEADER;
	const keyDirOff = bucketsOff + nbuckets * BUCKET;
	const postingsOff = pad8(keyDirOff + distinct * 4);
	const keyBytesOff = postingsOff + rows * 8;
	let textTotal = 0;
	if (isText) for (const k of keys) textTotal += k.bytes.length;
	const bodyLen = pad8(keyBytesOff + textTotal);

	const buf = new Uint8Array(bodyLen);
	const view = new DataView(buf.buffer);

	view.setUint32(0, MAGIC, true);
	view.setUint16(4, VERSION, true);
	view.setUint16(6, shift, true);
	view.setUint16(8, maxProbe, true);
	view.setBigUint64(16, BigInt(rows), true);
	view.setBigUint64(24, BigInt(distinct), true);
	view.setBigUint64(32, BigInt(keyDirOff), true);
	view.setBigUint64(40, BigInt(postingsOff), true);
	view.setBigUint64(48, BigInt(keyBytesOff), true);
	view.setUint32(56, 0, true); // nullStart: null run is first
	view.setUint32(60, nullCount, true);

	// Buckets, key dir, key bytes — from key metadata, no positions.
	let byteCursor = 0;
	for (let i = 0; i < distinct; i++) {
		const k = keys[i];
		if (isText) {
			k._textOff = byteCursor;
			buf.set(k.bytes, keyBytesOff + byteCursor);
			byteCursor += k.bytes.length;
		}
		const b = bucketsOff + slotOf[i] * BUCKET;
		view.setBigUint64(b, k.bits, true);
		view.setUint32(b + 8, k._start, true);
		view.setUint32(b + 12, k.count, true);
		view.setUint32(b + 16, isText ? k._textOff : 0, true);
		// A bucket records the key's byte length in 16 bits. Motoko's builder traps on a
		// longer key; setUint16 would silently wrap and the reader would compare the wrong
		// number of bytes, so refuse it here too rather than emit a segment that decodes
		// to a different key.
		if (isText && k.bytes.length > 0xffff)
			throw new Error(
				`hash segment: text key of ${k.bytes.length} bytes exceeds the 65535-byte limit`,
			);
		view.setUint16(b + 20, isText ? k.bytes.length : 0, true);
		view.setUint16(b + 22, 1, true); // flags: occupied
		view.setUint32(keyDirOff + i * 4, slotOf[i], true);
	}

	// Pass 2: scatter ABSOLUTE positions (firstRow + r) into the postings section. r
	// ascends, so each run (and the null run) fills in ascending order — matching a
	// single-pass build.
	let nullCur = 0;
	for (let r = 0; r < rows; r++) {
		const v = keyAt(r);
		const pos = BigInt(firstRow + r);
		if (v === null || v === undefined) {
			view.setBigUint64(postingsOff + nullCur * 8, pos, true);
			nullCur++;
			continue;
		}
		const mapKey = isText ? `t:${v}` : `b:${cellBits(keyType, v).toString()}`;
		const e = map.get(mapKey);
		view.setBigUint64(postingsOff + e._cur * 8, pos, true);
		e._cur++;
	}

	return buf;
}

// Materialised-array convenience: build one segment over `cells` (its values,
// LOCAL index = position within the segment) starting at absolute `firstRow`.
// Used by the CSV tool (one segment's values at a time) and the conformance
// fixture (firstRow defaults to 0).
export function buildHashSegment(keyType, cells, firstRow = 0) {
	return buildHashSegmentStreaming(
		keyType,
		firstRow,
		cells.length,
		(r) => cells[r],
	);
}
