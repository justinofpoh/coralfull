package model

import (
	"time"

	"github.com/lib/pq"

	"coralfull/backend/internal/model/enum"
)

type Site struct {
	ID           string         `gorm:"column:id;primarykey;default:gen_random_uuid()"`
	Name         string         `gorm:"column:name"`
	Priority     enum.Priority  `gorm:"column:priority"`
	State        enum.SiteState `gorm:"column:state"`
	StateMessage *string        `gorm:"column:state_message"`
	PhotoCount   int            `gorm:"column:photo_count"`
	Tags         pq.StringArray `gorm:"column:tags;type:text[]"`
	CoverPath    *string        `gorm:"column:cover_path"`
	CreatedAt    time.Time      `gorm:"column:created_at"`
	UpdatedAt    time.Time      `gorm:"column:updated_at"`
}

func (Site) TableName() string { return "sites" }
