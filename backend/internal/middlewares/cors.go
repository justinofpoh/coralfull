package middlewares

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// Cors echoes an allowed origin rather than replying "*".
//
// The skeleton's version set "*" together with Allow-Credentials: true, which
// browsers reject outright. Expose-Headers matters here specifically: without it
// a cross-origin fetch cannot read Content-Range, so ranged .ply loads and the
// viewer's progress reporting break.
func Cors(origins []string) fiber.Handler {
	allowed := make(map[string]bool, len(origins))
	for _, o := range origins {
		if o = strings.TrimSpace(o); o != "" {
			allowed[o] = true
		}
	}
	any := allowed["*"]

	return func(c *fiber.Ctx) error {
		c.Vary(fiber.HeaderOrigin)

		origin := c.Get(fiber.HeaderOrigin)
		if origin != "" && (any || allowed[origin]) {
			c.Set(fiber.HeaderAccessControlAllowOrigin, origin)
			c.Set(fiber.HeaderAccessControlExposeHeaders,
				"Content-Range, Accept-Ranges, Content-Length, ETag")
		}

		if c.Method() == fiber.MethodOptions {
			c.Set(fiber.HeaderAccessControlAllowMethods, "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			c.Set(fiber.HeaderAccessControlAllowHeaders, "Content-Type, If-None-Match, Range")
			c.Set(fiber.HeaderAccessControlMaxAge, "86400")
			return c.SendStatus(fiber.StatusNoContent)
		}
		return c.Next()
	}
}
