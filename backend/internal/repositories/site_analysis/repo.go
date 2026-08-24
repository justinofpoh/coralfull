package site_analysis

import (
	"context"
	"errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"coralfull/backend/internal/model"
	apperrors "coralfull/backend/pkg/utils/errors"
)

func (r *siteAnalysisRepo) Upsert(ctx context.Context, m *model.SiteAnalysis) (*model.SiteAnalysis, error) {
	err := r.dbdget.Get(ctx).Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "site_id"}},
		DoUpdates: clause.AssignmentColumns([]string{"manifest", "generated_at", "semantic_model", "depth_producer", "updated_at"}),
	}).Create(m).Error
	if err != nil {
		return nil, err
	}
	return m, nil
}

func (r *siteAnalysisRepo) GetBySiteID(ctx context.Context, siteID string) (*model.SiteAnalysis, error) {
	var m model.SiteAnalysis
	err := r.dbdget.Get(ctx).Where("site_id = ?", siteID).First(&m).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, apperrors.From("DATA_NOT_FOUND").WithMessage("Site has no analysis manifest")
		}
		return nil, err
	}
	return &m, nil
}
