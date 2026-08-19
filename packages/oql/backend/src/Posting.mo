/// A posting list: the refs an index holds for one key, kept sorted by the
/// caller's `cmp` and deduplicated.
///
/// This exists because a general-purpose ordered set is the wrong container for
/// this job. `mo:core`'s `Set` spends five heap objects per posting — including a
/// 31-slot element array allocated whether the posting holds 1 ref or 31 — and
/// boxes every element in an option, to store refs that are 8 bytes each.
///
/// A secondary index is the only part of a columnar table that lives on the heap —
/// the row data sits in a Region — so what a posting costs per ref is what bounds
/// how many rows such a table can carry. `bench/scale/README.md` measures it.
///
/// A posting only ever needs: add, remove, iterate in order, and size. None of
/// that requires a tree, so this is a plain growable array:
///
///   - `[var Ref]`, NOT `[var ?Ref]` — no option box per element. The empty
///     posting holds a zero-length array, and the first `add` supplies the value
///     that fills a freshly grown one, so no default `Ref` is ever needed.
///   - capacity doubles, so no fixed per-posting minimum.
///   - `add` checks the tail first — appending an ascending ref (the columnar
///     backend's case, where refs are increasing row positions) lands with one
///     comparison and shifts nothing; anything else binary-searches for its
///     insertion point.
///   - the live refs occupy a WINDOW `[start, start + count)` of the array, and
///     an insert or remove shifts whichever side is shorter. Removing the first
///     or last ref therefore moves nothing, which is what keeps deleting rows in
///     key order off an O(n^2) path — a low-cardinality column has few postings
///     holding very many refs, and deleting a table in insertion order removes
///     the front of each one every time.
///
/// A remove from the MIDDLE of a large posting is still O(n) in the shorter
/// side, where a tree would be O(log n). That is the deliberate trade: postings
/// are overwhelmingly appended to and iterated, and this representation is
/// several times smaller for both.
///
/// Iteration is in `cmp` order, matching what the ordered set did, so callers
/// relying on posting order being scan order are unaffected.

import Iter     "mo:core/Iter";
import Order    "mo:core/Order";
import VarArray "mo:core/VarArray";

