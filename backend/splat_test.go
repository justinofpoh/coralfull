package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidID(t *testing.T) {
	ok := []string{"site-a", "a", "reef2024", strings.Repeat("a", 64)}
	bad := []string{
		"", "..", "../etc", "a/b", "a.b", "Site-A", "-lead", "a b",
		strings.Repeat("a", 65), "site-a.ply", `a\b`,
	}
	for _, s := range ok {
		if !validID(s) {
			t.Errorf("validID(%q) = false, want true", s)
		}
	}
	for _, s := range bad {
		if validID(s) {
			t.Errorf("validID(%q) = true, want false", s)
		}
	}
}

func TestAssetPathRejectsEscapes(t *testing.T) {
	s := &Store{dir: "/data"}
	want := filepath.Join("/data", "splats", "site-a.ply")
	got, err := s.AssetPath("site-a", "site-a.ply")
	if err != nil || got != want {
		t.Fatalf("AssetPath(site-a, site-a.ply) = %q, %v; want %q, nil", got, err, want)
	}
	// PathValue hands us the URL-decoded segment, so %2e%2e%2f arrives as ../
	for _, name := range []string{
		"", "..", "../../etc/passwd", "site-a../../x", "/etc/passwd",
		"site-b.ply", // right shape, wrong scan
		"secrets",    // no id prefix
	} {
		if p, err := s.AssetPath("site-a", name); err == nil {
			t.Errorf("AssetPath(site-a, %q) = %q, want error", name, p)
		}
	}
}

func TestPLYVertexCount(t *testing.T) {
	if n, err := plyVertexCount(bytes.NewReader(fakePLY(139307))); err != nil || n != 139307 {
		t.Fatalf("got %d, %v; want 139307, nil", n, err)
	}
	for _, b := range [][]byte{
		[]byte("not a ply at all"),
		[]byte("ply\nformat ascii 1.0\nend_header\n"),     // no vertex element
		[]byte("ply\nformat ascii 1.0\nelement vertex 5"), // no end_header
	} {
		if _, err := plyVertexCount(bytes.NewReader(b)); err == nil {
			t.Errorf("plyVertexCount(%q) = nil error, want error", b)
		}
	}
}

func TestUploadAndServe(t *testing.T) {
	a := newTestAPI(t)

	// happy path
	rec := a.post(t, upload{id: "site-a", meta: goodMeta, model: fakePLY(10), labels: make([]byte, 10), cover: jpeg()})
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload = %d %s, want 201", rec.Code, rec.Body)
	}

	// all four files landed
	for _, suffix := range []string{sidecarSuffix, modelSuffix, labelsSuffix, coverSuffix} {
		if _, err := os.Stat(filepath.Join(a.store.splatsDir(), "site-a"+suffix)); err != nil {
			t.Errorf("missing %s: %v", suffix, err)
		}
	}

	// index sees exactly one scan, with derived fields filled in
	var list []SplatView
	a.getJSON(t, "/api/splats", &list)
	if len(list) != 1 || list[0].ID != "site-a" || list[0].Name != "Main Reef Structure" {
		t.Fatalf("list = %+v, want one site-a record", list)
	}
	if list[0].Bytes == 0 || list[0].Assets["model"] != "/api/splats/site-a/assets/site-a.ply" {
		t.Errorf("derived fields wrong: bytes=%d assets=%v", list[0].Bytes, list[0].Assets)
	}

	// range request on the model
	req := httptest.NewRequest("GET", "/api/splats/site-a/assets/site-a.ply", nil)
	req.Header.Set("Range", "bytes=0-9")
	rec = httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusPartialContent || rec.Body.Len() != 10 {
		t.Errorf("range = %d, %d bytes; want 206, 10 bytes", rec.Code, rec.Body.Len())
	}
	if rec.Header().Get("Content-Type") != "application/octet-stream" {
		t.Errorf("model Content-Type = %q", rec.Header().Get("Content-Type"))
	}

	// cover has no extension; ServeContent must sniff it
	rec = httptest.NewRecorder()
	a.routes().ServeHTTP(rec, httptest.NewRequest("GET", "/api/splats/site-a/assets/site-a.cover", nil))
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "image/jpeg") {
		t.Errorf("cover Content-Type = %q, want image/jpeg", ct)
	}

	// cross-scan and traversal reads
	for _, path := range []string{
		"/api/splats/site-a/assets/site-b.ply",
		"/api/splats/site-a/assets/%2e%2e%2f%2e%2e%2fgo.mod",
	} {
		rec = httptest.NewRecorder()
		a.routes().ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("GET %s = %d, want 400", path, rec.Code)
		}
	}

	// duplicate id
	rec = a.post(t, upload{id: "site-a", meta: goodMeta, model: fakePLY(10), labels: make([]byte, 10), cover: jpeg()})
	if rec.Code != http.StatusConflict {
		t.Errorf("duplicate upload = %d, want 409", rec.Code)
	}
}

