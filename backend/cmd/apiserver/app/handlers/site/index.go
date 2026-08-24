package site

import (
	serviceSite "coralfull/backend/internal/services/site"
)

type SiteHandler struct {
	siteService serviceSite.SiteService
}

func NewSiteHandler(siteService serviceSite.SiteService) *SiteHandler {
	return &SiteHandler{siteService: siteService}
}