module {

  public type Posting<Ref> = {
    var refs : [var Ref];   // sorted ascending by `cmp`; live window is [start, start + count)
    var start : Nat;
    var count : Nat;
  };

  public func empty<Ref>() : Posting<Ref> = { var refs = [var]; var start = 0; var count = 0 };

  public func size<Ref>(self : Posting<Ref>) : Nat = self.count;

  public func isEmpty<Ref>(self : Posting<Ref>) : Bool = self.count == 0;

  /// `(found, index)`: whether `ref` is present, and its position — or where it
  /// would be inserted.
  func locate<Ref>(self : Posting<Ref>, cmp : (Ref, Ref) -> Order.Order, ref : Ref) : (Bool, Nat) {
    var lo = self.start;
    var hi = self.start + self.count;
    while (lo < hi) {
      let mid = lo + (hi - lo) / 2;
      switch (cmp(self.refs[mid], ref)) {
        case (#less) { lo := mid + 1 };
        case (#greater) { hi := mid };
        case (#equal) { return (true, mid) };
      };
    };
    (false, lo);
  };

  /// Make room for one more ref at either end of the window: slides the window
  /// back to 0 when the array is merely off-centre, and grows only when it is
  /// genuinely full. `filler` seeds a freshly grown array — it is a live ref the
  /// caller already has, which is what lets the element type stay `Ref` rather
  /// than `?Ref` (a generic `Ref` has no default value).
  func reserve<Ref>(self : Posting<Ref>, filler : Ref) {
    let cap = self.refs.size();
    if (self.start + self.count < cap) return;        // room above the window
    // The window is flush against the top. Sliding it down to 0 costs O(count)
    // and recovers exactly `start` slots, so it only pays for itself when
    // `start` is a real fraction of the array; otherwise grow instead.
    //
    // The guard is what keeps this amortised, and it is easy to lose: a rolling
    // workload (append the newest ref, delete the oldest — what the columnar
    // backend generates) frees one slot at the front per insert, so a
    // slide-whenever-there-is-room policy copies the entire posting on EVERY
    // insert and never grows out of it. Requiring a quarter of the array to be
    // reclaimable bounds that to O(1) amortised, and growing in the other case
    // leaves `count` free slots above the window for the inserts that follow.
    if (self.start > 0 and self.start * 4 >= cap) {
      var i = 0;
      while (i < self.count) { self.refs[i] := self.refs[self.start + i]; i += 1 };
      self.start := 0;
      return;
    };
    let next = VarArray.repeat<Ref>(filler, if (cap == 0) 4 else cap * 2);
    var i = 0;
    while (i < self.count) { next[i] := self.refs[self.start + i]; i += 1 };
    self.refs := next;
    self.start := 0;
  };

  /// Add `ref`, keeping the list sorted. Adding one already present is a no-op,
  /// so re-indexing a row stays idempotent (the ordered set deduped too).
  public func add<Ref>(self : Posting<Ref>, cmp : (Ref, Ref) -> Order.Order, ref : Ref) {
    // A ref past the current tail lands with ONE comparison, no search and no
    // shift. This is the dominant write: refs are ascending row positions, so
    // live appends and the index-build walk both extend the tail every time.
    if (self.count > 0 and cmp(self.refs[self.start + self.count - 1], ref) == #less) {
      reserve(self, ref);
      self.refs[self.start + self.count] := ref;
      self.count += 1;
      return;
    };
    let (found, at0) = locate(self, cmp, ref);
    if (found) return;
    let offset = at0 - self.start;          // insertion point within the window
    reserve(self, ref);
    let at = self.start + offset;
    let end = self.start + self.count;
    // Shift the shorter side: an append moves nothing, and so does a prepend
    // when there is slack below the window.
    if (self.start > 0 and offset * 2 < self.count) {
      var i = self.start;
      while (i < at) { self.refs[i - 1] := self.refs[i]; i += 1 };
      self.start -= 1;
      self.refs[at - 1] := ref;
    } else {
      var i = end;
      while (i > at) { self.refs[i] := self.refs[i - 1]; i -= 1 };
      self.refs[at] := ref;
    };
    self.count += 1;
  };

  /// Remove `ref`; returns whether it was there.
  public func remove<Ref>(self : Posting<Ref>, cmp : (Ref, Ref) -> Order.Order, ref : Ref) : Bool {
    let (found, at) = locate(self, cmp, ref);
    if (not found) return false;
    let end = self.start + self.count;
    // Removing either end moves nothing — just retract the window. Otherwise
    // close the gap from whichever side is nearer. A removed `Ref` must not stay
    // reachable through a vacated slot, so the slot the window gives up is
    // overwritten with a ref that is still live.
    if (at == self.start) {
      self.refs[self.start] := self.refs[end - 1];
      self.start += 1;
    } else if (at == end - 1) {
      self.refs[at] := self.refs[self.start];
    } else if (at - self.start < end - 1 - at) {
      var i = at;
      while (i > self.start) { self.refs[i] := self.refs[i - 1]; i -= 1 };
      self.refs[self.start] := self.refs[end - 1];
      self.start += 1;
    } else {
      var i = at;
      while (i + 1 < end) { self.refs[i] := self.refs[i + 1]; i += 1 };
      self.refs[end - 1] := self.refs[self.start];
    };
    self.count -= 1;
    if (self.count == 0) { self.refs := [var]; self.start := 0 };
    true;
  };

  /// The refs in `cmp` order.
  public func values<Ref>(self : Posting<Ref>) : Iter.Iter<Ref> {
    var i = 0;
    {
      next = func() : ?Ref {
        if (i >= self.count) return null;
        let r = self.refs[self.start + i];
        i += 1;
        ?r;
      };
    };
  };

};
