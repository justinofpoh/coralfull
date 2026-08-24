package asset

import "testing"

func TestContentType(t *testing.T) {
	cases := []struct {
		declared, ext, want string
	}{
		// The extension wins over whatever the client declared. curl
		// --data-binary sends x-www-form-urlencoded; trusting it stored every
		// artifact under that type once.
		{"application/x-www-form-urlencoded", ".jpg", "image/jpeg"},
		{"application/x-www-form-urlencoded", ".ply", "application/octet-stream"},
		{"text/html", ".png", "image/png"},
		{"", ".json", "application/json"},

		// Types with no registered MIME are named rather than sniffed.
		{"", ".ply", "application/octet-stream"},
		{"", ".bin", "application/octet-stream"},
		{"", ".spz", "application/octet-stream"},

		// A declared type is only consulted when the extension says nothing.
		{"image/webp", "", "image/webp"},
		{"image/webp; charset=utf-8", "", "image/webp"},
		{"application/x-www-form-urlencoded", "", "application/octet-stream"},
		{"", "", "application/octet-stream"},
		{"nonsense///", "", "application/octet-stream"},
	}
	for _, c := range cases {
		if got := contentType(c.declared, c.ext); got != c.want {
			t.Errorf("contentType(%q, %q) = %q, want %q", c.declared, c.ext, got, c.want)
		}
	}
}
