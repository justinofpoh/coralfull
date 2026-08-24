// Command backend serves coral reef splat scans to the web and macOS viewers.
//
// Storage is the filesystem: data/splats holds one bundle of files per scan.
// No database, no object store, no dependencies outside the standard library.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type config struct {
	port      string
	dataDir   string
	origins   []string
	maxUpload int64
}

func loadConfig() config {
	return config{
		port:      env("PORT", "8321"), // 8080/8090 are commonly taken (stalwart, docker, ...)
		dataDir:   env("DATA_DIR", "./data"),
		origins:   strings.Split(env("ALLOWED_ORIGINS", "http://localhost:3000"), ","),
		maxUpload: envInt("MAX_UPLOAD_BYTES", 256<<20),
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int64) int64 {
	if v := os.Getenv(k); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			log.Fatalf("%s: %v", k, err)
		}
		return n
	}
	return def
}

func logf(format string, args ...any) { log.Printf(format, args...) }

func main() {
	cfg := loadConfig()

	store, err := NewStore(cfg.dataDir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	a := &api{store: store, maxUpload: cfg.maxUpload}

	srv := &http.Server{
		Addr:    ":" + cfg.port,
		Handler: cors(cfg.origins)(a.routes()),
		// No WriteTimeout: a 31MB .ply over a slow link would get cut mid-stream.
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("listening on :%s  data=%s  origins=%v", cfg.port, cfg.dataDir, cfg.origins)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

type api struct {
	store     *Store
	maxUpload int64
}

func (a *api) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /api/splats", a.list)
	mux.HandleFunc("POST /api/splats", a.upload)
	mux.HandleFunc("GET /api/splats/{id}", a.get)
	mux.HandleFunc("GET /api/splats/{id}/assets/{name}", a.asset)
	return mux
}

// cors allows the viewers to fetch across origins. Expose-Headers matters: without
// it a cross-origin fetch() cannot read Content-Range, so ranged .ply loads and
// Spark's progress reporting break.
func cors(origins []string) func(http.Handler) http.Handler {
	allowed := make(map[string]bool, len(origins))
	for _, o := range origins {
		allowed[strings.TrimSpace(o)] = true
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h := w.Header()
			h.Add("Vary", "Origin")
			if o := r.Header.Get("Origin"); o != "" && (allowed["*"] || allowed[o]) {
				h.Set("Access-Control-Allow-Origin", o)
				h.Set("Access-Control-Expose-Headers", "Content-Range, Accept-Ranges, Content-Length, ETag")
			}
			if r.Method == http.MethodOptions {
				h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
				h.Set("Access-Control-Allow-Headers", "Content-Type")
				h.Set("Access-Control-Max-Age", "86400")
				w.WriteHeader(http.StatusNoContent)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func (a *api) list(w http.ResponseWriter, r *http.Request) {
	splats, err := a.store.List()
	if err != nil {
		fail(w, http.StatusInternalServerError, "could not read scans")
		logf("list: %v", err)
		return
	}
	writeJSON(w, http.StatusOK, splats)
}

func (a *api) get(w http.ResponseWriter, r *http.Request) {
	v, err := a.store.Get(r.PathValue("id"))
	switch {
	case errors.Is(err, ErrInvalid):
		fail(w, http.StatusBadRequest, "invalid id")
	case errors.Is(err, ErrNotFound):
		fail(w, http.StatusNotFound, "no such scan")
	case err != nil:
		fail(w, http.StatusInternalServerError, "could not read scan")
		logf("get: %v", err)
	default:
		writeJSON(w, http.StatusOK, v)
	}
}

// asset streams one file of a scan. http.ServeContent supplies Range/206,
// Accept-Ranges, Last-Modified and conditional GETs.
func (a *api) asset(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	path, err := a.store.AssetPath(r.PathValue("id"), name)
	if err != nil {
		fail(w, http.StatusBadRequest, "invalid asset name")
		return
	}
	f, err := os.Open(path)
	if err != nil {
		fail(w, http.StatusNotFound, "no such asset")
		return
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil || fi.IsDir() {
		fail(w, http.StatusNotFound, "no such asset")
		return
	}
	// .ply and .bin have no registered MIME type; naming it stops ServeContent
	// from sniffing them as text. The extensionless cover is left to sniff.
	if ext := filepath.Ext(name); ext == ".ply" || ext == ".bin" {
		w.Header().Set("Content-Type", "application/octet-stream")
	}
	w.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, fi.ModTime().UnixNano(), fi.Size()))
	w.Header().Set("Cache-Control", "public, max-age=3600")
	http.ServeContent(w, r, name, fi.ModTime(), f)
}

// upload accepts one complete scan in a single multipart request. All four parts
// are required; a scan missing any of them is not renderable.
//
// This endpoint is deliberately unauthenticated. Everything below is what stands
// between an anonymous caller and the disk: a hard body cap, streamed writes,
// magic-byte checks, a labels/geometry consistency check, and an id that cannot
// address anything outside data/splats.
func (a *api) upload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, a.maxUpload)

	mr, err := r.MultipartReader()
	if err != nil {
		fail(w, http.StatusBadRequest, "expected multipart/form-data")
		return
	}

	tmp, err := os.MkdirTemp(a.store.tmpDir(), "up-")
	if err != nil {
		fail(w, http.StatusInternalServerError, "could not stage upload")
		logf("upload: mkdtemp: %v", err)
		return
	}
	defer os.RemoveAll(tmp)

	var id string
	var meta []byte
	staged := map[string]string{}

	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			failUpload(w, err)
			return
		}
		switch name := part.FormName(); name {
		case "id":
			b, err := io.ReadAll(io.LimitReader(part, 128))
			if err != nil {
				failUpload(w, err)
				return
			}
			id = strings.TrimSpace(string(b))
		case "meta":
			if meta, err = io.ReadAll(io.LimitReader(part, 1<<20)); err != nil {
				failUpload(w, err)
				return
			}
		case "model", "labels", "cover":
			path := filepath.Join(tmp, name)
			if err := writeStream(path, part); err != nil {
				failUpload(w, err)
				return
			}
			staged[name] = path
		default:
			io.Copy(io.Discard, part) // ignore unknown parts, but drain them
		}
		part.Close()
	}

	if !validID(id) {
		fail(w, http.StatusBadRequest, "id must match ^[a-z0-9][a-z0-9-]{0,63}$")
		return
	}
	for _, want := range []string{"model", "labels", "cover"} {
		if staged[want] == "" {
			fail(w, http.StatusBadRequest, "missing required part: "+want)
			return
		}
	}
	if len(meta) == 0 {
		fail(w, http.StatusBadRequest, "missing required part: meta")
		return
	}
	if _, err := parseMeta(meta, id); err != nil {
		fail(w, http.StatusBadRequest, err.Error())
		return
	}

	vertices, err := readPLYVertexCount(staged["model"])
	if err != nil {
		fail(w, http.StatusBadRequest, "model: "+err.Error())
		return
	}
	fi, err := os.Stat(staged["labels"])
	if err != nil {
		fail(w, http.StatusInternalServerError, "could not stat labels")
		return
	}
	if fi.Size() != int64(vertices) {
		fail(w, http.StatusBadRequest, fmt.Sprintf(
			"labels: %d bytes but model has %d vertices (one uint8 per splat)", fi.Size(), vertices))
		return
	}
	if !imageFile(staged["cover"]) {
		fail(w, http.StatusBadRequest, "cover: expected JPEG or PNG")
		return
	}

	switch err := a.store.Create(id, meta, staged["model"], staged["labels"], staged["cover"]); {
	case errors.Is(err, ErrExists):
		fail(w, http.StatusConflict, "scan "+id+" already exists")
	case err != nil:
		fail(w, http.StatusInternalServerError, "could not save scan")
		logf("upload: create %s: %v", id, err)
	default:
		writeJSON(w, http.StatusCreated, map[string]any{"id": id, "assets": assetURLs(id)})
	}
}

func writeStream(path string, r io.Reader) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func readPLYVertexCount(path string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return plyVertexCount(f)
}

func imageFile(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	head := make([]byte, 8)
	n, _ := io.ReadFull(f, head)
	return isImage(head[:n])
}

func failUpload(w http.ResponseWriter, err error) {
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		fail(w, http.StatusRequestEntityTooLarge, "upload exceeds MAX_UPLOAD_BYTES")
		return
	}
	fail(w, http.StatusBadRequest, "malformed multipart body")
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		logf("write json: %v", err)
	}
}

func fail(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
