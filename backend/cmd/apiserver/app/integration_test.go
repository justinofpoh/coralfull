package app_test

// End-to-end tests against a real Postgres. They skip unless one is reachable,
// so `make test` stays runnable without Docker:
//
//	make db-up && make migration-up && make test
//
// A real database is the point: every bug this file pins down was invisible to
// unit tests. gorm writing an explicit NULL for a nil slice into a NOT NULL
// column, for one, only fails against Postgres.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"testing"

	"github.com/gofiber/fiber/v2"

	"coralfull/backend/cmd/apiserver/app/routes"
	"coralfull/backend/cmd/apiserver/app/store"
	"coralfull/backend/config"
	"coralfull/backend/pkg/blobstore"
	"coralfull/backend/pkg/clients/db"
)

func setup(t *testing.T) (*fiber.App, func()) {
	t.Helper()
	config.Init()

	dbdget := db.NewDBDelegate()
	if err := dbdget.Init(); err != nil {
		t.Skipf("no database (%v); run `make db-up && make migration-up`", err)
	}
	if err := dbdget.Get(t.Context()).Exec("SELECT 1 FROM sites LIMIT 1").Error; err != nil {
		dbdget.Close()
		t.Skipf("schema not migrated (%v); run `make migration-up`", err)
	}

	blobs, err := blobstore.New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	app := routes.NewHTTPServer(store.New(dbdget, blobs, 1<<20))
	return app, func() { dbdget.Close() }
}

