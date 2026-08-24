package site_asset

import (
	"context"

	"coralfull/backend/internal/model"
	"coralfull/backend/pkg/clients/db"
)

type SiteAssetRepo interface {
	Upsert(ctx context.Context, m *model.SiteAsset) (*model.SiteAsset, error)
	GetByRelPath(ctx context.Context, siteID, relPath string) (*model.SiteAsset, error)
	ListBySite(ctx context.Context, siteID string) ([]*model.SiteAsset, error)
	ListRelPaths(ctx context.Context, siteID string) ([]string, error)
	// CountByStorageKeyExcludingSite reports how many other sites still
	// reference a blob, so an unlink can be decided safely.
	CountByStorageKeyExcludingSite(ctx context.Context, storageKey, siteID string) (int64, error)
}

type siteAssetRepo struct {
	dbdget db.DBGormDelegate
}

func NewSiteAssetRepo(dbdget db.DBGormDelegate) SiteAssetRepo {
	return &siteAssetRepo{dbdget: dbdget}
}
