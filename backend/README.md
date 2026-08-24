# coralfull backend

Serves reef scan sites to the web and macOS viewers.

A scan is produced locally — Metashape and CoralScapes run on the machine that
took the photos — and then published here, so every client sees the same list
regardless of which laptop built it. Metadata goes to Postgres; artifacts go to
a content-addressed blob store on disk.

Structured after [`go-skeleton@fiber-app-skeleton`](https://github.com/richardsonjp/go-skeleton):
`handler → service → repository → model`, with `txRepo.Run` called from the
service layer only.

## Running it

```bash
cp .env.example .env      # godotenv needs KEY=value, not "KEY: value"
make db-up                # postgres:17 on host port 5433
make migration-up
make run                  # :8321
```

`make help` lists every target. `make test` needs the database up and migrated;
tests that require it skip cleanly when it is not.

| Env | Default | |
|---|---|---|
| `SYSTEM_ADDR` | `:8321` | |
| `DB_HOST` / `DB_PORT` | `127.0.0.1` / `5433` | 5432 is usually a local Postgres |
| `STORAGE_DATA_DIR` | `./data` | gitignored |
| `STORAGE_MAX_ASSET_BYTES` | 512 MiB | per artifact |
| `ALLOWED_ORIGINS` | `http://localhost:3000` | comma separated, or `*` |

## Data model

```
sites          id, name, priority, state, state_message, photo_count,
               tags[], cover_path, created_at, updated_at
site_assets    site_id, rel_path, storage_key, content_type, bytes
               UNIQUE (site_id, rel_path)
site_analyses  site_id, manifest jsonb, generated_at,
               semantic_model, depth_producer
```

`rel_path` is spelled exactly as the analysis manifest spells it
(`site_b_frames/TIMELAPSE_0119_rgb.jpg`), because that is the string both
clients join onto a base to build a URL.

The manifest is stored as opaque `jsonb` and served back byte for byte. It is
the local pipeline's contract with the viewers, not this service's — keeping it
opaque means a pipeline change does not need a migration here.

Blobs are named `<sha256><ext>` and sharded two levels deep:

```
data/blobs/ab/cd/abcd…ef.ply
```

Content addressing means re-uploading the same bytes is free, the key doubles as
a strong ETag, and a blob's contents never change — which is why Fiber's
hardcoded 10-second file cache and its missing `If-Range` support are both
harmless here. Two sites sharing an artifact share one blob; deleting one site
unlinks a blob only when nothing else references it.

## API

```
GET    /healthz
GET    /api/sites                     list
GET    /api/sites/{id}
POST   /api/sites                     -> 201 {site, missing:[rel_path…]}
PATCH  /api/sites/{id}                name, priority, photoCount, tags, state, manifest
DELETE /api/sites/{id}                cascades; unlinks unreferenced blobs
GET    /api/sites/{id}/analysis       the manifest, verbatim
GET    /api/sites/{id}/missing        what publishing still needs
POST   /api/sites/{id}/publish        409 while anything is missing
GET    /api/sites/{id}/assets         inventory
PUT    /api/sites/{id}/files/*        upload one artifact, raw body
GET    /api/sites/{id}/files/*        serve one artifact, Range + ETag
```

Successes are wrapped in `{"data": …}`; errors are a flat
`{code, message, status, details}`.

### The site payload is Swift-`Codable`-shaped

`state` is encoded the way Swift synthesises `Codable` for an enum with
associated values, because macOS's `UploadedSite.State` decodes it directly and
`web/lib/site-record.ts` translates it for the browser:

```json
{ "state": { "ready": {} } }
{ "state": { "failed": { "_0": "metashape exited 1" } } }
```

`internal/model/enum/site_state_test.go` pins that shape. Changing it breaks the
macOS client.

The four local-path fields those client types also carry
(`sourcePhotoDirectory`, `metashapeProjectPath`, `meshPlyPath`,
`analysisManifestPath`) are deliberately omitted: they are absolute paths on
whichever laptop ran the pipeline. All four are optional on both clients.

## Publishing

`tools/publish_site.py` uploads a finished site directory. One request per file,
so a dropped connection costs one file rather than the whole ~55 MB, and
re-running skips whatever a previous attempt stored.

```bash
python3 tools/publish_site.py --dir ~/Library/Application\ Support/coralfull/sites/<uuid> \
                              --name "Site B" --priority medium
```

`tools/process_site.py` calls it as a final `publish` stage, so both clients get
publishing without their own upload code. `--no-publish` keeps a scan local.
A publish failure does not fail the pipeline — the analysis is already on disk
and can be retried.

When the client created the site row up front (the web app does, so an
in-progress scan is visible while it builds), pass `--site-id` and the publisher
uploads into that record instead of creating a second one.

## Clients

Both viewers read their site list from here. Point them elsewhere with:

| Client | How |
|---|---|
| web | `NEXT_PUBLIC_API_BASE=http://host:8321 npm run dev` |
| macOS | `defaults write juno.coralfull CoralfullAPIBaseURL http://host:8321`, or the `CORALFULL_API` environment variable |

`CORALFULL_API` is also what `tools/publish_site.py` reads, so one export points
the whole toolchain at the same backend.

**macOS mirrors rather than streams.** Its analysis stack -- a hand-rolled
binary PLY parser, `CGImageSource` decoding, an mtime+size cache signature, a
sibling-`.jpg` texture fallback -- is built on local file URLs throughout.
Rather than rewrite all of that, `SiteMirror` downloads a site's artifacts into
`~/Library/Application Support/coralfull/sites/<id>/analysis/`, which is exactly
where `SiteAnalysisSource.uploaded(siteID:)` already looks. Opening a site the
first time fetches ~83 files (~54 MB); after that it is local, and works offline.

It deliberately skips each frame's `mask`: `AnalysisFrame` has no field for it
and the viewer never displays it, so mirroring them would fetch 26 files per
site for nothing. The backend still requires them before publishing.

## No authentication

Scans are public and unowned by design. Anyone who can reach the port can create
and delete sites. What *is* enforced: a hard per-asset size cap, a validated
site-relative path vocabulary (`pkg/utils/relpath`), and rejection of empty
bodies.

## Notes on Fiber

Three behaviours worth knowing, all verified against
`fiber v2.52.10` / `fasthttp v1.51.0` rather than assumed:

- `c.SendFile` supplies Range, `206` with `Content-Range`, `416`,
  `Accept-Ranges`, `Last-Modified` and `If-Modified-Since` → `304`. It does
  **not** supply an ETag — fasthttp never sets one — so the asset handler does.
  Fiber's `middleware/etag` is not an alternative: it calls `Response.Body()`,
  which drains the file into memory.
- `StreamRequestBody: true` alone does nothing for multipart; fasthttp fully
  parses the form before the handler runs unless `DisablePreParseMultipartForm`
  is also set. Both are set, though nothing here uses multipart.
- `BodyLimit` stops being enforced once `StreamRequestBody` is on —
  `ErrBodyTooLarge` is swallowed — so the cap lives in the asset handler.

`SendFile` also has no path-traversal guard of its own (`Root: ""`,
`AllowEmptyRoot: true`; gofiber/fiber#4345, closed as working-as-intended). It
is only ever handed a path derived from a storage key this service generated;
the request-supplied part is validated separately and used only as a lookup key.
