# caffeineai-data-viewer
Data viewer mixin for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill-mops&utm_medium=referral).

Pairs with moc's `--generate-view-queries` flag to auto-expose a controller-only `__<var>` query for every supported stable variable (`Map`, `Set`, `Array`, `VarArray`, `List`, `Stack`, `Queue`). Intended for admin dashboards and debug viewers — **not** as a substitute for user-facing list/feed endpoints.

## Install

```
mops add caffeineai-data-viewer
```

Then in your actor:

```motoko
import MixinViews "mo:caffeineai-data-viewer/MixinViews";

actor {
  include MixinViews();
  // ... your stable variables ...
};
```

Requires `--generate-view-queries` in your `[moc] args`.

## Documentation

See [github.com/caffeinelabs/skills](https://github.com/caffeinelabs/skills) for integration guides.

## License

Apache-2.0
