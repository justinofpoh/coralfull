# coralfull backend

Serves reef splat scans to the web viewer and the macOS app.

Standard library only — `go.mod` has zero dependencies. Storage is the
filesystem; there is no database and no object store.

```
go run .          # listens on :8321
go test ./...
```

## Configuration

| Env | Default | |
|---|---|---|
| `PORT` | `8321` | 8080 and 8090 are commonly occupied (stalwart, docker) |
| `DATA_DIR` | `./data` | gitignored; scans live in `$DATA_DIR/splats` |
| `ALLOWED_ORIGINS` | `http://localhost:3000` | comma separated, or `*` |
| `MAX_UPLOAD_BYTES` | `268435456` (256 MB) | hard cap on a single upload |

## A scan on disk

Four files sharing one id prefix. The sidecar is what makes the scan exist —
`GET /api/splats` lists `*.site.json` and nothing else.

```
data/splats/
  site-a.site.json    record: name, location, priority, class taxonomy
  site-a.ply          geometry
  site-a.labels.bin   one uint8 class id per splat
  site-a.cover        cover image, extensionless so Content-Type is sniffed
```

`site-a.site.json`:

```json
{
  "id": "site-a",
  "name": "Main Reef Structure",
  "location": "Padang Bai, Bali",
  "photoCount": 129,
  "priority": "high",
  "splatCount": 139307,
  "capturedAt": "2026-08-18T00:00:00Z",
  "classes": [
    { "id": 0, "name": "other/background", "color": "#4b5563" },
    { "id": 1, "name": "healthy coral",    "color": "#00c800" },
    { "id": 2, "name": "unhealthy coral",  "color": "#dc1e1e" }
  ]
}
```

`classes` lives with the record rather than in its own file because
`labels.bin` is a bare array of class ids — without the taxonomy it cannot be
coloured.

## API

```
GET  /healthz
GET  /api/splats                      list, newest fields derived from disk
GET  /api/splats/{id}                 one record            404 unknown
GET  /api/splats/{id}/assets/{name}   bytes, Range + ETag   400 escapes scan
POST /api/splats                      create                400 / 409 / 413
```

Every record carries an `assets` map of ready-made URLs, so clients never
build paths by hand:

```json
"assets": {
  "model":  "/api/splats/site-a/assets/site-a.ply",
  "labels": "/api/splats/site-a/assets/site-a.labels.bin",
  "cover":  "/api/splats/site-a/assets/site-a.cover"
}
```

### Upload

One multipart request. All five fields are required; a scan missing any of
them is not renderable, so it is rejected whole.

```bash
curl -F id=site-b \
     -F 'meta={"name":"Site B","priority":"medium","classes":[{"id":0,"name":"bg","color":"#4b5563"}]}' \
     -F model=@site-b.ply \
     -F labels=@site-b.labels.bin \
     -F cover=@site-b.jpg \
     localhost:8321/api/splats
```

Checks, in order: body size cap; `id` matches `^[a-z0-9][a-z0-9-]{0,63}$`;
`meta` parses and has a name and classes; `model` is a real PLY; `labels` is
exactly one byte per vertex in that PLY; `cover` is JPEG or PNG. Files stream
to `data/tmp` and only move into place once everything passes.

**There is no authentication.** Anyone who can reach the port can create a
scan. A single bearer token on `POST` is a short middleware away when this
leaves your machine.

## Seeding a scan from git

The reef scan is not on `main` — it lives on `origin/feature/macos-ui`:

```bash
B=origin/feature/macos-ui
R=macos/coralfull/coralfull
git -C .. show "$B:$R/ReefViewer/reef_struct_orient_proper_cleaned.ply"        > data/splats/site-a.ply
git -C .. show "$B:$R/ReefViewer/reef_struct_orient_proper_cleaned.labels.bin" > data/splats/site-a.labels.bin
git -C .. show "$B:$R/Assets.xcassets/main_reef_struct_cover.imageset/main_reef_struct_cover.jpeg" > data/splats/site-a.cover
# then write data/splats/site-a.site.json as above
```

## Wiring a client (not done yet)

Neither viewer points here. The web one is a single env var:

```bash
cd ../web
NEXT_PUBLIC_REEF_MODEL_URL=http://localhost:8321/api/splats/site-a/assets/site-a.ply npm run dev
```

Making the viewers actually *list* scans means changing
`web/components/ReefViewer.tsx` and the macOS app, which is separate work.
