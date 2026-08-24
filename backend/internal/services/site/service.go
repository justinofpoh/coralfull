package site

import (
	"context"
	"encoding/json"

	"coralfull/backend/internal/model"
	"coralfull/backend/internal/model/enum"
	reposSite "coralfull/backend/internal/repositories/site"
	apperrors "coralfull/backend/pkg/utils/errors"
	"coralfull/backend/pkg/utils/relpath"
)

func (s *siteService) Create(ctx context.Context, p CreatePayload) (*CreateResponse, error) {
	if p.CoverPath != "" {
		if err := relpath.Validate(p.CoverPath); err != nil {
			return nil, apperrors.From("INVALID_ASSET_PATH").
				WithDetail("coverPath: " + err.Error())
		}
	}
	if len(p.Manifest) > 0 && !json.Valid(p.Manifest) {
		return nil, apperrors.From("BAD_REQUEST").WithDetail("manifest is not valid JSON")
	}

	priority := enum.Priority(p.Priority)
	if priority == "" {
		priority = enum.PriorityMedium
	}
	state := enum.StateImporting
	var stateMessage *string
	if p.State != nil {
		state = p.State.Kind
		if p.State.Message != "" {
			msg := p.State.Message
			stateMessage = &msg
		}
	}

	// tags is NOT NULL with a '{}' default, but gorm writes an explicit NULL for
	// a nil slice rather than omitting the column, so the default never applies.
	tags := p.Tags
	if tags == nil {
		tags = []string{}
	}

	m := &model.Site{
		Name:         p.Name,
		Priority:     priority,
		State:        state,
		StateMessage: stateMessage,
		PhotoCount:   p.PhotoCount,
		Tags:         tags,
	}
	if p.CoverPath != "" {
		cover := p.CoverPath
		m.CoverPath = &cover
	}

	var missing []string
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		created, err := s.siteRepo.Create(ctx, m)
		if err != nil {
			return err
		}
		m = created

		if len(p.Manifest) == 0 {
			return nil
		}
		if err := s.storeManifest(ctx, m.ID, p.Manifest); err != nil {
			return err
		}
		missing, err = s.missingFor(ctx, m, p.Manifest)
		return err
	})
	if err != nil {
		return nil, err
	}

	if missing == nil {
		missing = []string{}
	}
	return &CreateResponse{Site: toResponse(m, len(p.Manifest) > 0), Missing: missing}, nil
}

func (s *siteService) GetByID(ctx context.Context, id string) (*SiteResponse, error) {
	m, err := s.siteRepo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	return toResponse(m, s.hasAnalysis(ctx, id)), nil
}

func (s *siteService) List(ctx context.Context) ([]*SiteResponse, error) {
	sites, err := s.siteRepo.List(ctx, reposSite.ListFilter{})
	if err != nil {
		return nil, err
	}
	out := make([]*SiteResponse, 0, len(sites))
	for _, m := range sites {
		out = append(out, toResponse(m, s.hasAnalysis(ctx, m.ID)))
	}
	return out, nil
}

func (s *siteService) Patch(ctx context.Context, id string, p PatchPayload) (*SiteResponse, error) {
	if p.CoverPath != nil && *p.CoverPath != "" {
		if err := relpath.Validate(*p.CoverPath); err != nil {
			return nil, apperrors.From("INVALID_ASSET_PATH").
				WithDetail("coverPath: " + err.Error())
		}
	}
	if len(p.Manifest) > 0 && !json.Valid(p.Manifest) {
		return nil, apperrors.From("BAD_REQUEST").WithDetail("manifest is not valid JSON")
	}

	var out *model.Site
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		m, err := s.siteRepo.GetByID(ctx, id)
		if err != nil {
			return err
		}

		var fields []string
		if p.Name != nil {
			m.Name = *p.Name
			fields = append(fields, "name")
		}
		if p.Priority != nil {
			m.Priority = enum.Priority(*p.Priority)
			fields = append(fields, "priority")
		}
		if p.PhotoCount != nil {
			m.PhotoCount = *p.PhotoCount
			fields = append(fields, "photo_count")
		}
		if p.Tags != nil {
			tags := *p.Tags
			if tags == nil {
				tags = []string{}
			}
			m.Tags = tags
			fields = append(fields, "tags")
		}
		if p.CoverPath != nil {
			cover := *p.CoverPath
			m.CoverPath = &cover
			fields = append(fields, "cover_path")
		}
		if p.State != nil {
			m.State = p.State.Kind
			msg := p.State.Message
			m.StateMessage = &msg
			fields = append(fields, "state", "state_message")
		}

		if len(fields) > 0 {
			if err := s.siteRepo.Update(ctx, m, fields...); err != nil {
				return err
			}
		}
		if len(p.Manifest) > 0 {
			if err := s.storeManifest(ctx, id, p.Manifest); err != nil {
				return err
			}
		}
		out = m
		return nil
	})
	if err != nil {
		return nil, err
	}
	return toResponse(out, s.hasAnalysis(ctx, id)), nil
}

