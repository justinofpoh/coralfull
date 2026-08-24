package asset

import (
	serviceAsset "coralfull/backend/internal/services/asset"
)

type AssetHandler struct {
	assetService serviceAsset.AssetService
	maxBytes     int64
}

func NewAssetHandler(assetService serviceAsset.AssetService, maxBytes int64) *AssetHandler {
	return &AssetHandler{assetService: assetService, maxBytes: maxBytes}
}
