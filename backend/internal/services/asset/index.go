package asset

import (
	"context"
	"io"

	"coralfull/backend/internal/model"
	reposSite "coralfull/backend/internal/repositories/site"
	reposSiteAsset "coralfull/backend/internal/repositories/site_asset"
	"coralfull/backend/pkg/blobstore"
)

type AssetService interface {
	// Put stores one artifact for a site, replacing any previous upload at the
	// same relative path.
	Put(ctx context.Context, siteID, relPath string, r io.Reader, declaredType string) (*PutResponse, error)
	// Resolve returns the asset row and the on-disk path of its blob.
	Resolve(ctx context.Context, siteID, relPath string) (*model.SiteAsset, string, error)
	List(ctx context.Context, siteID string) ([]*AssetResponse, error)
}

type assetService struct {
	siteRepo  reposSite.SiteRepo
	assetRepo reposSiteAsset.SiteAssetRepo
	blobs     *blobstore.Store
	maxBytes  int64
}

func NewAssetService(
	siteRepo reposSite.SiteRepo,
	assetRepo reposSiteAsset.SiteAssetRepo,
	blobs *blobstore.Store,
	maxBytes int64,
) AssetService {
	return &assetService{siteRepo: siteRepo, assetRepo: assetRepo, blobs: blobs, maxBytes: maxBytes}
}
