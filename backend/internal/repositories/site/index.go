package site

import (
	"context"

	"coralfull/backend/internal/model"
	"coralfull/backend/pkg/clients/db"
)

type SiteRepo interface {
	Create(ctx context.Context, m *model.Site) (*model.Site, error)
	GetByID(ctx context.Context, id string) (*model.Site, error)
	List(ctx context.Context, filter ListFilter) ([]*model.Site, error)
	Update(ctx context.Context, m *model.Site, fields ...string) error
	Delete(ctx context.Context, id string) error
}

// ListFilter is empty of pagination on purpose: a reef survey has tens of
// sites, not thousands, and both dashboards render the whole list at once.
type ListFilter struct {
	State string
}

type siteRepo struct {
	dbdget db.DBGormDelegate
}

func NewSiteRepo(dbdget db.DBGormDelegate) SiteRepo { return &siteRepo{dbdget: dbdget} }
