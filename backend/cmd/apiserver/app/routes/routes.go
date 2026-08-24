package routes

import (
	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/logger"

	"coralfull/backend/cmd/apiserver/app/store"
	"coralfull/backend/config"
	"coralfull/backend/internal/middlewares"
)

func NewHTTPServer(appStore *store.Store) *fiber.App {
	app := fiber.New(fiber.Config{
		AppName:               config.Config.System.AppName,
		DisableStartupMessage: true,

		// Artifacts are uploaded as raw PUT bodies and served as whole files, so
		// neither direction should ever be buffered in memory.
		StreamRequestBody: true,
		// Without this, fasthttp fully parses a multipart form before the
		// handler runs (http.go:1331), which defeats StreamRequestBody. Nothing
		// here uses multipart, so pre-parsing is pure cost.
		DisablePreParseMultipartForm: true,
		// Not a real limit: fasthttp swallows ErrBodyTooLarge once streaming is
		// on. The asset handler enforces the cap itself.
		BodyLimit: -1,
	})

	app.Use(logger.New(logger.Config{
		Format:     "[coralfull] ${time} | ${status} | ${latency} | ${method} | ${path} ${error}\n",
		TimeFormat: "2006/01/02 - 15:04:05",
		TimeZone:   "Local",
	}))
	app.Use(middlewares.Recovery())
	app.Use(middlewares.Cors(config.Config.AllowedOrigins))

	app.Get("/healthz", func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{"status": "ok"})
	})

	api := app.Group("/api")
	initSiteRoutes(api, appStore)

	return app
}
