package errors

import (
	"errors"

	"github.com/gofiber/fiber/v2"
)

// Respond writes err as JSON. Unknown errors become a 500 with the message as a
// detail rather than leaking a raw Go error as the top-level message.
func Respond(c *fiber.Ctx, err error) error {
	if err == nil {
		return nil
	}

	var appErr *AppError
	if errors.As(err, &appErr) {
		return c.Status(appErr.Status).JSON(appErr)
	}

	internal := From("INTERNAL_SERVER_ERROR").WithDetail(err.Error())
	return c.Status(internal.Status).JSON(internal)
}

// Is reports whether err is an AppError carrying code.
func Is(err error, code string) bool {
	var appErr *AppError
	if errors.As(err, &appErr) {
		return appErr.Code == code
	}
	return false
}
