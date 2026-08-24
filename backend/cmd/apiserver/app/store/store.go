// Package store is the dependency container. Everything is a field on Store
// rather than a package-level var, so tests can build an isolated one.
package store

import (
	handlerAsset "coralfull/backend/cmd/apiserver/app/handlers/asset"
	handlerSite "coralfull/backend/cmd/apiserver/app/handlers/site"
	reposSite "coralfull/backend/internal/repositories/site"
	reposSiteAnalysis "coralfull/backend/internal/repositories/site_analysis"
	reposSiteAsset "coralfull/backend/internal/repositories/site_asset"
	reposTx "coralfull/backend/internal/repositories/tx"
	serviceAsset "coralfull/backend/internal/services/asset"
	serviceSite "coralfull/backend/internal/services/site"
	"coralfull/backend/pkg/blobstore"
	"coralfull/backend/pkg/clients/db"
)

type Store struct {
	DB    db.DBGormDelegate
	Blobs *blobstore.Store

	SiteRepo         reposSite.SiteRepo
	SiteAssetRepo    reposSiteAsset.SiteAssetRepo
	SiteAnalysisRepo reposSiteAnalysis.SiteAnalysisRepo
	TxRepo           reposTx.TxRepo

	SiteService  serviceSite.SiteService
	AssetService serviceAsset.AssetService

	SiteHandler  *handlerSite.SiteHandler
	AssetHandler *handlerAsset.AssetHandler
}

// New wires the graph bottom-up. Callers own opening the database and the blob
// store, which keeps this function free of I/O and usable from tests.
func New(dbdget db.DBGormDelegate, blobs *blobstore.Store, maxAssetBytes int64) *Store {
	s := &Store{DB: dbdget, Blobs: blobs}

	s.SiteRepo = reposSite.NewSiteRepo(dbdget)
	s.SiteAssetRepo = reposSiteAsset.NewSiteAssetRepo(dbdget)
	s.SiteAnalysisRepo = reposSiteAnalysis.NewSiteAnalysisRepo(dbdget)
	s.TxRepo = reposTx.NewTxRepo(dbdget)

	s.SiteService = serviceSite.NewSiteService(s.SiteRepo, s.SiteAssetRepo, s.SiteAnalysisRepo, s.TxRepo, blobs)
	s.AssetService = serviceAsset.NewAssetService(s.SiteRepo, s.SiteAssetRepo, blobs, maxAssetBytes)

	s.SiteHandler = handlerSite.NewSiteHandler(s.SiteService)
	s.AssetHandler = handlerAsset.NewAssetHandler(s.AssetService, maxAssetBytes)

	return s
}
