package routes

import (
	"github.com/gofiber/fiber/v2"

	"coralfull/backend/cmd/apiserver/app/store"
)

// initSiteRoutes registers the whole public surface. There is no auth: scans are
// public and unowned by design.
//
// The files/* shape mirrors the route web already had at
// web/app/api/sites/[id]/files/[...path]/route.ts, because both clients build
// those URLs by joining a manifest-relative path onto a base.
func initSiteRoutes(router fiber.Router, s *store.Store) {
	sites := router.Group("/sites")

	sites.Get("/", s.SiteHandler.List)
	sites.Post("/", s.SiteHandler.Create)
	sites.Get("/:id", s.SiteHandler.Get)
	sites.Patch("/:id", s.SiteHandler.Patch)
	sites.Delete("/:id", s.SiteHandler.Delete)

	sites.Get("/:id/analysis", s.SiteHandler.Analysis)
	sites.Get("/:id/missing", s.SiteHandler.Missing)
	sites.Post("/:id/publish", s.SiteHandler.Publish)

	sites.Get("/:id/assets", s.AssetHandler.List)
	sites.Put("/:id/files/*", s.AssetHandler.Put)
	sites.Get("/:id/files/*", s.AssetHandler.Get)
}
