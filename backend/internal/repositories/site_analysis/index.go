package site_analysis

import (
	"context"

	"coralfull/backend/internal/model"
	"coralfull/backend/pkg/clients/db"
)

type SiteAnalysisRepo interface {
	Upsert(ctx context.Context, m *model.SiteAnalysis) (*model.SiteAnalysis, error)
	GetBySiteID(ctx context.Context, siteID string) (*model.SiteAnalysis, error)
}

type siteAnalysisRepo struct {
	dbdget db.DBGormDelegate
}

func NewSiteAnalysisRepo(dbdget db.DBGormDelegate) SiteAnalysisRepo {
	return &siteAnalysisRepo{dbdget: dbdget}
}
