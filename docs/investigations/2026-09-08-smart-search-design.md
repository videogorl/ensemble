# Smart music search: design proposal and provider evidence

Status: proposal, not implemented. Researched 2026-09-08 against checkout
`0c1ddbe2`. This extends the reproduced straight/curly apostrophe search bug
into the requested normalization, typo tolerance, transliteration, punctuation
omission, ampersand equivalence, ranking, and possible lyric search work.

## Product objective

People should find music using the name, spelling, artist, or fragment they
remember. Broader matching must not make precise searches less useful. Preserve
original metadata, source identities, hidden-source rules, and offline browsing.

Treat three jobs separately: interpreting the query, retrieving plausible
candidates, and ranking/presenting them. A better scorer cannot recover a song
that a literal database predicate already excluded.

## Verified current implementation

- `EnsemblePersistence/.../RepositoryPredicates.swift` splits queries on
  whitespace, requires every token, and uses `CONTAINS[cd]` across fields.
  Track search covers title, artist, and album; repository results are sorted
  alphabetically. Apostrophe variants are not equivalent.
- `EnsembleCore/.../MediaFilterEngine.swift` uses lowercased substring matching
  for tracks, albums, and artists. PlaylistViewModel has another title matcher.
  Library filtering and Search therefore already have different semantics.
- `SearchViewModel.determineSearchSectionOrder()` always orders nonempty
  sections Artists, Albums, Playlists, Songs. Its priority comment mentions ties,
  but counts only determine whether a section is present. Tests assert this order.
- Search applies source/hidden-item visibility and existing merging projections.
  Any new retrieval/ranking must preserve that pipeline and exact-source actions.
- `AppleMusicCatalogSearch.swift` is currently iOS 18+ only. It requests 25
  results per configured MusicKit search limit and maps typed collections; it
  does not request mixed top results or autocomplete suggestions.
- `LyricsService.swift` caches source/track/asset-specific lyric content in JSON
  and loads lyrics through the source capability. It has no full-text lyric
  index and explicitly skips Apple Music tracks. Displaying lyrics for some
  tracks does not establish complete library coverage.
- `EnsembleSiriShared/SiriMatching.swift` already has normalization and edit
  similarity. Its ASCII-only regular expression removes non-Latin text; its
  command stripping and whole-phrase scoring are not suitable for direct reuse
  as general typed search. Reuse appropriate primitives, not Siri interpretation.

## Matching contract

Keep original, normalized, and bounded alternative forms, with the reason for
each match. Lossy forms are retrieval aliases, never metadata or identity keys.

| User variation | Proposed behavior | Important boundary |
| --- | --- | --- |
| Case, equivalent Unicode, accents, width | Case/diacritic/width folding and consistent Unicode normalization | Original spelling remains available for exact-match preference and display. |
| Straight, curly, modifier apostrophes | Canonical apostrophe plus apostrophe-omitted alias | `it's`, `it’s`, and `its` find the title. |
| Repeated or unusual whitespace | Trim and collapse whitespace; use native word segmentation | Do not require spaces between words in every writing system. |
| Punctuation omitted or spaced differently | Keep both separator and compact aliases | `K.Flay`, `k flay`, `kflay`; `AC/DC`, `ac dc`, `acdc`. Avoid joining unrelated title words indiscriminately. |
| Symbol-only names | Preserve literal-symbol matching | `!!!` and `+` must not become empty queries matching everything. |
| Ampersand | Add `and` as an alternative conjunction token | `Florence & the Machine` and `Florence and the Machine`; never replace `and` inside another word. Also handle compact `R&B` / `r and b`. |
| Partial typing | Match complete words plus a prefix for the final unfinished word | Prefix evidence is stronger than arbitrary interior substring evidence; preserve intentional substring access as a lower tier. |
| Words in a different order | Match across title and artist, with full query coverage preferred | `kflay just a lot` and `just a lot kflay`; adjacency/order strengthen a result rather than being required everywhere. |
| Typing mistakes | Bounded token edit distance including adjacent transposition | Start with no fuzzy expansion for 1–3 character tokens, one edit for 4–7, up to two for 8+; these are tuning defaults, not verified ideal thresholds. |
| Romanized names | Native-script text plus native transliteration aliases | Transliteration is not translation and cannot infer every Japanese reading or common artist alias. |
| Credited aliases | Use alternate names, credited/featured artists and album artist where data exists | `P!nk` to `Pink`, `CHVRCHES` to `Chvrches`, and artist renames are not all the same normalization problem. `P!nk` needs a real alias or another supported match path. |
| Version qualifiers | Match core title while retaining live/remix/acoustic/remaster terms | An explicit `live` request must favor live recordings. Do not silently merge recordings or discard all parenthetical text. |
| Numbers and abbreviations | Explicit metadata-backed aliases where justified | No universal `2` → `to/too` or number-word rewrites; protect `U2`, `1975`, `M83`. |
| Common words | Retain them; reduce their contribution in long queries | Do not erase meaningful names such as `The The` or short titles such as `A`. |

