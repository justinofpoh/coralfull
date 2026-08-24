package site

import (
	"coralfull/backend/internal/model"
	"coralfull/backend/internal/model/enum"
)

// FilesBase is the URL prefix a client joins a manifest-relative path onto.
// It matches the route web already had at
// web/app/api/sites/[id]/files/[...path]/route.ts, so SiteAnalysisView's
// fileUrl() only needs a new origin, not a new shape.
func FilesBase(siteID string) string {
	return "/api/sites/" + siteID + "/files/"
}

func toResponse(m *model.Site, hasAnalysis bool) *SiteResponse {
	state := enum.SiteStatePayload{Kind: m.State}
	if m.StateMessage != nil {
		state.Message = *m.StateMessage
	}

	tags := []string(m.Tags)
	if tags == nil {
		tags = []string{}
	}

	r := &SiteResponse{
		ID:         m.ID,
		Name:       m.Name,
		CreatedAt:  m.CreatedAt,
		UpdatedAt:  m.UpdatedAt,
		State:      state,
		PhotoCount: m.PhotoCount,
		Priority:   m.Priority,
		Tags:       tags,
		FilesBase:  FilesBase(m.ID),
	}

	if m.CoverPath != nil && *m.CoverPath != "" {
		url := FilesBase(m.ID) + *m.CoverPath
		r.CoverURL = &url
	}
	if hasAnalysis {
		url := "/api/sites/" + m.ID + "/analysis"
		r.AnalysisURL = &url
	}
	return r
}
