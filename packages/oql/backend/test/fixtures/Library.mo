/// Heterogeneous-storage replica fixture: deliberately uses one of each
/// of Motoko's common collection shapes as the underlying source for an
/// OQL entity:
///
///   • `authors`   : `[Author]`                            (immutable array)
///   • `articles`  : `List.List<Article>`                  (mutable list)
///   • `tags`      : `Set.Set<Text>`                       (sorted set)
///   • `archive`   : `[var Article]`                       (mutable array —
///                                                          snapshot of
///                                                          `articles` via
///                                                          `VarArray.tabulate`)
///   • `metrics`   : `Map.Map<Int, Map.Map<Nat, Measurement>>`
///                                                         (two-level nested
///                                                          map — outer Int
///                                                          buckets, inner
///                                                          Nat sensor ids)
///
/// Records nest other records (`Address`, `Reactions`) and contain
/// collection-typed fields (`tags : [Text]`, `coAuthorIds : [Nat]`). The
/// nested-map entity flattens both levels at iteration time, promoting
/// the outer and inner keys to payload fields so they're queryable. The
/// `extract` closures handle all this flattening — OQL itself has no
/// vocabulary for nested or collection-typed fields; that's pushed to
/// the developer, exactly as the design intended.

import Int      "mo:core/Int";
import Iter     "mo:core/Iter";
import List     "mo:core/List";
import Map      "mo:core/Map";
import Nat      "mo:core/Nat";
import Set      "mo:core/Set";
import Text     "mo:core/Text";
import VarArray "mo:core/VarArray";
import OQL      "../../src";
import Expose   "../../src/Expose";

