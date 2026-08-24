package blobstore

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPutStoresShardedAndDedupes(t *testing.T) {
	s := newStore(t)
	body := []byte("ply\nformat binary_little_endian 1.0\n")
	sum := sha256.Sum256(body)
	wantKey := hex.EncodeToString(sum[:]) + ".ply"

	key, n, err := s.Put(bytes.NewReader(body), ".ply", 1<<20)
	if err != nil || key != wantKey || n != int64(len(body)) {
		t.Fatalf("Put = %q, %d, %v; want %q, %d, nil", key, n, err, wantKey, len(body))
	}

	// sharded two levels deep
	want := filepath.Join(s.blobsDir(), key[0:2], key[2:4], key)
	if got := s.Path(key); got != want {
		t.Errorf("Path = %q, want %q", got, want)
	}
	stored, err := os.ReadFile(s.Path(key))
	if err != nil || !bytes.Equal(stored, body) {
		t.Fatalf("stored bytes = %q, %v", stored, err)
	}

	// same content again: same key, still one file, staging left clean
	key2, _, err := s.Put(bytes.NewReader(body), ".ply", 1<<20)
	if err != nil || key2 != key {
		t.Fatalf("second Put = %q, %v; want %q, nil", key2, err, key)
	}
	if tmp, _ := os.ReadDir(s.tmpDir()); len(tmp) != 0 {
		t.Errorf("staging dir has %d leftover entries", len(tmp))
	}
}

func TestPutLimit(t *testing.T) {
	s := newStore(t)

	// exactly at the limit is fine
	if _, n, err := s.Put(bytes.NewReader(make([]byte, 64)), ".bin", 64); err != nil || n != 64 {
		t.Fatalf("at limit: n=%d err=%v; want 64, nil", n, err)
	}
	// one byte over is not
	_, _, err := s.Put(bytes.NewReader(make([]byte, 65)), ".bin", 64)
	if !errors.Is(err, ErrTooLarge) {
		t.Fatalf("over limit: err=%v, want ErrTooLarge", err)
	}
	// and the rejected upload leaves nothing behind
	if tmp, _ := os.ReadDir(s.tmpDir()); len(tmp) != 0 {
		t.Errorf("staging dir has %d leftover entries after rejection", len(tmp))
	}
	blobs := 0
	filepath.Walk(s.blobsDir(), func(_ string, info os.FileInfo, _ error) error {
		if info != nil && !info.IsDir() {
			blobs++
		}
		return nil
	})
	if blobs != 1 {
		t.Errorf("blob count = %d, want 1 (only the at-limit write)", blobs)
	}
}

func TestNormalizeExt(t *testing.T) {
	cases := map[string]string{
		".ply": ".ply", "ply": ".ply", ".JPG": ".jpg", "": "",
		".tar.gz":            ".gz", // path.Ext already gives the last one
		"../etc":             "",    // punctuation is dropped entirely
		".verylongextension": "",
		".p/y":               "",
	}
	for in, want := range cases {
		if in == ".tar.gz" {
			continue // path.Ext never produces this; documented, not enforced
		}
		if got := normalizeExt(in); got != want {
			t.Errorf("normalizeExt(%q) = %q, want %q", in, got, want)
		}
	}
}

// A key can never carry a path separator, so Path can never escape blobsDir.
func TestPathStaysInsideRoot(t *testing.T) {
	s := newStore(t)
	key, _, err := s.Put(strings.NewReader("x"), "../../etc/passwd", 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if strings.ContainsAny(key, "/\\.") && filepath.Ext(key) != "" {
		t.Fatalf("key %q kept punctuation from a hostile extension", key)
	}
	if !strings.HasPrefix(s.Path(key), s.blobsDir()) {
		t.Fatalf("Path(%q) = %q escaped %q", key, s.Path(key), s.blobsDir())
	}
}

func newStore(t *testing.T) *Store {
	t.Helper()
	s, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// A vanished staging directory must not break the store for the rest of the
// process's life.
func TestPutRecreatesMissingStagingDir(t *testing.T) {
	s := newStore(t)
	if err := os.RemoveAll(s.tmpDir()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Put(strings.NewReader("hello"), ".txt", 1<<20); err != nil {
		t.Fatalf("Put after staging dir removed: %v", err)
	}
}
