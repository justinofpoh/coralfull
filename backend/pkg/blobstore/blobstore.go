// Package blobstore is a content-addressed file store on the local filesystem.
//
// A blob is named by the SHA-256 of its contents plus the extension of the path
// it arrived as, and is sharded two levels deep so no directory grows unbounded:
//
//	data/blobs/ab/cd/abcd...ef.ply
//
// Content addressing buys three things this service depends on. Uploading the
// same bytes twice is free, so a publish that died halfway can simply be re-run.
// The key doubles as a strong ETag. And blobs are immutable, which is why
// Fiber's hardcoded ten-second file cache and its missing If-Range support are
// both harmless here -- a given key's bytes never change.
package blobstore

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// ErrTooLarge is returned when a reader supplies more than the given limit.
var ErrTooLarge = errors.New("blobstore: content exceeds limit")

type Store struct {
	root string
}

// New prepares the blob and staging directories under root.
func New(root string) (*Store, error) {
	s := &Store{root: root}
	for _, d := range []string{s.blobsDir(), s.tmpDir()} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, err
		}
	}
	// Drop staging files left behind by a crash mid-upload.
	entries, err := os.ReadDir(s.tmpDir())
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		_ = os.RemoveAll(filepath.Join(s.tmpDir(), e.Name()))
	}
	return s, nil
}

func (s *Store) blobsDir() string { return filepath.Join(s.root, "blobs") }
func (s *Store) tmpDir() string   { return filepath.Join(s.root, "tmp") }

// Put streams r to disk, hashing as it copies, and returns the storage key.
//
// At most limit bytes are accepted; one byte beyond that is an ErrTooLarge, so
// a body exactly at the limit still succeeds. The caller must enforce its own
// cap on the reader too when the transport does not -- see the note about
// Fiber's BodyLimit in the asset handler.
func (s *Store) Put(r io.Reader, ext string, limit int64) (key string, n int64, err error) {
	tmp, err := os.CreateTemp(s.tmpDir(), "put-")
	if os.IsNotExist(err) {
		// The staging directory can go missing between New and here -- a tmp
		// reaper, an operator clearing disk. Recreate rather than failing every
		// upload until the process restarts.
		if mkErr := os.MkdirAll(s.tmpDir(), 0o755); mkErr != nil {
			return "", 0, mkErr
		}
		tmp, err = os.CreateTemp(s.tmpDir(), "put-")
	}
	if err != nil {
		return "", 0, err
	}
	tmpName := tmp.Name()
	defer func() {
		tmp.Close()
		// Removing a file already renamed away is a harmless no-op.
		os.Remove(tmpName)
	}()

	h := sha256.New()
	n, err = io.Copy(io.MultiWriter(tmp, h), io.LimitReader(r, limit+1))
	if err != nil {
		return "", 0, err
	}
	if n > limit {
		return "", n, ErrTooLarge
	}
	if err := tmp.Close(); err != nil {
		return "", n, err
	}

	key = hex.EncodeToString(h.Sum(nil)) + normalizeExt(ext)
	dst := s.Path(key)
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", n, err
	}
	if _, err := os.Stat(dst); err == nil {
		return key, n, nil // already stored; identical bytes by construction
	} else if !os.IsNotExist(err) {
		return "", n, err
	}
	if err := os.Rename(tmpName, dst); err != nil {
		return "", n, err
	}
	return key, n, nil
}

// Path is the absolute location of a blob. It is derived entirely from the key,
// which is generated here and never taken from a request.
func (s *Store) Path(key string) string {
	if len(key) < 4 {
		return filepath.Join(s.blobsDir(), key)
	}
	return filepath.Join(s.blobsDir(), key[0:2], key[2:4], key)
}

func (s *Store) Exists(key string) bool {
	_, err := os.Stat(s.Path(key))
	return err == nil
}

// Remove deletes a blob. Callers must have checked that nothing references it.
func (s *Store) Remove(key string) error {
	err := os.Remove(s.Path(key))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// normalizeExt keeps the extension usable as part of a filename and lets the
// file server derive a Content-Type from it.
func normalizeExt(ext string) string {
	if ext == "" {
		return ""
	}
	if !strings.HasPrefix(ext, ".") {
		ext = "." + ext
	}
	if len(ext) > 16 {
		return ""
	}
	for _, r := range ext[1:] {
		isAlnum := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
		if !isAlnum {
			return ""
		}
	}
	return strings.ToLower(ext)
}

// KeyFor is exported for tests and tooling that need the key without storing.
func KeyFor(sum []byte, ext string) string {
	return fmt.Sprintf("%s%s", hex.EncodeToString(sum), normalizeExt(ext))
}