// do sends a request through the app. Fiber's Test needs an explicit timeout for
// bodies that take more than a moment.
func do(t *testing.T, app *fiber.App, method, path string, body []byte, ctype string) (int, []byte) {
	t.Helper()
	var r io.Reader
	if body != nil {
		r = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, path, r)
	if err != nil {
		t.Fatal(err)
	}
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	if body != nil {
		req.ContentLength = int64(len(body))
	}
	resp, err := app.Test(req, 10_000)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func createSite(t *testing.T, app *fiber.App, payload string) string {
	t.Helper()
	status, body := do(t, app, "POST", "/api/sites", []byte(payload), fiber.MIMEApplicationJSON)
	if status != http.StatusCreated {
		t.Fatalf("create -> %d: %s", status, body)
	}
	var out struct {
		Data struct {
			Site struct {
				ID   string          `json:"id"`
				Tags []string        `json:"tags"`
				St   json.RawMessage `json:"state"`
			} `json:"site"`
			Missing []string `json:"missing"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { do(t, app, "DELETE", "/api/sites/"+out.Data.Site.ID, nil, "") })
	return out.Data.Site.ID
}

// A payload without "tags" must not write NULL into a NOT NULL column.
func TestCreateWithoutOptionalFields(t *testing.T) {
	app, done := setup(t)
	defer done()

	id := createSite(t, app, `{"name":"minimal"}`)

	status, body := do(t, app, "GET", "/api/sites/"+id, nil, "")
	if status != http.StatusOK {
		t.Fatalf("get -> %d: %s", status, body)
	}
	var got struct {
		Data struct {
			Tags     []string        `json:"tags"`
			State    json.RawMessage `json:"state"`
			Priority string          `json:"priority"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if got.Data.Tags == nil || len(got.Data.Tags) != 0 {
		t.Errorf("tags = %v, want []", got.Data.Tags)
	}
	if got.Data.Priority != "medium" {
		t.Errorf("priority = %q, want medium", got.Data.Priority)
	}
	// The Swift-Codable shape the macOS client decodes.
	if s := string(got.Data.State); s != `{"importing":{}}` {
		t.Errorf("state = %s, want {\"importing\":{}}", s)
	}
}

func TestPublishGatedOnAssets(t *testing.T) {
	app, done := setup(t)
	defer done()

	manifest := `{"frames":[{"rgb":"f/a.jpg","semantic":"f/b.jpg","depth":"f/c.png","mask":"f/d.png"}],
	              "mesh":{"ply":"m.ply","texture":"m.jpg","vertexLabels":null}}`
	id := createSite(t, app, fmt.Sprintf(`{"name":"gated","manifest":%s}`, manifest))

	status, body := do(t, app, "POST", "/api/sites/"+id+"/publish", nil, "")
	if status != http.StatusConflict {
		t.Fatalf("publish with nothing uploaded -> %d: %s", status, body)
	}
	var e struct {
		Code    string   `json:"code"`
		Details []string `json:"details"`
	}
	json.Unmarshal(body, &e)
	if e.Code != "SITE_INCOMPLETE" || len(e.Details) != 6 {
		t.Fatalf("code=%s details=%v, want SITE_INCOMPLETE with 6 missing", e.Code, e.Details)
	}

	for _, rel := range e.Details {
		if s, b := do(t, app, "PUT", "/api/sites/"+id+"/files/"+rel, []byte("x"), ""); s != http.StatusCreated {
			t.Fatalf("PUT %s -> %d: %s", rel, s, b)
		}
	}

	if s, b := do(t, app, "POST", "/api/sites/"+id+"/publish", nil, ""); s != http.StatusOK {
		t.Fatalf("publish after upload -> %d: %s", s, b)
	} else if !bytes.Contains(b, []byte(`{"ready":{}}`)) {
		t.Errorf("published state not ready: %s", b)
	}
}

func TestAssetServing(t *testing.T) {
	app, done := setup(t)
	defer done()
	id := createSite(t, app, `{"name":"assets"}`)

	content := bytes.Repeat([]byte("abcd"), 256) // 1 KiB
	if s, b := do(t, app, "PUT", "/api/sites/"+id+"/files/mesh/model.ply", content, ""); s != http.StatusCreated {
		t.Fatalf("PUT -> %d: %s", s, b)
	}

	// Whole file, with the extension driving Content-Type despite no declared one.
	req, _ := http.NewRequest("GET", "/api/sites/"+id+"/files/mesh/model.ply", nil)
	resp, err := app.Test(req, 10_000)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !bytes.Equal(got, content) {
		t.Fatalf("GET -> %d, %d bytes (want 200, %d)", resp.StatusCode, len(got), len(content))
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/octet-stream" {
		t.Errorf("Content-Type = %q", ct)
	}
	etag := resp.Header.Get("ETag")
	if etag == "" {
		t.Fatal("no ETag; fasthttp never sets one, the handler must")
	}

	// Range: fasthttp's FS supplies 206 + Content-Range.
	req, _ = http.NewRequest("GET", "/api/sites/"+id+"/files/mesh/model.ply", nil)
	req.Header.Set("Range", "bytes=0-99")
	resp, _ = app.Test(req, 10_000)
	got, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent || len(got) != 100 {
		t.Errorf("range -> %d, %d bytes; want 206, 100", resp.StatusCode, len(got))
	}
	if cr := resp.Header.Get("Content-Range"); cr != "bytes 0-99/1024" {
		t.Errorf("Content-Range = %q", cr)
	}

	// Conditional GET.
	req, _ = http.NewRequest("GET", "/api/sites/"+id+"/files/mesh/model.ply", nil)
	req.Header.Set("If-None-Match", etag)
	resp, _ = app.Test(req, 10_000)
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotModified {
		t.Errorf("If-None-Match -> %d, want 304", resp.StatusCode)
	}
}

func TestAssetRejections(t *testing.T) {
	app, done := setup(t)
	defer done()
	id := createSite(t, app, `{"name":"rejections"}`)

	cases := map[string]struct {
		path string
		body []byte
		want int
	}{
		"traversal":  {"../../../etc/passwd", []byte("x"), http.StatusBadRequest},
		"empty body": {"empty.bin", []byte{}, http.StatusBadRequest},
		"too large":  {"big.bin", bytes.Repeat([]byte("x"), (1<<20)+1), http.StatusRequestEntityTooLarge},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			s, b := do(t, app, "PUT", "/api/sites/"+id+"/files/"+c.path, c.body, "")
			if s != c.want {
				t.Errorf("-> %d, want %d: %s", s, c.want, b)
			}
		})
	}

	if s, _ := do(t, app, "GET", "/api/sites/"+id+"/files/never-uploaded.png", nil, ""); s != http.StatusNotFound {
		t.Errorf("missing asset -> %d, want 404", s)
	}
	if s, _ := do(t, app, "GET", "/api/sites/00000000-0000-0000-0000-000000000000", nil, ""); s != http.StatusNotFound {
		t.Errorf("unknown site -> %d, want 404", s)
	}
}

func TestMain(m *testing.M) {
	// Tests run from the package dir; config.Init looks for ./.env there.
	if _, err := os.Stat(".env"); err != nil {
		os.Chdir("../..")
	}
	os.Exit(m.Run())
}
