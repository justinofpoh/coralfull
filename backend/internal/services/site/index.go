package site

import (
	"context"

	reposSite "coralfull/backend/internal/repositories/site"
	reposSiteAnalysis "coralfull/backend/internal/repositories/site_analysis"
	reposSiteAsset "coralfull/backend/internal/repositories/site_asset"
	reposTx "coralfull/backend/internal/repositories/tx"
	"coralfull/backend/pkg/blobstore"
)

type SiteService interface {
	Create(ctx context.Context, p CreatePayload) (*CreateResponse, error)
	GetByID(ctx context.Context, id string) (*SiteResponse, error)
	List(ctx context.Context) ([]*SiteResponse, error)
	Patch(ctx context.Context, id string, p PatchPayload) (*SiteResponse, error)
	Delete(ctx context.Context, id string) error
	Analysis(ctx context.Context, id string) ([]byte, error)
	Publish(ctx context.Context, id string) (*SiteResponse, error)
	// MissingAssets is what a publisher polls to know what still needs sending.
	MissingAssets(ctx context.Context, id string) ([]string, error)
}

type siteService struct {
	siteRepo     reposSite.SiteRepo
	assetRepo    reposSiteAsset.SiteAssetRepo
	analysisRepo reposSiteAnalysis.SiteAnalysisRepo
	txRepo       reposTx.TxRepo
	blobs        *blobstore.Store
}

func NewSiteService(
	siteRepo reposSite.SiteRepo,
	assetRepo reposSiteAsset.SiteAssetRepo,
	analysisRepo reposSiteAnalysis.SiteAnalysisRepo,
	txRepo reposTx.TxRepo,
	blobs *blobstore.Store,
) SiteService {
	return &siteService{
		siteRepo:     siteRepo,
		assetRepo:    assetRepo,
		analysisRepo: analysisRepo,
		txRepo:       txRepo,
		blobs:        blobs,
	}
}
