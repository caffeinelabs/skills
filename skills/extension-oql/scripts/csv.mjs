// Minimal streaming CSV parser — RFC 4180 quoting (double-quoted fields, "" as
// an escaped quote, newlines allowed inside quotes), LF or CRLF records.
//
// Yields one record per row as an array of { text, quoted }. `quoted` is kept
// because it is meaningful for a text column: an unquoted empty field is a null
// cell, a quoted empty field ("") is the empty string.
// Decoded text, chunk by chunk. A chunk boundary can fall INSIDE a multi-byte UTF-8
// sequence, and decoding each chunk on its own turns those bytes into replacement
// characters — silently corrupting any non-ASCII value that straddles a read. One
// decoder in streaming mode holds the partial sequence until the next chunk completes
// it; the final flush surfaces one that never does. Kept separate so the record loop
// below yields its rows directly: forwarding them through a second generator costs
// ~10% of parse throughput.
async function* decoded(stream) {
	const decoder = new TextDecoder("utf-8");
	for await (const chunk of stream) {
		yield typeof chunk === "string"
			? chunk
			: decoder.decode(chunk, { stream: true });
	}
	const tail = decoder.decode();
	if (tail !== "") yield tail;
}

export async function* csvRecords(stream) {
	let field = "";
	let quoted = false; // this field was quoted
	let inQuotes = false;
	let sawQuote = false; // previous char inside quotes was a '"'
	let row = [];
	let prevCR = false;

	const endField = () => {
		row.push({ text: field, quoted });
		field = "";
		quoted = false;
	};

	for await (const s of decoded(stream)) {
		for (let i = 0; i < s.length; i++) {
			const c = s[i];
			if (inQuotes) {
				if (sawQuote) {
					sawQuote = false;
					if (c === '"') {
						field += '"';
						continue;
					} // escaped quote
					inQuotes = false; // closing quote, reprocess c
				} else if (c === '"') {
					sawQuote = true;
					continue;
				} else {
					field += c;
					continue;
				}
			}
			if (c === '"' && field === "" && !quoted) {
				inQuotes = true;
				quoted = true;
				sawQuote = false;
				continue;
			}
			if (c === ",") {
				endField();
				prevCR = false;
				continue;
			}
			if (c === "\n") {
				endField();
				if (row.length > 1 || row[0].text !== "" || row[0].quoted) yield row; // skip blank lines
				row = [];
				prevCR = false;
				continue;
			}
			if (c === "\r") {
				prevCR = true;
				continue;
			}
			if (prevCR) {
				field += "\r";
				prevCR = false;
			} // lone CR inside a field
			field += c;
		}
	}

	if (field !== "" || quoted || row.length > 0) {
		endField();
		if (row.length > 1 || row[0].text !== "" || row[0].quoted) yield row;
	}
}