// Delete removes the site and, for each of its assets, unlinks the blob when no
// other site still references it. A blob left behind is invisible and reclaimable;
// one deleted too early would break a different site, so the check is not optional.
func (s *siteService) Delete(ctx context.Context, id string) error {
	var orphans []string
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		assets, err := s.assetRepo.ListBySite(ctx, id)
		if err != nil {
			return err
		}
		for _, a := range assets {
			n, err := s.assetRepo.CountByStorageKeyExcludingSite(ctx, a.StorageKey, id)
			if err != nil {
				return err
			}
			if n == 0 {
				orphans = append(orphans, a.StorageKey)
			}
		}
		return s.siteRepo.Delete(ctx, id)
	})
	if err != nil {
		return err
	}

	// After the commit: a failed unlink leaves a harmless orphan, whereas
	// unlinking inside the transaction would lose the bytes on a rollback.
	for _, key := range orphans {
		_ = s.blobs.Remove(key)
	}
	return nil
}

func (s *siteService) Analysis(ctx context.Context, id string) ([]byte, error) {
	if _, err := s.siteRepo.GetByID(ctx, id); err != nil {
		return nil, err
	}
	a, err := s.analysisRepo.GetBySiteID(ctx, id)
	if err != nil {
		return nil, err
	}
	return a.Manifest, nil
}

func (s *siteService) MissingAssets(ctx context.Context, id string) ([]string, error) {
	m, err := s.siteRepo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	a, err := s.analysisRepo.GetBySiteID(ctx, id)
	if err != nil {
		return nil, err
	}
	return s.missingFor(ctx, m, a.Manifest)
}

// Publish flips a site to ready, but only once every file its manifest names has
// actually been uploaded.
func (s *siteService) Publish(ctx context.Context, id string) (*SiteResponse, error) {
	var out *model.Site
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		m, err := s.siteRepo.GetByID(ctx, id)
		if err != nil {
			return err
		}
		a, err := s.analysisRepo.GetBySiteID(ctx, id)
		if err != nil {
			if apperrors.Is(err, "DATA_NOT_FOUND") {
				return apperrors.From("SITE_NO_MANIFEST")
			}
			return err
		}

		missing, err := s.missingFor(ctx, m, a.Manifest)
		if err != nil {
			return err
		}
		if len(missing) > 0 {
			return apperrors.From("SITE_INCOMPLETE").WithDetails(missing)
		}

		m.State = enum.StateReady
		empty := ""
		m.StateMessage = &empty
		if err := s.siteRepo.Update(ctx, m, "state", "state_message"); err != nil {
			return err
		}
		out = m
		return nil
	})
	if err != nil {
		return nil, err
	}
	return toResponse(out, true), nil
}

func (s *siteService) storeManifest(ctx context.Context, siteID string, manifest []byte) error {
	generatedAt, semanticModel, depthProducer := manifestMeta(manifest)
	_, err := s.analysisRepo.Upsert(ctx, &model.SiteAnalysis{
		SiteID:        siteID,
		Manifest:      manifest,
		GeneratedAt:   generatedAt,
		SemanticModel: semanticModel,
		DepthProducer: depthProducer,
	})
	return err
}

// missingFor diffs what the manifest references (plus the cover) against what
// has been stored.
func (s *siteService) missingFor(ctx context.Context, m *model.Site, manifest []byte) ([]string, error) {
	want, err := referencedPaths(manifest)
	if err != nil {
		return nil, apperrors.From("BAD_REQUEST").
			WithDetail("manifest could not be read: " + err.Error())
	}
	if m.CoverPath != nil && *m.CoverPath != "" {
		want = append(want, *m.CoverPath)
	}

	stored, err := s.assetRepo.ListRelPaths(ctx, m.ID)
	if err != nil {
		return nil, err
	}
	have := make(map[string]struct{}, len(stored))
	for _, p := range stored {
		have[p] = struct{}{}
	}

	missing := []string{}
	seen := map[string]struct{}{}
	for _, p := range want {
		if _, dup := seen[p]; dup {
			continue
		}
		seen[p] = struct{}{}
		if _, ok := have[p]; !ok {
			missing = append(missing, p)
		}
	}
	return missing, nil
}

func (s *siteService) hasAnalysis(ctx context.Context, id string) bool {
	_, err := s.analysisRepo.GetBySiteID(ctx, id)
	return err == nil
}
