package model

import (
	"time"

	"coralfull/backend/internal/model/custom_type"
)

type SiteAnalysis struct {
	SiteID        string            `gorm:"column:site_id;primarykey"`
	Manifest      custom_type.JSONB `gorm:"column:manifest;type:jsonb"`
	GeneratedAt   *time.Time        `gorm:"column:generated_at"`
	SemanticModel *string           `gorm:"column:semantic_model"`
	DepthProducer *string           `gorm:"column:depth_producer"`
	CreatedAt     time.Time         `gorm:"column:created_at"`
	UpdatedAt     time.Time         `gorm:"column:updated_at"`
}

func (SiteAnalysis) TableName() string { return "site_analyses" }