Use native Foundation folding/transforms and language-aware segmentation where
they fit. Foundation provides script transformation APIs, but romanization
requires language-aware expectations and supplemental aliases; it is not a
guarantee of every spelling a listener remembers. [Apple transformations](https://developer.apple.com/documentation/foundation/string-transformations),
[Unicode transliteration guidance](https://cldr.unicode.org/index/cldr-spec/transliteration-guidelines).

Avoid Cartesian products of all aliases. Bound alternatives per token, fuzzy
tokens per query, and candidate work. For a multiword query, use reliable words
as anchors when available. A single misspelled artist must still be retrievable
through the fuzzy vocabulary path. Exact prefix completion remains available
for short queries even when fuzzy matching is disabled.

Relax missing words only as an explained fallback. Never quietly reinterpret
an explicit artist or version qualifier simply to produce more results. Do not
replace the typed query automatically; offer a correction and preserve literal
results. Quoted phrases can request contiguous matching after harmless
typographic normalization, without fuzzy expansion inside the quotation.

## Ranking results

Use explainable relevance tiers, then tie-breakers. Initial tier ordering:

1. Complete entity-name match, or full title plus matching artist/version hints.
2. Equivalent full-name match through safe normalization or known aliases.
3. Exact phrase or complete query-token coverage, favoring primary name fields,
   ordered/adjacent words, and a final-word prefix.
4. Complete coverage requiring bounded spelling correction; strong supported
   transliteration can sit with equivalent-name evidence rather than all fuzzy hits.
5. Weaker substrings, partial coverage, or exploratory metadata relationships,
   clearly separated when confidence is low.

An artist-name-only match on a track is weaker evidence for that track than an
exact match to the artist entity. Broad artist queries can have artist-specific
song ordering within the Songs section. Full-query coverage matters: a candidate
matching just the artist in `kflay just a lot` must not beat the requested song.

Within a tier, consider matched field, coverage, proximity, edit cost, then a
small preference for favorites, recent successful selections, or play history.
Keep a deterministic title/source-ID tie-breaker. Personalization must not lift
a weak match over a precise unfamiliar title. Do not interpret uncalibrated
relevance scores as probabilities or add Apple's provider rank to local scores.

Use existing merging preferences to group equivalent results, preserving source
variants for playback and mutations. Relevance for a merged group comes from its
best eligible matching member; preferred source governs the representative, not
an unrelated text-match decision. Retain match evidence if an alias/source title
differs from the displayed representative. Distinct recordings remain distinct.

## Ranking sections and interaction

Recommended layout: a compact Top Results group (up to three strong, distinct
entities), followed by the strongest relevant section, then other nonempty
sections in a stable tie-break order. Keep the current section order as a tie
break initially. Rank a section by its strongest meaningful evidence, never
its raw number of matches. Lyrics are a secondary match group unless the user
chooses Lyrics or the query has strong lyric evidence and weak metadata evidence.

Examples: `kflay` promotes the artist and Artists; `its just a lot kflay` promotes
the song and Songs; an exact playlist name promotes that playlist. Ambiguous
names may show an artist, album, and song together in Top Results. Avoid a huge
hero card or duplicating most of the first screen. Repeating a top item in its
complete category list is acceptable if row identity remains stable.

Debounce/coalesce updates and cancel stale query work. Do not move the focused
row or change its action target beneath keyboard/VoiceOver users. Preserve the
original spelling in results; highlighting must map normalized matches back to
original text safely. Use a short match explanation for corrections or lyrics.

Offer content-type and source chips, useful autocomplete from the visible
library, and recent searches. Hidden/inactive sources must not leak through
suggestions, counts, snippets, or cached top results. Make active filters visible
and explain no-result causes: no match, filtered out, source unavailable, or
incomplete lyric coverage are different states. A no-match state may offer an
explicit catalog search without sending every local query remotely.

Library filters should share query normalization, aliases, token matching, and
typo tolerance, while retaining the user's selected sort and existing genre,
favorite, download, and source constraints. Provide relevance ordering as an
explicit choice rather than silently replacing their selected browse order.
Keep lyric-only matches in Search by default, so filtering a playlist or Songs
does not unexpectedly select tracks solely because of a lyric line.

## Provider lessons and limits

- Apple Music's consumer app supports remembered lyric words, library/catalog
  scope, recent searches, and natural-language requests. Consumer support is not
  a contract for third-party MusicKit behavior. [Apple search guide](https://support.apple.com/en-au/guide/iphone/iph4b506b24d/ios).
- MusicKit provides mixed, relevance-ordered top results via
  `includeTopResults`, and autocomplete through
  `MusicCatalogSearchSuggestionsRequest`, including display/search terms.
  Ensemble can preserve provider ranking for catalog results while using its own
  local ranking. These API features are separate from lyric-text access.
  [Apple WWDC22](https://developer.apple.com/videos/play/wwdc2022/110347/).
- Spotify documents searching at least three lyric words and marking hits
  “Lyrics match,” along with metadata search tags. Its ranking guidance names
  listening history and current/all-time popularity. These are useful product
  ideas, not a complete algorithm to copy. [Spotify search](https://support.spotify.com/us/article/search/),
  [Spotify ranking](https://support.spotify.com/sc-en/artists/article/spotify-search-ranking/).
- Apple's `Song.hasLyrics` is availability metadata. Reviewed public docs do
  not establish a lyric-text or explicit lyric-search API contract. Spotify's
  public Search endpoint likewise does not document lyric-body filtering.
  Do not promise consumer-app parity. [Apple hasLyrics](https://developer.apple.com/documentation/musickit/song/haslyrics),
  [Spotify API](https://developer.spotify.com/documentation/web-api/reference/search).
- Spotify research discusses query suggestions and the difficulty of retrieving
  obscure relevant entities. This supports useful suggestions and protecting
  precise long-tail matches; it does not reveal current production weights.
  [Query suggestions](https://research.atspotify.com/publications/bootstrapping-query-suggestions-in-spotifys-instant-search-system),
  [Retrievability research](https://research.atspotify.com/2023/05/improving-retrievability-in-search-with-query-generation).
- No verified current official typo thresholds, transliteration coverage, or
  exact section-ordering formula were found for either service.

## Lyric search

Recommend a local first version using already-available, permitted lyric text.
Index actual lyric lines, not LRC timestamps, metadata headers, or chord symbols.
Keep source/track identity, asset/version, language when known, and line offsets.
Search phrases and nearby words; use restrained tolerance for a misremembered
word, not unconstrained fuzzy matching across every lyric. Common phrases should
not flood ordinary short title searches. Provide a Lyrics chip for explicit
search even when metadata results are also strong.

Show a short matching excerpt with a “Lyrics match” explanation. A song matching
both metadata and lyrics remains one result with extra evidence. Opening the
result should identify the recording and make Lyrics easy to reach; seeking to
a matching timestamp is an explicit optional action, not an automatic playback
side effect. Plain lyrics remain searchable without timestamps.

Expose coverage as “Search available lyrics” or an equivalent honest scope.
Index new cache content incrementally, replace it on authoritative content
updates, and remove derived entries when the underlying source/cache is removed.
Do not scan every JSON file or fetch the entire lyric catalog per keystroke.
Do not bulk-download library lyrics as a side effect of opening Search. Complete
coverage would be a separate background acquisition feature with provider,
network, storage, and permitted-use requirements.

LRCLIB's documented `/api/search?q=` searches track title, artist, and album
metadata; it does not provide lyric-body phrase search. It cannot directly solve
“I remember this line but not the title.” [LRCLIB docs](https://lrclib.net/docs).
Catalog-wide lyric search remains dependent on a verified provider capability
and appropriate access; availability of a playback lyric display is insufficient.

## Implementation shape and validation

Share pure text primitives below Core and Persistence (the existing Support
layer fits); keep candidate storage in Persistence, ranking/intent in Core, and
presentation in UI. Leave Siri-specific command interpretation separate and
avoid changing Siri behavior accidentally during the first typed-search work.

Precompute normalized fields/aliases incrementally. Use indexed candidate
retrieval followed by bounded in-process scoring, off the main thread. A separate
rebuildable SQLite FTS index is a strong candidate for metadata plus lyrics:
FTS5 supports phrase/prefix search, weighted BM25 and snippets. It does not
provide complete typo correction automatically; trigram tokenization is not
edit-distance search and cannot be the only path for one/two-character queries.
Verify system SQLite capabilities on supported OS versions before choosing
tokenizers. Keep any sidecar separate from CoreData's private SQLite schema.
[SQLite FTS5](https://www.sqlite.org/fts5.html).

Prototype indexed retrieval on realistic catalog sizes before committing the
storage design. Normalization and fuzzy vocabulary expansion belong before
candidate exclusion; scanning/fuzzy-scoring the whole catalog on every keystroke
is not the intended architecture. Derived indexes must be versioned, rebuildable,
incrementally updated and atomically swapped, with cancellation and last-good
metadata search during rebuilding. Visibility applies before ranking/limiting
where practical, and is rechecked before publication/actions to avoid hidden
hits occupying the result budget. Preserve cached metadata during offline states.

Use one compact relevance fixture with exact expected ordering and false-positive
cases: original K.Flay queries, `kflay`, `acdc`, `r and b`, accent/Unicode variants,
one typo and transposition, native/romanized names, short symbols/names, reordered
artist/title tokens, explicit live/remix, obscure exact vs favorite fuzzy,
ambiguous entity types, and lyric-only hits. Include source visibility, alias
updates/deletion, stable results after restart and stale-query cancellation.

Measure top-1/top-5 retrieval, false positives, zero-result recovery, keystrokes
to a useful hit, p50/p95 latency, and index size/build cost. Warm local results
under roughly 100 ms after debounce is an initial target, not measured proof.
Verify memory and responsiveness on the supported 2 GB device class and macOS.
Check the same query in Search and Songs, keyboard navigation, VoiceOver, and
offline mode. Collect local synthetic benchmarks rather than requiring a new
service or logging raw users' queries.

## Recommended delivery sequence

1. Establish the shared matching contract and candidate retrieval; include all
   requested normalization, omitted punctuation, conjunction aliases,
   transliteration, and bounded typo tolerance, plus ranked local results.
2. Add Top Results/section relevance, query suggestions and match explanations;
   retain browse sort and wire supported MusicKit top results/autocomplete.
3. Add available-lyrics indexing and visible coverage. Treat full-catalog lyric
   search as a provider-dependent extension, not an unverified promise.

Later discovery can interpret concrete filters such as `90s alternative` or
`downloaded live songs` using existing metadata. Requests such as “the song from
that movie” require soundtrack/credit data; semantic mood descriptions and
humming require different retrieval capabilities. Track them separately instead
of pretending normalization alone can answer them. The present proposal does
not require embeddings, a cloud search service, or an LLM on each keystroke.
