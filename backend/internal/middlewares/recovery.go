package middlewares

import (
	"fmt"
	"runtime/debug"

	"github.com/gofiber/fiber/v2"

	apperrors "coralfull/backend/pkg/utils/errors"
	"coralfull/backend/pkg/utils/logs"
)

// Recovery turns a panic into a 500 without leaking the panic value to the
// client. The skeleton's version put err.Error() in the response body under a
// "debug" key with a note to remove it in production.
func Recovery() fiber.Handler {
	return func(c *fiber.Ctx) (err error) {
		defer func() {
			if r := recover(); r != nil {
				if logs.Log != nil {
					logs.Log.WithFields(logs.Fields{
						"panic": fmt.Sprintf("%v", r),
						"path":  c.Path(),
						"stack": string(debug.Stack()),
					}).Error("recovered from panic")
				}
				err = apperrors.Respond(c, apperrors.From("INTERNAL_SERVER_ERROR"))
			}
		}()
		return c.Next()
	}
}