func TestUploadRejects(t *testing.T) {
	base := upload{id: "site-b", meta: goodMeta, model: fakePLY(10), labels: make([]byte, 10), cover: jpeg()}

	cases := map[string]func(u *upload){
		"bad id":            func(u *upload) { u.id = "../etc" },
		"missing model":     func(u *upload) { u.model = nil },
		"missing labels":    func(u *upload) { u.labels = nil },
		"missing cover":     func(u *upload) { u.cover = nil },
		"missing meta":      func(u *upload) { u.meta = "" },
		"meta not json":     func(u *upload) { u.meta = "{" },
		"meta no name":      func(u *upload) { u.meta = `{"classes":[{"id":0}]}` },
		"meta no classes":   func(u *upload) { u.meta = `{"name":"x"}` },
		"model not a ply":   func(u *upload) { u.model = []byte("PK\x03\x04 zip") },
		"labels wrong size": func(u *upload) { u.labels = make([]byte, 9) },
		"cover not image":   func(u *upload) { u.cover = []byte("<html>") },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			a := newTestAPI(t)
			u := base
			mutate(&u)
			if rec := a.post(t, u); rec.Code != http.StatusBadRequest {
				t.Fatalf("= %d %s, want 400", rec.Code, rec.Body)
			}
			if n := countScans(t, a); n != 0 {
				t.Fatalf("rejected upload left %d scans on disk", n)
			}
		})
	}
}

func TestUploadTooLarge(t *testing.T) {
	a := newTestAPI(t)
	a.maxUpload = 64
	rec := a.post(t, upload{id: "site-b", meta: goodMeta, model: fakePLY(4096), labels: make([]byte, 4096), cover: jpeg()})
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("= %d %s, want 413", rec.Code, rec.Body)
	}
}

// --- helpers ---

const goodMeta = `{"name":"Main Reef Structure","location":"Padang Bai, Bali",
 "photoCount":129,"priority":"high",
 "classes":[{"id":0,"name":"other/background","color":"#4b5563"},
            {"id":1,"name":"healthy coral","color":"#00c800"}]}`

func newTestAPI(t *testing.T) *api {
	t.Helper()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return &api{store: store, maxUpload: 256 << 20}
}

// fakePLY builds a header-only PLY. plyVertexCount only reads the ASCII header,
// so the body is irrelevant here; padding keeps the file long enough to range over.
func fakePLY(vertices int) []byte {
	h := fmt.Sprintf("ply\nformat binary_little_endian 1.0\nelement vertex %d\nproperty float x\nend_header\n", vertices)
	return append([]byte(h), bytes.Repeat([]byte{0}, 512)...)
}

func jpeg() []byte { return append([]byte{0xFF, 0xD8, 0xFF, 0xE0}, bytes.Repeat([]byte{0}, 64)...) }

type upload struct {
	id, meta             string
	model, labels, cover []byte
}

func (a *api) post(t *testing.T, u upload) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	if u.id != "" {
		mw.WriteField("id", u.id)
	}
	if u.meta != "" {
		mw.WriteField("meta", u.meta)
	}
	for _, f := range []struct {
		field string
		data  []byte
	}{{"model", u.model}, {"labels", u.labels}, {"cover", u.cover}} {
		if f.data == nil {
			continue
		}
		part, err := mw.CreateFormFile(f.field, f.field)
		if err != nil {
			t.Fatal(err)
		}
		part.Write(f.data)
	}
	mw.Close()

	req := httptest.NewRequest("POST", "/api/splats", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	return rec
}

func (a *api) getJSON(t *testing.T, path string, into any) {
	t.Helper()
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s = %d %s", path, rec.Code, rec.Body)
	}
	if err := json.NewDecoder(rec.Body).Decode(into); err != nil && err != io.EOF {
		t.Fatal(err)
	}
}

func countScans(t *testing.T, a *api) int {
	t.Helper()
	list, err := a.store.List()
	if err != nil {
		t.Fatal(err)
	}
	return len(list)
}
