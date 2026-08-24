package relpath

import (
	"strings"
	"testing"
)

func TestValidate(t *testing.T) {
	valid := []string{
		"cover.jpg",
		"site_b_sequence.json",
		"site_b_frames/TIMELAPSE_0119_rgb.jpg",
		"analysis/frames/a/b/c/d.png",
		"a-b_c.1.ply",
	}
	for _, p := range valid {
		if err := Validate(p); err != nil {
			t.Errorf("Validate(%q) = %v, want nil", p, err)
		}
	}

	invalid := map[string]error{
		"":                       ErrEmpty,
		"/etc/passwd":            ErrAbsolute,
		"..":                     ErrTraversal,
		"../secrets":             ErrTraversal,
		"a/../../b":              ErrTraversal,
		"frames/../../../etc/pw": ErrTraversal,
		"./cover.jpg":            ErrNotClean,
		"a//b":                   ErrNotClean,
		"frames/":                ErrNotClean,
		"a/b/.":                  ErrNotClean,
		`frames\rgb.jpg`:         ErrCharacter,
		"cover\x00.jpg":          ErrCharacter,
		"a/b/c/d/e/f/g/h/i":      ErrTooDeep,
		strings.Repeat("a", 513): ErrTooLong,
	}
	for p, want := range invalid {
		if got := Validate(p); got != want {
			t.Errorf("Validate(%q) = %v, want %v", p, got, want)
		}
	}
}

// A decoded %2e%2e%2f arrives as "../" -- the same input the table above covers,
// but worth pinning since that is the shape an attacker actually sends.
func TestValidateRejectsDecodedEscapes(t *testing.T) {
	for _, p := range []string{"../../go.mod", "frames/../../../../etc/passwd"} {
		if err := Validate(p); err == nil {
			t.Errorf("Validate(%q) = nil, want an error", p)
		}
	}
}