actor class Library() = self {

  // ── Nested types ─────────────────────────────────────────────────────

  type Address = {
    city       : Text;
    country    : Text;
    postalCode : Text;
  };

  type Reactions = {
    likes    : Nat;
    shares   : Nat;
    comments : Nat;
  };

  type Status = { #draft; #published; #archived };

  // ── Entity types ─────────────────────────────────────────────────────

  type Author = {
    id      : Nat;
    name    : Text;
    address : Address;
    tags    : [Text];        // genres the author writes in
  };

  type Article = {
    id          : Nat;
    authorId    : Nat;
    title       : Text;
    body        : Text;
    status      : Status;
    reactions   : Reactions;
    coAuthorIds : [Nat];     // co-authors as a list
  };

  /// Inner value of the nested `metrics` map. `bucket` and `sensor` are
  /// the two key dimensions; they're stored separately as map keys, not
  /// duplicated inside `Measurement`.
  type Measurement = {
    metric : Text;   // "temp" / "humidity" / "pressure"
    value  : Nat;
    okay   : Bool;   // true if the reading passed sensor self-check
  };

  /// The flattened row the `measurement` entity exposes: the two map-key
  /// dimensions (`bucket`, `sensor`) promoted alongside the `Measurement`
  /// fields. A flat record of primitives, so OQL auto-derives its schema.
  type MeasurementRow = {
    bucket : Int;
    sensor : Nat;
    metric : Text;
    value  : Nat;
    okay   : Bool;
  };

  // ── Storage (four different shapes) ──────────────────────────────────

  // Immutable seed array: read-only catalog.
  let authors : [Author] = [
    {
      id = 1; name = "Ada";
      address = { city = "London"; country = "UK"; postalCode = "EC1A" };
      tags = ["math", "compsci", "engineering"];
    },
    {
      id = 2; name = "Borges";
      address = { city = "Buenos Aires"; country = "AR"; postalCode = "C1000" };
      tags = ["fiction", "philosophy"];
    },
    {
      id = 3; name = "Curie";
      address = { city = "Paris"; country = "FR"; postalCode = "75005" };
      tags = ["physics", "chemistry"];
    },
    {
      id = 4; name = "Dijkstra";
      address = { city = "Eindhoven"; country = "NL"; postalCode = "5612" };
      tags = ["compsci", "math", "philosophy", "engineering"];
    },
  ];

  // Mutable list: things you keep appending to.
  let articles : List.List<Article> = List.empty();

  // Sorted set: cross-cutting tag dictionary, deduplicated naturally.
  let tags : Set.Set<Text> = Set.empty();

  // Mutable array snapshot of `articles`. Built once in the seed block
  // via `VarArray.tabulate`; demonstrates that OQL treats `[var T]` the
  // same as any other iterable source.
  var archive : [var Article] = [var];

  // Two-level nested map: outer key is a signed time bucket (`Int`,
  // negative = past, 0 = now, positive = scheduled future), inner key
  // is the sensor id (`Nat`). The OQL `measurement` entity has to walk
  // BOTH levels at read time to materialise rows.
  let metrics : Map.Map<Int, Map.Map<Nat, Measurement>> = Map.empty();

  // ── Helpers needed by the seed block (declared above to satisfy
  //    Motoko's no-forward-references-from-do-block rule) ──────────────

  /// Upsert a `Measurement` at `metrics[bucket][sensor]`, creating the
  /// inner map lazily on first write to a bucket.
  func seedReading(bucket : Int, sensor : Nat, m : Measurement) {
    let inner : Map.Map<Nat, Measurement> = switch (metrics.get(bucket)) {
      case (?existing) { existing };
      case null {
        let fresh : Map.Map<Nat, Measurement> = Map.empty();
        metrics.add(bucket, fresh);
        fresh
      };
    };
    inner.add(sensor, m);
  };

  // ── Seed ─────────────────────────────────────────────────────────────

  do {
    articles.add({
      id = 1; authorId = 1; title = "Note G"; body = "the analytical engine";
      status = #published;
      reactions = { likes = 240; shares = 32; comments = 18 };
      coAuthorIds = [];
    });
    articles.add({
      id = 2; authorId = 1; title = "On Bernoulli"; body = "computing Bn via a recurrence";
      status = #draft;
      reactions = { likes = 0; shares = 0; comments = 0 };
      coAuthorIds = [];
    });
    articles.add({
      id = 3; authorId = 2; title = "Garden of Forking Paths"; body = "a labyrinth that is the labyrinth";
      status = #published;
      reactions = { likes = 1800; shares = 410; comments = 220 };
      coAuthorIds = [];
    });
    articles.add({
      id = 4; authorId = 3; title = "Radioactivity"; body = "uranium emits invisible rays";
      status = #published;
      reactions = { likes = 95; shares = 12; comments = 4 };
      coAuthorIds = [];
    });
    articles.add({
      id = 5; authorId = 4; title = "Go-to considered harmful"; body = "a letter to the editor";
      status = #published;
      reactions = { likes = 3200; shares = 780; comments = 540 };
      coAuthorIds = [1];   // Ada credited
    });
    articles.add({
      id = 6; authorId = 4; title = "EWD-1300"; body = "drafts of drafts";
      status = #archived;
      reactions = { likes = 12; shares = 0; comments = 1 };
      coAuthorIds = [];
    });

    for (a in authors.values()) {
      for (t in a.tags.values()) { tags.add(t) };
    };

    // Snapshot the freshly-seeded list into a mutable array. Done once
    // at init; tests don't mutate articles, so we don't need to rebuild.
    let snap = articles.toArray();
    archive := VarArray.tabulate<Article>(snap.size(), func (i) = snap[i]);

    // Seed three time buckets, each holding a few sensor readings.
    seedReading(-1,  1, { metric = "temp";     value = 21; okay = true  });
    seedReading(-1,  2, { metric = "humidity"; value = 47; okay = true  });
    seedReading(-1,  3, { metric = "pressure"; value = 1013; okay = false });
    seedReading( 0,  1, { metric = "temp";     value = 22; okay = true  });
    seedReading( 0,  2, { metric = "humidity"; value = 49; okay = true  });
    seedReading( 0,  3, { metric = "pressure"; value = 1015; okay = true });
    seedReading( 0,  4, { metric = "wind";     value = 12; okay = true  });
    seedReading( 1,  1, { metric = "temp";     value = 24; okay = false });
    seedReading( 1,  2, { metric = "humidity"; value = 51; okay = true  });
  };

  /// Flatten the two-level map into a stream of `(bucket, sensor, m)`
  /// triples — the row type the OQL `measurement` entity expects.
  /// Eager rather than lazy: the dataset is tiny and the implementation
  /// stays one screen long. A lazy `Iter.flatMap`-style streamer would
  /// look the same to OQL.
  func flattenMetrics() : Iter.Iter<MeasurementRow> {
    let acc = List.empty<MeasurementRow>();
    for ((bucket, inner) in metrics.entries()) {
      for ((sensor, m) in inner.entries()) {
        acc.add({ bucket; sensor; metric = m.metric; value = m.value; okay = m.okay });
      };
    };
    acc.values()
  };

  // ── Extract helpers ──────────────────────────────────────────────────

  /// Render `Status` as the flat text we want in query results.
  func statusText(s : Status) : Text = switch s {
    case (#draft)     { "draft" };
    case (#published) { "published" };
    case (#archived)  { "archived" };
  };

  /// Word count derived from body text. Demonstrates "computed" fields.
  func wordCount(t : Text) : Nat {
    var n = 0;
    var inWord = false;
    for (c in t.chars()) {
      if (c == ' ') { inWord := false }
      else if (not inWord) { inWord := true; n += 1 };
    };
    n
  };

  // ── OQL schema overlay ───────────────────────────────────────────────

  include Expose({
    entities = [

      // 1. Backed by `[Author]`. Flattens `address.city`/`country`,
      //    summarises `tags` as both a count and a joined string.
      authors.toEntityManual<Author>("author", "Author", "id")
        .payload("id",         func a = a.id)
        .payload("name",       func a = a.name)
        // Nested record → flat columns, auto-derived from Address's fields
        .flatten(func a = a.address)
        // Collection → scalar derivations
        .payload("tagCount",   func a = a.tags.size())
        .payload("tagSummary", func a = Text.join(a.tags.values(), ","))
        .build(),

      // 2. Backed by `List.List<Article>`. Flattens `status` from a
      //    variant, `reactions.*` from a nested record, `coAuthorIds`
      //    size from a collection.
      articles.toEntityManual<Article>("article", "Article", "id")
        .payload("id",            func a = a.id)
        .payload("authorId",      func a = a.authorId)
        .edge   ("authorId",      "author")
        .payload("title",         func a = a.title)
        // Variant → text, with its arms declared so clients filter exactly
        .payload("status",        func a = statusText(a.status))
        .domain ("status",        [#text("draft"), #text("published"), #text("archived")])
        // Nested record → flat columns, auto-derived from Reactions's fields
        .flatten(func a = a.reactions)
        // Derived
        .payload("wordCount",     func a = wordCount(a.body))
        .payload("coAuthorCount", func a = a.coAuthorIds.size())
        .build(),

      // 3. Backed by `Set.Set<Text>`. The element type is just `Text`,
      //    no record at all — the "id" and the only "field" coincide.
      tags.toEntityManual<Text>("tag", "Text", "name")
        .payload("name", func t = t)
        .build(),

      // 4. Backed by `[var Article]`. Same row shape as `article` but
      //    drawn from a mutable-array snapshot. Exists to confirm OQL
      //    treats `[var T]` identically to any other `Iter.Iter<T>`.
      archive.toEntityManual<Article>("archived", "Article", "id")
        .payload("id",     func a = a.id)
        .payload("title",  func a = a.title)
        .payload("status", func a = statusText(a.status))
        .build(),

      // 5. Backed by `Map<Int, Map<Nat, Measurement>>`. The custom
      //    `flattenMetrics()` flatten promotes both map keys (`bucket`,
      //    `sensor`) alongside the `Measurement` fields into a flat
      //    `MeasurementRow` record — so the schema auto-derives via
      //    `Entity.new`, no per-field `.payload` needed even though the
      //    row source is a custom flatten rather than `metrics.values()`.
      OQL.Entity.new<MeasurementRow>(
        "measurement",
        func () = flattenMetrics(),
        "MeasurementRow",
        "sensor",  // primary key is composite in reality; we pick one
      )
        .build(),

    ];
  });

};
