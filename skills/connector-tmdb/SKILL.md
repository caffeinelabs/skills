---
name: connector-tmdb
description: >-
  MANDATORY recipe for every Caffeine build that reads movie, TV or people data
  from a canister. The supported path is the `tmdb-client` mops package (The
  Movie Database Web API v3) over outbound HTTPS, authenticated with a v3 API
  key or a v4 read-access token. Hand-rolling `ic.http_request` calls to
  `api.themoviedb.org` is a FORBIDDEN anti-pattern — it bypasses the
  non-replicated-outcall safeguard, the generated JSON decoding of ~720 response
  models, and the credential handling. Load this skill whenever the user, spec,
  or any prior task mentions movies, films, TV shows, series, episodes, seasons,
  actors, directors, cast, crew, genres, "now playing", upcoming, popular,
  top-rated, trending, discover, recommendations, similar titles, posters,
  backdrops, ratings, watchlists, favorites, TMDb or "The Movie Database" — and
  BEFORE writing any code that touches a movie-data endpoint.
version: 0.3.0
caffeineai-subscription: [none]
compatibility:
  mops:
    tmdb-client: "~0.4.0"
---

# Movie and TV data with `tmdb-client`

Motoko bindings for [The Movie Database API](https://developer.themoviedb.org/),
generated from TMDb's OpenAPI spec. **124 operations in one module**
(`Apis/DefaultApi`) — the spec carries no tags, so there is nothing to split on
and no nested facade.

**Read this before planning the app.** Catalog reads (search, details,
trending, discover, now-playing) need only the token. Favorites, watchlists,
ratings and lists also need a **user session**, which takes a browser redirect
to TMDb (§6). One read, `movieRecommendations`, returns an untyped value you
walk by hand (§6); for a "more like this" row, prefer `tvSeriesRecommendations`,
which is typed.

# Backend

## 1. Add the dependency

```bash
mops add tmdb-client@0.4.0
```

## 2. The credential

**Use the v4 read-access token and `?#bearer`. That is the only credential
this client supports.**

```mo:tmdb-client
auth = ?#bearer "eyJhbGciOi…"   // v4 read-access token, themoviedb.org/settings/api
```

TMDb also issues a v3 API key (32 hex chars) that normally travels as an
`?api_key=…` query parameter. **This client cannot send it.** The spec declares
exactly one security scheme — `apiKey` in a *header* named `Authorization`,
tagged `x-bearer-format: bearer` — so no generated operation ever appends
`api_key` to the URL (`api_key` occurs zero times in `DefaultApi.mo`).

And do **not** reach for the `?#apiKey` variant that `Config.Auth` happens to
offer: it emits `Authorization: <key>` *without* the `Bearer ` prefix, which
TMDb rejects with 401. It is a generic generator variant, wrong for this API.
`?#bearer` is the one wired correctly.

The v4 token is minted off-chain and **never expires** — no OAuth flow, no
refresh to implement for the read surface.

### Where the credential lives

The actor in §3 takes the token as a parameter, which keeps the example
self-contained. For a real app you do **not** want the frontend holding the
credential — put it in actor state, set by an authorized update call:

- **Declare the field type-only.** Caffeine actors get their stable state from
  the migration chain, so `var tmdbToken : Text;` — *without* an initializer.
  Writing `var tmdbToken : Text = "";` is `M0250` the moment it is compiled in
  a real project.
- Gate the setter with `MixinAuthorization` and read the field only inside the
  actor when building `Config`.
- Never return it from a query method, never log it, never include it in an
  error surfaced to the caller.

`connector-googlemail` is the worked example of that shape — a `gmailConfig`
record of type-only `var` fields, an authorization mixin over the setter, and
the migration head that supplies the initial values. Follow it if the app needs
admin-managed credentials; the parameter form above is fine for a prototype or
when the caller is already trusted.

## 3. Canonical layout

The actor below is the whole backend for a movie-search feature. It maps TMDb's
wide optional-everything response into a narrow record the frontend can consume
without null-checking fourteen fields.

```motoko filepath=src/backend/main.mo
import Tmdb "mo:tmdb-client/Apis/DefaultApi";
import { defaultConfig; type Config } "mo:tmdb-client/Config";
import Array "mo:core/Array";

actor {

  /// Narrow, frontend-friendly shape. TMDb marks almost every field
  /// optional, so collapse the optionals here once instead of in the UI.
  public type Movie = {
    id : Int;
    title : Text;
    overview : Text;
    releaseDate : Text;
    posterUrl : Text;
    voteAverage : Float;
  };

  /// The v4 read-access token is passed in rather than stored here — see
  /// "Where the credential lives" below for the admin-set variant.
  func config(token : Text) : Config = {
    defaultConfig with
    auth = ?#bearer token;
    // search and discover payloads run large; the default cap is too
    // small for a 20-result page with overviews.
    max_response_bytes = ?300_000;
  };

  /// Poster paths come back relative (`/abc.jpg`); prepend an image base.
  /// w500 is the usual card size. An empty path yields an empty string so
  /// the frontend can fall back to a placeholder.
  func posterUrl(path : ?Text) : Text {
    switch (path) {
      case (?p) "https://image.tmdb.org/t/p/w500" # p;
      case null "";
    };
  };

  /// One mapper for every list endpoint. The parameter type is written
  /// STRUCTURALLY rather than naming a generated model, because each
  /// endpoint has its own `…ResultsInner` type with the same fields —
  /// `SearchMovie200ResponseResultsInner`,
  /// `MovieNowPlayingList200ResponseResultsInner`, and so on. One structural
  /// signature accepts all of them.
  func toMovie(
    m : {
      id : ?Int;
      title : ?Text;
      overview : ?Text;
      release_date : ?Text;
      poster_path : ?Text;
      vote_average : ?Float;
    }
  ) : Movie = {
    id = m.id ?? 0;
    title = m.title ?? "";
    overview = m.overview ?? "";
    releaseDate = m.release_date ?? "";
    posterUrl = posterUrl(m.poster_path);
    voteAverage = m.vote_average ?? 0.0;
  };

  // `query` is a reserved word in Motoko — hence `term` here, and `query_`
  // in the generated signature.
  public func searchMovies(token : Text, term : Text, page : Int) : async [Movie] {
    // searchMovie(config, query_, includeAdult, language,
    //             primaryReleaseYear, page, region_, year)
    // Text and Bool parameters are positional and NOT optional: pass ""
    // and false to omit them. Only `page` is 1-indexed.
    let response = await* Tmdb.searchMovie(
      config(token),
      term,
      false,
      "en-US",
      "",
      page,
      "",
      "",
    );
    let results = switch (response.results) {
      case (?r) r;
      case null [];
    };
    Array.map(results, toMovie);
  };

  /// Full detail for one title. `appendToResponse` embeds sub-resources in
  /// the SAME outcall — "credits,images,videos" costs one call, not four.
  public func movieOverview(token : Text, movieId : Int) : async Text {
    let movie = await* Tmdb.movieDetails(config(token), movieId, "", "en-US");
    movie.overview ?? "";
  };

  /// "In cinemas now" feed, for a landing page.
  public func nowPlaying(token : Text) : async [Movie] {
    let response = await* Tmdb.movieNowPlayingList(config(token), "en-US", 1, "US");
    let results = switch (response.results) {
      case (?r) r;
      case null [];
    };
    Array.map(results, toMovie);
  };
}
```

## 4. The read surface

All 124 operations live in `mo:tmdb-client/Apis/DefaultApi` as free functions
taking `Config` first. The generated names are camelCase of TMDb's hyphenated
operationIds (`movie-now-playing-list` → `movieNowPlayingList`). The useful
groups:

| group | representative operations | use for |
|---|---|---|
| search | `searchMovie`, `searchTv`, `searchPerson`, `searchMulti` | a search box. `searchMulti` returns movies + TV + people in one call |
| movie detail | `movieDetails`, `movieCredits`, `movieImages`, `movieVideos`, `movieSimilar`, `movieReleaseDates` | a title page. `movieRecommendations` is untyped — see §6 |
| TV detail | `tvSeriesDetails`, `tvSeasonDetails`, `tvEpisodeDetails`, `tvSeriesCredits`, `tvSeriesRecommendations` | a series page, drilling season → episode |
| people | `personDetails`, `personMovieCredits`, `personTvCredits`, `personImages` | a cast/crew page |
| feeds | `movieNowPlayingList`, `movieUpcomingList`, `moviePopularList`, `movieTopRatedList`, `tvSeriesPopularList` | landing pages, carousels |
| trending | `trendingMovies`, `trendingTv`, `trendingPeople`, `trendingAll` | a "what's hot" row. Takes a `timeWindow` enum (`#day` / `#week`) as a **path** parameter, so it is bare, not `?T` |
| recommendations | `tvSeriesRecommendations` (typed); `movieRecommendations` (untyped, §6) | "more like this" rows |
| discover | `discoverMovie`, `discoverTv` | filtered browse: genre, year, rating, language, sort |
| account reads | `accountGetFavorites`, `accountWatchlistMovies`, `accountWatchlistTv`, `accountRatedMovies`, `accountRatedTv`, `accountLists`, `accountDetails` | reading a user's own lists. They need a `sessionId` — see §6. There is no `accountGetWatchlist`; movies and TV are separate operations |
| configuration | `configurationDetails`, `configurationLanguages`, `configurationCountries` | image base URLs, language codes. Fetch once and cache — it changes rarely |

Everything in a response is optional (`?T`), because TMDb omits fields rather
than nulling them. Collapse the optionals at the actor boundary as §3 does.

Sort-by parameters are **typed variants**, not strings — pick from the generated
`*SortByParameter` modules (e.g. `#created_at_desc`). Passing an arbitrary string
will not type-check.

## 5. Calls are non-replicated by default

`defaultConfig` ships `is_replicated = ?false`, so one node performs each
outcall and the response is not put to consensus. That is right in both
directions here, and it is a **change from 0.1.1**, which shipped `null`
(= replicated):

- **Reads** — catalog responses are stable, so replication buys nothing and
  costs roughly 13× the cycles.
- **Writes** — `listCreate` and the three `authenticationCreateSession*`
  operations are **not idempotent**. Replicated, each call would create ~13
  lists or ~13 sessions, and the credential would leave every replica.

> **Correction to earlier guidance.** The in-package `SKILL.md` that shipped
> inside `tmdb-client@0.1.1` said: *"for mutations leave `is_replicated = null`
> — consensus replication guards against single-node tampering."* That is
> backwards. Consensus does not de-duplicate an outcall, it multiplies it; for a
> non-idempotent write, replication is the bug rather than the safeguard. If you
> find that pattern in existing code, `?false` is the fix.

Override per call site with record update when a specific endpoint wants the
other mode — but for TMDb there is no endpoint that does.

## 6. Sessions, writes, and the one untyped read

### Getting a user session

Every account read and write takes a `sessionId`, the user's TMDb session. The
v4 read-access token alone can't act for a user. Get a session in three steps:

1. Call `authenticationCreateRequestToken(config)` and store its
   `request_token` in actor state, keyed by the caller. Don't count on reading
   it back from the redirect: TMDb's docs don't say what they append to
   `redirect_to`.
2. Send the user's browser to
   `https://www.themoviedb.org/authenticate/<request_token>?redirect_to=<your app URL>`,
   with the app URL percent-encoded, to approve it. TMDb sends the browser back
   to `redirect_to` once the user approves. The token expires after 60 minutes.
3. Call `authenticationCreateSession(config, { request_token })` and keep the
   returned `session_id`, per user, in actor state. Treat it like a credential.

Every response field is optional, so unwrap before you reuse one. For example,
with `import Error "mo:core/Error"`,
`let ?request_token = tokenResponse.request_token else throw Error.reject("no request token")`,
and the same for `session_id` and `guest_session_id`.

To end a session, call `authenticationDeleteSession(config, { session_id })`.
Don't use `authenticationCreateSessionFromLogin`: it would route the user's TMDb
password through your canister.

For ratings only, `authenticationCreateGuestSession(config)` returns a
`guest_session_id` without any redirect. Pass it as `guestSessionId` to the
rating operations, with `sessionId = ""`. TMDb deletes a guest session if it
isn't used within 60 minutes of being issued. A guest's ratings can't be read
back: the `guest-session-rated-*` operations are pruned (§8).

The account operations also take an `accountId`. `accountDetails` returns it as
`id : ?Int`, but TMDb's docs mark `accountId` required on `accountDetails` too
and don't say how to get one first. This client hasn't been tested against the
live API, so raise that with the user before you build account features on a
guessed ID.

### Writes take typed request models

The 12 operations with a request body each take a record built from the
spec's request examples:

| operation | request |
|---|---|
| `accountAddFavorite` | `{ media_type = #movie; media_id = 550; favorite = true }` |
| `accountAddToWatchlist` | `{ media_type = #tv; media_id = 1399; watchlist = true }` |
| `movieAddRating`, `tvSeriesAddRating`, `tvEpisodeAddRating` | `{ value = 8.5 }` |
| `listCreate` | `{ name = "Watch later"; description = ?"Films to catch"; language = ?"en" }` |
| `listAddMovie`, `listRemoveMovie` | `{ media_id = 18 }` |
| `authenticationCreateSession` | `{ request_token }`, with `request_token : Text` |
| `authenticationDeleteSession` | `{ session_id }`, with `session_id : Text` |

- `media_type` is the `MediaType` variant, `#movie` or `#tv`.
- A rating `value` runs from 0.5 to 10 in steps of 0.5.
- The models live in `mo:tmdb-client/Models/<Name>` if you need to name them,
  for example `FavoriteRequest` or `ListCreateRequest`.
  TMDb's docs don't say whether `description` and `language` may be left out,
  so set both. `ListCreateRequest.init({ name })` leaves them `null`, which
  drops them from the JSON and is untested.
- Each rating operation takes both `guestSessionId` and `sessionId` as `Text`;
  pass `""` for the one you don't use.

### `movieRecommendations` returns an untyped `Candid.Candid`

TMDb declares its 200 body as `{"type": "object", "properties": {}}`, a
free-form object, so there is no model to decode into. The call returns the
parsed JSON as `Candid.Candid` from `serde-core`: an object is
`#Record([(key, value)])`, an array is `#Array([...])`, and leaves are `#Text`,
`#Nat`, `#Int`, `#Float`, `#Bool`, or `#Null`. Switch on the result and look up
`"results"`, then read each entry's fields such as `"id"` and `"title"` the same
way. It is the only operation in the package with that shape;
`tvSeriesRecommendations` is typed normally.

- **A number's tag follows how TMDb wrote it, not the field.** A whole number
  is `#Nat` (or `#Int` if negative), and only a number with a decimal point or
  exponent is `#Float`, so `vote_average` can arrive as `#Nat(7)` or
  `#Float(7.4)`. Handle both.
- **You don't need to name the type to switch on it.** To name it, for example
  in a helper's signature, run `mops add serde-core@0.2.1` and
  `import { Candid } "mo:serde-core"`.

## 7. Response sizes and cycles

- `max_response_bytes` defaults to the platform maximum, which is both slower
  and more expensive than needed. Set it to what the endpoint actually returns:
  **~300 KB** for a 20-result search or discover page with overviews, ~50 KB for
  a single `movieDetails` without `appendToResponse`, more if you append
  sub-resources.
- Prefer `appendToResponse` over several outcalls. `"credits,images,videos"` on
  `movieDetails` is one call and one cycle charge instead of four.
- `configurationDetails` is effectively static — fetch it once, keep it in a
  `var`, and do not call it per request.

## 8. Things that will bite you

- **Empty string and zero mean "omit".** Text and Bool query parameters are
  positional and not `?T`: pass `""` / `false` to leave one out. Only the enum
  query parameters are `?T`.
- **IDs are `Int`, not `Text`.** `movieId`, `tvSeriesId`, `personId`,
  `accountId` are all integers in the generated signatures. Coerce before
  calling.
- **`page` is 1-indexed**, 20 items per page, and **page > 500 returns 422** —
  clamp before calling rather than surfacing TMDb's error.
- **Image paths are relative.** `poster_path` / `backdrop_path` look like
  `/abc123.jpg`; prepend `https://image.tmdb.org/t/p/w500` (or another size from
  `configurationDetails`). A bare path renders nothing.
- **Rate limit ~50 requests/second per IP**, and TMDb sends no `Retry-After`. On
  429, back off at least a second. Never retry inside a tight loop in a canister.
- **`searchMulti` results are heterogeneous** — each entry carries a
  `media_type` of `movie`, `tv` or `person`, and the fields present differ
  accordingly (`title` for movies, `name` for TV and people). Branch on
  `media_type` before reading.
- **28 of TMDb's 152 operations are pruned out — but check before assuming.**
  `focusApis` keeps every operationId starting with `tv`, `movie`, `account`,
  `person`, `search`, `list`, `lists`, `authentication`, `configuration`,
  `trending` or `discover`. That means the **movie- and tv-scoped** variants of
  a resource are *in* while the standalone endpoint for the same resource is
  *out*. `movieWatchProviders`, `movieKeywords`, `movieReviews`,
  `movieTranslations`, `movieChanges`, `searchCompany`, `searchCollection` and
  `authenticationCreateGuestSession` are all **present**; it is
  `watchProvidersMovieList`, `keywordDetails`, `reviewDetails`, `translations`,
  `changesMovieList`, `companyDetails`, `collectionDetails` and
  `guestSessionRatedMovies` that are not. The full dropped set, measured against
  the spec:

  ```
  alternative-names-copy      certification-movie-list    certifications-tv-list
  changes-movie-list          changes-people-list         changes-tv-list
  collection-details          collection-images           collection-translations
  company-alternative-names   company-details             company-images
  credit-details              details-copy                find-by-id
  genre-movie-list            genre-tv-list               guest-session-rated-movies
  guest-session-rated-tv      guest-session-rated-tv-episodes
  keyword-details             keyword-movies              network-details
  review-details              translations                watch-provider-tv-list
  watch-providers-available-regions                       watch-providers-movie-list
  ```

  If a feature needs one of those, add its prefix to `focusApis` and regenerate
  and republish the package. Search `DefaultApi.mo` for the camelCase name
  before concluding an operation is missing.

## Related

- `connector-weatherapi` — the same generated-client shape at a much smaller
  scale (9 operations), useful as a second example of the `Config` pattern.
