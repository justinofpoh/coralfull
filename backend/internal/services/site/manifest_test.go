package site

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestReferencedPaths(t *testing.T) {
	manifest := []byte(`{
	  "site": "Site B",
	  "generatedAt": "2026-08-18T04:05:06Z",
	  "semanticModel": "coralscapes-vit-b-dpt",
	  "depthProducer": "metashape",
	  "frames": [
	    {"rgb":"f/a_rgb.jpg","semantic":"f/a_semantic.jpg","depth":"f/a_depth.png","mask":"f/a_mask.png"},
	    {"rgb":"f/b_rgb.jpg","semantic":"f/b_semantic.jpg","depth":"f/b_depth.png","mask":""}
	  ],
	  "mesh": {"ply":"mesh.ply","texture":"mesh.jpg","vertexLabels":null,"vertices":123}
	}`)

	got, err := referencedPaths(manifest)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"f/a_depth.png", "f/a_mask.png", "f/a_rgb.jpg", "f/a_semantic.jpg",
		"f/b_depth.png", "f/b_rgb.jpg", "f/b_semantic.jpg",
		"mesh.jpg", "mesh.ply",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("referencedPaths =\n  %q\nwant\n  %q", got, want)
	}
}

func TestReferencedPathsToleratesSparseManifests(t *testing.T) {
	// mesh: null is what site_b_sequence.json actually ships today.
	for _, m := range []string{`{}`, `{"frames":[]}`, `{"frames":[],"mesh":null}`} {
		got, err := referencedPaths([]byte(m))
		if err != nil || len(got) != 0 {
			t.Errorf("referencedPaths(%s) = %q, %v; want empty, nil", m, got, err)
		}
	}
	if _, err := referencedPaths([]byte(`not json`)); err == nil {
		t.Error("referencedPaths on invalid JSON = nil error, want an error")
	}
}

func TestManifestMeta(t *testing.T) {
	generatedAt, model, depth := manifestMeta([]byte(
		`{"generatedAt":"2026-08-18T04:05:06Z","semanticModel":"m","depthProducer":"d"}`))
	if generatedAt == nil || generatedAt.Year() != 2026 {
		t.Errorf("generatedAt = %v", generatedAt)
	}
	if model == nil || *model != "m" || depth == nil || *depth != "d" {
		t.Errorf("model=%v depth=%v", model, depth)
	}

	// A malformed timestamp must not fail a publish over a metadata column.
	generatedAt, _, _ = manifestMeta([]byte(`{"generatedAt":"last tuesday"}`))
	if generatedAt != nil {
		t.Errorf("generatedAt = %v, want nil for an unparseable date", generatedAt)
	}
}

// The real manifest shipped in the macOS bundle is the contract this service
// has to survive. If the pipeline's format drifts, this is where it shows.
func TestReferencedPathsOnRealManifest(t *testing.T) {
	path := filepath.Join("..", "..", "..", "..",
		"macos", "coralfull", "coralfull", "ReefViewer", "site_b_sequence.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("bundled manifest not present: %v", err)
	}

	paths, err := referencedPaths(raw)
	if err != nil {
		t.Fatalf("real manifest failed to parse: %v", err)
	}

	var counted struct {
		Frames []json.RawMessage `json:"frames"`
	}
	if err := json.Unmarshal(raw, &counted); err != nil {
		t.Fatal(err)
	}
	// 26 frames x rgb/semantic/depth/mask, all distinct.
	if want := len(counted.Frames) * 4; len(paths) != want {
		t.Errorf("referencedPaths returned %d paths for %d frames, want %d",
			len(paths), len(counted.Frames), want)
	}
	for _, p := range paths {
		if p == "" || filepath.IsAbs(p) {
			t.Errorf("manifest referenced a bad path: %q", p)
		}
	}
}
