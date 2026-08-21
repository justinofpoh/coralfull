package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A scan is a bundle of four files sharing one id prefix:
//
//	<id>.site.json   the record; its presence is what makes the scan exist
//	<id>.ply         geometry
//	<id>.labels.bin  one uint8 class id per splat
//	<id>.cover       cover image, extensionless so ServeContent sniffs the type
const (
	sidecarSuffix = ".site.json"
	modelSuffix   = ".ply"
	labelsSuffix  = ".labels.bin"
	coverSuffix   = ".cover"
)

var (
	ErrNotFound = errors.New("not found")
	ErrExists   = errors.New("already exists")
	ErrInvalid  = errors.New("invalid")
)

type Class struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Color string `json:"color"`
}

// Splat is the persisted record, written verbatim to <id>.site.json.
type Splat struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	Location   string  `json:"location,omitempty"`
	PhotoCount int     `json:"photoCount,omitempty"`
	Priority   string  `json:"priority,omitempty"`
	SplatCount int     `json:"splatCount,omitempty"`
	CapturedAt string  `json:"capturedAt,omitempty"`
	Classes    []Class `json:"classes"`
}

// SplatView is what the API returns: the record plus fields derived from disk.
type SplatView struct {
	Splat
	Bytes     int64             `json:"bytes"`
	UpdatedAt time.Time         `json:"updatedAt"`
	Assets    map[string]string `json:"assets"`
}

// idRe is the whole traversal defence: no dots, no slashes, nothing to escape with.
var idRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

func validID(s string) bool { return idRe.MatchString(s) }

func assetURLs(id string) map[string]string {
	base := "/api/splats/" + id + "/assets/" + id
	return map[string]string{
		"model":  base + modelSuffix,
		"labels": base + labelsSuffix,
		"cover":  base + coverSuffix,
	}
}

type Store struct {
	dir string

	// ponytail: one global write lock. Single-writer service; shard per-id if
	// concurrent uploads ever become a real workload.
	mu sync.Mutex
}

func NewStore(dir string) (*Store, error) {
	s := &Store{dir: dir}
	for _, d := range []string{s.splatsDir(), s.tmpDir()} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, err
		}
	}
	// Drop staging dirs left behind by a crash mid-upload.
	entries, err := os.ReadDir(s.tmpDir())
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		_ = os.RemoveAll(filepath.Join(s.tmpDir(), e.Name()))
	}
	return s, nil
}

func (s *Store) splatsDir() string { return filepath.Join(s.dir, "splats") }
func (s *Store) tmpDir() string    { return filepath.Join(s.dir, "tmp") }

func (s *Store) Get(id string) (*SplatView, error) {
	if !validID(id) {
		return nil, ErrInvalid
	}
	b, err := os.ReadFile(filepath.Join(s.splatsDir(), id+sidecarSuffix))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	var sp Splat
	if err := json.Unmarshal(b, &sp); err != nil {
		return nil, fmt.Errorf("%s%s: %w", id, sidecarSuffix, err)
	}
	sp.ID = id // the filename is authoritative, not the field

	v := &SplatView{Splat: sp, Assets: assetURLs(id)}
	if fi, err := os.Stat(filepath.Join(s.splatsDir(), id+modelSuffix)); err == nil {
		v.Bytes, v.UpdatedAt = fi.Size(), fi.ModTime()
	}
	return v, nil
}

// List rescans the directory on every call.
// ponytail: a ReadDir + N small reads is microseconds for a handful of scans.
// Cache on the directory mtime if this ever holds ~1k+ scans.
func (s *Store) List() ([]*SplatView, error) {
	entries, err := os.ReadDir(s.splatsDir())
	if err != nil {
		return nil, err
	}
	out := make([]*SplatView, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), sidecarSuffix) {
			continue
		}
		id := strings.TrimSuffix(e.Name(), sidecarSuffix)
		v, err := s.Get(id)
		if err != nil {
			// One unreadable sidecar must not blank the whole index.
			logf("skipping %s: %v", e.Name(), err)
			continue
		}
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// AssetPath resolves a requested asset name to a path inside the splats dir.
// Two independent checks: the name must be a bare filename, and it must belong
// to this scan. Either alone would be enough; both is cheap.
func (s *Store) AssetPath(id, name string) (string, error) {
	if !validID(id) {
		return "", ErrInvalid
	}
	if name == "" || filepath.Base(name) != name {
		return "", ErrInvalid
	}
	if !strings.HasPrefix(name, id+".") {
		return "", ErrInvalid
	}
	return filepath.Join(s.splatsDir(), name), nil
}

// Create moves a validated upload staged in tmpDir into place.
// tmp and splats share a filesystem, so the renames are cheap and atomic.
func (s *Store) Create(id string, meta []byte, model, labels, cover string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sidecar := filepath.Join(s.splatsDir(), id+sidecarSuffix)
	if _, err := os.Stat(sidecar); err == nil {
		return ErrExists
	} else if !os.IsNotExist(err) {
		return err
	}

	// ponytail: near-atomic via rename-last, not a transaction. A crash between
	// renames leaves orphan asset files with no sidecar, so the scan stays
	// invisible to List and a retry overwrites them.
	moves := []struct{ from, to string }{
		{model, filepath.Join(s.splatsDir(), id+modelSuffix)},
		{labels, filepath.Join(s.splatsDir(), id+labelsSuffix)},
		{cover, filepath.Join(s.splatsDir(), id+coverSuffix)},
	}
	for _, m := range moves {
		if err := os.Rename(m.from, m.to); err != nil {
			return err
		}
	}
	return os.WriteFile(sidecar, meta, 0o644)
}

// parseMeta validates the uploaded metadata part. labels.bin is a bare array of
// uint8, so a record without classes is unrenderable.
func parseMeta(b []byte, id string) (*Splat, error) {
	var sp Splat
	if err := json.Unmarshal(b, &sp); err != nil {
		return nil, fmt.Errorf("meta: %w", err)
	}
	if strings.TrimSpace(sp.Name) == "" {
		return nil, errors.New("meta: name is required")
	}
	if len(sp.Classes) == 0 {
		return nil, errors.New("meta: classes is required")
	}
	sp.ID = id
	return &sp, nil
}

// plyVertexCount reads the ASCII header that both ascii and binary PLYs carry.
// Doubles as the magic-byte check, and its result is what proves a labels.bin
// belongs to this model rather than some other scan.
func plyVertexCount(r io.Reader) (int, error) {
	br := bufio.NewReader(io.LimitReader(r, 64<<10))
	line, err := br.ReadString('\n')
	if err != nil || strings.TrimSpace(line) != "ply" {
		return 0, errors.New("not a PLY file")
	}
	n := -1
	for {
		line, err = br.ReadString('\n')
		if err != nil {
			return 0, errors.New("PLY: header has no end_header")
		}
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if len(f) == 3 && f[0] == "element" && f[1] == "vertex" {
			if n, err = strconv.Atoi(f[2]); err != nil {
				return 0, fmt.Errorf("PLY: bad vertex count %q", f[2])
			}
		}
		if f[0] == "end_header" {
			if n < 0 {
				return 0, errors.New("PLY: no vertex element")
			}
			return n, nil
		}
	}
}

func isImage(b []byte) bool {
	switch {
	case len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF: // JPEG
		return true
	case len(b) >= 8 && string(b[:8]) == "\x89PNG\r\n\x1a\n": // PNG
		return true
	}
	return false
}
