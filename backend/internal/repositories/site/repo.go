package site

import (
	"context"
	"errors"

	"gorm.io/gorm"

	"coralfull/backend/internal/model"
	apperrors "coralfull/backend/pkg/utils/errors"
)

func (r *siteRepo) Create(ctx context.Context, m *model.Site) (*model.Site, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}

func (r *siteRepo) GetByID(ctx context.Context, id string) (*model.Site, error) {
	var m model.Site
	err := r.dbdget.Get(ctx).Where("id = ?", id).First(&m).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, apperrors.From("DATA_NOT_FOUND").WithMessage("Site not found")
		}
		return nil, err
	}
	return &m, nil
}

func (r *siteRepo) List(ctx context.Context, filter ListFilter) ([]*model.Site, error) {
	var out []*model.Site
	q := r.dbdget.Get(ctx).Model(&model.Site{})
	if filter.State != "" {
		// Bound parameter, never interpolated -- the skeleton's user repo built
		// its status filter and ORDER BY with fmt.Sprintf.
		q = q.Where("state = ?", filter.State)
	}
	if err := q.Order("created_at DESC").Find(&out).Error; err != nil {
		return nil, err
	}
	return out, nil
}

func (r *siteRepo) Update(ctx context.Context, m *model.Site, fields ...string) error {
	q := r.dbdget.Get(ctx).Model(&model.Site{}).Where("id = ?", m.ID)
	if len(fields) > 0 {
		q = q.Select(append(fields, "updated_at"))
	}
	res := q.Updates(m)
	if res.Error != nil {
		return res.Error
	}
	if res.RowsAffected == 0 {
		return apperrors.From("DATA_NOT_FOUND").WithMessage("Site not found")
	}
	return nil
}

func (r *siteRepo) Delete(ctx context.Context, id string) error {
	res := r.dbdget.Get(ctx).Where("id = ?", id).Delete(&model.Site{})
	if res.Error != nil {
		return res.Error
	}
	if res.RowsAffected == 0 {
		return apperrors.From("DATA_NOT_FOUND").WithMessage("Site not found")
	}
	return nil
}
