package site

import (
	"encoding/json"
	"sort"
	"time"
)

// manifestRefs is a deliberately partial view of the AnalysisSequence written by
// tools/process_site.py. Only the fields naming a file are decoded; everything
// else stays opaque jsonb so a pipeline change does not need a migration here.
//
// Field names track SiteAnalysisArtifacts.swift:26-98 and web/lib/types.ts:41-85.
type manifestRefs struct {
	GeneratedAt   *string `json:"generatedAt"`
	SemanticModel *string `json:"semanticModel"`
	DepthProducer *string `json:"depthProducer"`

	Frames []struct {
		RGB      string `json:"rgb"`
		Semantic string `json:"semantic"`
		Depth    string `json:"depth"`
		Mask     string `json:"mask"`
	} `json:"frames"`

	Mesh *struct {
		PLY          *string `json:"ply"`
		Texture      *string `json:"texture"`
		VertexLabels *string `json:"vertexLabels"`
	} `json:"mesh"`
}

// referencedPaths returns every site-relative path the manifest points at,
// deduplicated and sorted. This is the set that must exist before a site can be
// published -- a viewer that 404s halfway through 26 frames is worse than one
// that was never listed.
func referencedPaths(manifest []byte) ([]string, error) {
	var m manifestRefs
	if err := json.Unmarshal(manifest, &m); err != nil {
		return nil, err
	}

	seen := map[string]struct{}{}
	add := func(p string) {
		if p != "" {
			seen[p] = struct{}{}
		}
	}
	addPtr := func(p *string) {
		if p != nil {
			add(*p)
		}
	}

	for _, f := range m.Frames {
		add(f.RGB)
		add(f.Semantic)
		add(f.Depth)
		add(f.Mask)
	}
	if m.Mesh != nil {
		addPtr(m.Mesh.PLY)
		addPtr(m.Mesh.Texture)
		addPtr(m.Mesh.VertexLabels)
	}

	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out, nil
}

// manifestMeta pulls the few scalar columns worth having outside the jsonb, so
// the analyses table can be read without parsing the blob.
func manifestMeta(manifest []byte) (generatedAt *time.Time, semanticModel, depthProducer *string) {
	var m manifestRefs
	if err := json.Unmarshal(manifest, &m); err != nil {
		return nil, nil, nil
	}
	if m.GeneratedAt != nil {
		// The pipeline writes RFC 3339; anything else is simply left null
		// rather than failing a publish over a timestamp.
		if t, err := time.Parse(time.RFC3339, *m.GeneratedAt); err == nil {
			generatedAt = &t
		}
	}
	return generatedAt, m.SemanticModel, m.DepthProducer
}
