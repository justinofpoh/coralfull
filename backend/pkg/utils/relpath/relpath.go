// Package relpath validates site-relative asset paths supplied by clients.
//
// These strings come straight out of the analysis manifest ("site_b_frames/
// TIMELAPSE_0119_rgb.jpg") and are used as a database lookup key. They are never
// joined onto a filesystem path -- the blob a request resolves to is addressed
// by content hash -- but a bad one still must not reach the store, so the whole
// vocabulary is pinned down here in one place.
package relpath

import (
	"errors"
	"path"
	"strings"
)

const (
	// MaxLen bounds the whole path. Longest real one today is ~45 characters.
	MaxLen = 512
	// MaxDepth bounds nesting. Real manifests use one directory level.
	MaxDepth = 8
)

var (
	ErrEmpty     = errors.New("path is empty")
	ErrTooLong   = errors.New("path is too long")
	ErrTooDeep   = errors.New("path has too many segments")
	ErrAbsolute  = errors.New("path must be relative")
	ErrNotClean  = errors.New("path must be in cleaned form")
	ErrTraversal = errors.New("path must not contain a .. segment")
	ErrCharacter = errors.New("path contains a forbidden character")
)

// Validate reports whether p is acceptable as a site-relative asset path.
func Validate(p string) error {
	switch {
	case p == "":
		return ErrEmpty
	case len(p) > MaxLen:
		return ErrTooLong
	case strings.ContainsRune(p, 0):
		return ErrCharacter
	case strings.ContainsRune(p, '\\'):
		// Backslash is a separator on Windows and a literal here; refusing it
		// keeps one path from meaning two things.
		return ErrCharacter
	case strings.HasPrefix(p, "/"):
		return ErrAbsolute
	}

	segments := strings.Split(p, "/")
	if len(segments) > MaxDepth {
		return ErrTooDeep
	}
	for _, s := range segments {
		switch s {
		case "":
			return ErrNotClean // empty segment: "a//b" or a trailing slash
		case ".":
			return ErrNotClean
		case "..":
			return ErrTraversal
		}
	}

	// Belt and braces: anything the loop missed must survive a round trip.
	if path.Clean(p) != p {
		return ErrNotClean
	}
	return nil
}
