package asset

import (
	"context"
	"errors"
	"io"
	"mime"
	"path"
	"strings"

	"coralfull/backend/internal/model"
	"coralfull/backend/pkg/blobstore"
	apperrors "coralfull/backend/pkg/utils/errors"
	"coralfull/backend/pkg/utils/relpath"
)

func (s *assetService) Put(ctx context.Context, siteID, relPath string, r io.Reader, declaredType string) (*PutResponse, error) {
	if err := relpath.Validate(relPath); err != nil {
		return nil, apperrors.From("INVALID_ASSET_PATH").WithDetail(err.Error())
	}
	if _, err := s.siteRepo.GetByID(ctx, siteID); err != nil {
		return nil, err
	}

	ext := path.Ext(relPath)
	key, n, err := s.blobs.Put(r, ext, s.maxBytes)
	if errors.Is(err, blobstore.ErrTooLarge) {
		return nil, apperrors.From("ASSET_TOO_LARGE")
	}
	if err != nil {
		return nil, err
	}
	if n == 0 {
		// An empty artifact is always a bug upstream, and it would satisfy the
		// publish check while rendering nothing.
		_ = s.blobs.Remove(key)
		return nil, apperrors.From("EMPTY_BODY").WithDetail(relPath)
	}

	m := &model.SiteAsset{
		SiteID:      siteID,
		RelPath:     relPath,
		StorageKey:  key,
		ContentType: contentType(declaredType, ext),
		Bytes:       n,
	}
	if _, err := s.assetRepo.Upsert(ctx, m); err != nil {
		return nil, err
	}

	return &PutResponse{
		RelPath:     m.RelPath,
		StorageKey:  m.StorageKey,
		ContentType: m.ContentType,
		Bytes:       m.Bytes,
	}, nil
}

func (s *assetService) Resolve(ctx context.Context, siteID, relPath string) (*model.SiteAsset, string, error) {
	if err := relpath.Validate(relPath); err != nil {
		return nil, "", apperrors.From("INVALID_ASSET_PATH").WithDetail(err.Error())
	}
	m, err := s.assetRepo.GetByRelPath(ctx, siteID, relPath)
	if err != nil {
		return nil, "", err
	}
	// The path comes from the storage key this service generated, never from the
	// request. That matters: Fiber v2's SendFile has no traversal guard of its
	// own (Root:"", AllowEmptyRoot:true), so confinement is the caller's job.
	return m, s.blobs.Path(m.StorageKey), nil
}

func (s *assetService) List(ctx context.Context, siteID string) ([]*AssetResponse, error) {
	if _, err := s.siteRepo.GetByID(ctx, siteID); err != nil {
		return nil, err
	}
	rows, err := s.assetRepo.ListBySite(ctx, siteID)
	if err != nil {
		return nil, err
	}
	out := make([]*AssetResponse, 0, len(rows))
	for _, m := range rows {
		out = append(out, &AssetResponse{
			RelPath:     m.RelPath,
			ContentType: m.ContentType,
			Bytes:       m.Bytes,
			URL:         "/api/sites/" + siteID + "/files/" + m.RelPath,
		})
	}
	return out, nil
}

// contentType derives the MIME type, preferring the file extension over what
// the uploader declared.
//
// The declared header is the weaker signal: curl --data-binary sends
// application/x-www-form-urlencoded, browsers send it for form posts, and
// scripts frequently send nothing at all. The relative path, by contrast, comes
// from the manifest and always carries a meaningful extension. A declared type
// is only consulted when the extension yields nothing.
func contentType(declared, ext string) string {
	switch strings.ToLower(ext) {
	case ".ply", ".bin", ".spz", ".splat":
		// None of these have a registered MIME type; naming them explicitly
		// stops them being sniffed as text.
		return "application/octet-stream"
	}
	if mt := mime.TypeByExtension(strings.ToLower(ext)); mt != "" {
		if parsed, _, err := mime.ParseMediaType(mt); err == nil {
			return parsed
		}
		return mt
	}
	if mt, _, err := mime.ParseMediaType(declared); err == nil && !genericType(mt) {
		return mt
	}
	return "application/octet-stream"
}

// genericType reports whether a declared Content-Type carries no information --
// either a transport default or an explicit "I don't know".
func genericType(mt string) bool {
	switch mt {
	case "application/x-www-form-urlencoded",
		"application/octet-stream",
		"multipart/form-data",
		"":
		return true
	}
	return false
}
