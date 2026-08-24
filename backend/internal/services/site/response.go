package site

import (
	"time"

	"coralfull/backend/internal/model/enum"
)

// SiteResponse is shaped to decode straight into the clients' existing types:
// UploadedSite in web/lib/types.ts and SiteStore.swift, widened with the
// dashboard fields (priority, tags, coverUrl).
//
// The four local-path fields those types also carry -- sourcePhotoDirectory,
// metashapeProjectPath, meshPlyPath, analysisManifestPath -- are deliberately
// absent. They are absolute paths on whichever laptop ran the pipeline and mean
// nothing here. All four are optional on both clients, so omitting them decodes.
type SiteResponse struct {
	ID         string                `json:"id"`
	Name       string                `json:"name"`
	CreatedAt  time.Time             `json:"createdAt"`
	UpdatedAt  time.Time             `json:"updatedAt"`
	State      enum.SiteStatePayload `json:"state"`
	PhotoCount int                   `json:"photoCount"`
	Priority   enum.Priority         `json:"priority"`
	Tags       []string              `json:"tags"`
	CoverURL   *string               `json:"coverUrl"`
	// AnalysisURL is nil until a manifest has been stored.
	AnalysisURL *string `json:"analysisUrl"`
	FilesBase   string  `json:"filesBase"`
}

type CreateResponse struct {
	Site *SiteResponse `json:"site"`
	// Missing lists every manifest-referenced path not yet uploaded, so a
	// publisher can send exactly those and skip what a previous run stored.
	Missing []string `json:"missing"`
}
