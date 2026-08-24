package model

import "time"

type SiteAsset struct {
	ID          string    `gorm:"column:id;primarykey;default:gen_random_uuid()"`
	SiteID      string    `gorm:"column:site_id"`
	RelPath     string    `gorm:"column:rel_path"`
	StorageKey  string    `gorm:"column:storage_key"`
	ContentType string    `gorm:"column:content_type"`
	Bytes       int64     `gorm:"column:bytes"`
	CreatedAt   time.Time `gorm:"column:created_at"`
	UpdatedAt   time.Time `gorm:"column:updated_at"`
}

func (SiteAsset) TableName() string { return "site_assets" }
