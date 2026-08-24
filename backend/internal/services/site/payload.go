package site

import (
	"encoding/json"

	"coralfull/backend/internal/model/enum"
)

type CreatePayload struct {
	Name       string   `json:"name" validate:"required,min=1,max=200"`
	Priority   string   `json:"priority" validate:"omitempty,oneof=high medium low"`
	PhotoCount int      `json:"photoCount" validate:"min=0"`
	Tags       []string `json:"tags" validate:"omitempty,dive,max=64"`
	// CoverPath is a site-relative path like "cover.jpg"; it is validated as one
	// and must be uploaded like any other asset before publishing.
	CoverPath string `json:"coverPath" validate:"omitempty"`
	// State defaults to importing so a site row can exist while the local
	// pipeline is still running.
	State *enum.SiteStatePayload `json:"state"`
	// Manifest is the AnalysisSequence, optional at create time.
	Manifest json.RawMessage `json:"manifest"`
}

type PatchPayload struct {
	Name       *string                `json:"name" validate:"omitempty,min=1,max=200"`
	Priority   *string                `json:"priority" validate:"omitempty,oneof=high medium low"`
	PhotoCount *int                   `json:"photoCount" validate:"omitempty,min=0"`
	Tags       *[]string              `json:"tags" validate:"omitempty,dive,max=64"`
	CoverPath  *string                `json:"coverPath"`
	State      *enum.SiteStatePayload `json:"state"`
	Manifest   json.RawMessage        `json:"manifest"`
}
