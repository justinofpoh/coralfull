package site_asset

import (
	"context"
	"errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"coralfull/backend/internal/model"
	apperrors "coralfull/backend/pkg/utils/errors"
)

// Upsert makes re-uploading an asset idempotent: publishing is retried by
// re-running it, and an unchanged file must not become a conflict.
func (r *siteAssetRepo) Upsert(ctx context.Context, m *model.SiteAsset) (*model.SiteAsset, error) {
	err := r.dbdget.Get(ctx).Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "site_id"}, {Name: "rel_path"}},
		DoUpdates: clause.AssignmentColumns([]string{"storage_key", "content_type", "bytes", "updated_at"}),
	}).Create(m).Error
	if err != nil {
		return nil, err
	}
	return m, nil
}

func (r *siteAssetRepo) GetByRelPath(ctx context.Context, siteID, relPath string) (*model.SiteAsset, error) {
	var m model.SiteAsset
	err := r.dbdget.Get(ctx).
		Where("site_id = ? AND rel_path = ?", siteID, relPath).
		First(&m).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, apperrors.From("DATA_NOT_FOUND").WithMessage("Asset not found")
		}
		return nil, err
	}
	return &m, nil
}

func (r *siteAssetRepo) ListBySite(ctx context.Context, siteID string) ([]*model.SiteAsset, error) {
	var out []*model.SiteAsset
	err := r.dbdget.Get(ctx).
		Where("site_id = ?", siteID).
		Order("rel_path ASC").
		Find(&out).Error
	return out, err
}

func (r *siteAssetRepo) ListRelPaths(ctx context.Context, siteID string) ([]string, error) {
	var out []string
	err := r.dbdget.Get(ctx).
		Model(&model.SiteAsset{}).
		Where("site_id = ?", siteID).
		Pluck("rel_path", &out).Error
	return out, err
}

func (r *siteAssetRepo) CountByStorageKeyExcludingSite(ctx context.Context, storageKey, siteID string) (int64, error) {
	var n int64
	err := r.dbdget.Get(ctx).
		Model(&model.SiteAsset{}).
		Where("storage_key = ? AND site_id <> ?", storageKey, siteID).
		Count(&n).Error
	return n, err
}
