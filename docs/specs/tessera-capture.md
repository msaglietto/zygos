# Spec: `src/worker/tessera_capture.zig` — taxonomy-routed capture (W4, M4)

`zygos::tessera::capture` turns raw input into a note in the right place. The
routing taxonomy (destinations + tag vocabulary) is INJECTED from `zygos.zon`
config — never hardcoded (ADR-004): the vault owner edits config, not Zig.
Classification is one `zygos::turns::run` turn with `step_id:"tessera-capture"`
so `zygos::models::resolve` can route it to a cheap model. A capture is never
lost: any classifier malfunction falls back to the ideas destination tagged
`#needs-review`.

## Taxonomy config (ZON, router.zig's `std.zon.parse` idiom — text in, no file I/O)

```zig
pub const Destination = struct {
    name: []const u8,        // classifier-facing key, e.g. "ideas"
    path: []const u8,        // vault-relative note path, e.g. "Rumbles/Fleetings.md"
    description: []const u8, // one line for the classifier prompt
};

const TaxonomyData = struct {
    destinations: []const Destination = &.{},
    tags: []const []const u8 = &.{},   // allowed vocabulary, verbatim with '#'
    fallback: []const u8 = "",         // MUST name a destination
};

pub const Taxonomy = struct {
    gpa, data,
    pub fn parse(gpa, zon_text: [:0]const u8) error{ OutOfMemory, ParseZon, BadTaxonomy }!Taxonomy;
    // BadTaxonomy: empty destinations, or fallback not naming one (fail closed at startup).
    pub fn deinit(self: *Taxonomy) void;
    pub fn find(self: *const Taxonomy, name: []const u8) ?Destination;
};
```

## Worker

`OrientWorker` shape. Config:

```zig
pub const Config = struct {
    root: []const u8,                       // vault root
    taxonomy: Taxonomy,                     // parsed at startup, owned by caller
    turn_function: []const u8 = "zygos::turns::run",
    provider_function: ?[]const u8 = null,  // rides the turn request (tests use the fake)
    router_function: ?[]const u8 = null,    //   — exactly one of these two, like mission.zig
    checkpoint_function: ?[]const u8 = null, // W5 seam: call before the write, fail closed
};
```

### `zygos::tessera::capture`

Request `{"input":"...","date":"YYYY-MM-DD HH:MM"}` (both required; blank
input ⇒ error.Failed — an empty capture is a caller bug, not a note).

1. **Classify.** Build the turn request: `step_id:"tessera-capture"`,
   `max_steps:1`, no tools; system prompt enumerates the taxonomy
   (name + description per destination, allowed tags) and demands ONLY a JSON
   object `{"destination":<name>,"tags":[<from vocabulary>]}`; the user
   message is the raw input. Call `turn_function` on the bus.
2. **Parse fail-closed → fallback, never loss.** Fallback (destination :=
   taxonomy.fallback, tags := `["#needs-review"]`) when: the turn call
   errors, stop != "end_turn", no assistant text, text is not a JSON object,
   `destination` names no taxonomy entry, or `tags` contains anything outside
   the vocabulary. NO partial trust: a reply with a good destination but a
   bad tag is still a full fallback (simplest rule that can't guess).
3. **Checkpoint seam.** If `checkpoint_function` set: bus-call it first;
   error ⇒ error.Failed, nothing written (same rule as continuity).
4. **Write.** Append to `<root>/<destination.path>` (create file + parent
   dirs if missing; atomic tmp+rename, mission_store idiom):
   ```
   \n## Capture — <date>\n<tags space-joined>\n\n<input verbatim>\n
   ```
   Raw input goes in verbatim — shaping is M5, not W4.
5. Reply `{"destination":<name>,"path":<vault-relative>,"tags":[...],"fallback":<bool>}`.

## Test contract (RED first) — TmpDir vault + scripted fake provider (mission.zig's RecProvider pattern), real TurnOrchestrator on the bus

1. `taxonomy parse rejects empty destinations and unknown fallback (BadTaxonomy)`
2. `classifier's valid destination+tags routes the note there; file contains input verbatim`
3. `capture creates the destination file and parents on first write`
4. `malformed classifier JSON falls back to ideas + #needs-review; input not lost`
5. `unknown destination name falls back`
6. `tag outside the vocabulary falls back (no partial trust)`
7. `provider error / non-end_turn stop falls back (turn ran, capture survived)`
8. `blank input is error.Failed, nothing written`
9. `configured checkpoint_function failure blocks the write (fail closed)`
10. `classification turn carries step_id "tessera-capture" (assert on the fake provider's recorded request)`
11. `no leaks`
