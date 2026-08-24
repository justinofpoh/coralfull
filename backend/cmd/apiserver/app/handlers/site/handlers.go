package site

import (
	"github.com/gofiber/fiber/v2"

	serviceSite "coralfull/backend/internal/services/site"
	"coralfull/backend/pkg/utils/api"
	apperrors "coralfull/backend/pkg/utils/errors"
	"coralfull/backend/pkg/utils/validator"
)

func (h *SiteHandler) List(c *fiber.Ctx) error {
	sites, err := h.siteService.List(c.Context())
	if err != nil {
		return apperrors.Respond(c, err)
	}
	return c.JSON(api.Base{Data: sites})
}

func (h *SiteHandler) Get(c *fiber.Ctx) error {
	site, err := h.siteService.GetByID(c.Context(), c.Params("id"))
	if err != nil {
		return apperrors.Respond(c, err)
	}
	return c.JSON(api.Base{Data: site})
}

func (h *SiteHandler) Create(c *fiber.Ctx) error {
	payload := new(serviceSite.CreatePayload)
	if err := c.BodyParser(payload); err != nil {
		return apperrors.Respond(c, apperrors.From("BAD_REQUEST").WithDetail(err.Error()))
	}
	if msg, err := validator.Validate(payload); err != nil {
		return apperrors.Respond(c, apperrors.From("VALIDATION_FAILED").WithDetail(msg))
	}

	result, err := h.siteService.Create(c.Context(), *payload)
	if err != nil {
		return apperrors.Respond(c, err)
	}
	return c.Status(fiber.StatusCreated).JSON(api.Base{Data: result})
}

func (h *SiteHandler) Patch(c *fiber.Ctx) error {
	payload := new(serviceSite.PatchPayload)
	if err := c.BodyParser(payload); err != nil {
		return apperrors.Respond(c, apperrors.From("BAD_REQUEST").WithDetail(err.Error()))
	}
	if msg, err := validator.Validate(payload); err != nil {
		return apperrors.Respond(c, apperrors.From("VALIDATION_FAILED").WithDetail(msg))
	}

	site, err := h.siteService.Patch(c.Context(), c.Params("id"), *payload)
	if err != nil {
		return apperrors.Respond(c, err)
	}
	return c.JSON(api.Base{Data: site})
}

func (h *SiteHandler) Delete(c *fiber.Ctx) error {
	if err := h.siteService.Delete(c.Context(), c.Params("id")); err != nil {
		return apperrors.Respond(c, err)
	}
	return c.SendStatus(fiber.StatusNoContent)
}

// Analysis returns the stored manifest verbatim. It is not re-marshalled through
// a Go struct: the clients decode the whole AnalysisSequence, and round-tripping
// it here would silently drop any field this service does not model.
func (h *SiteHandler) Analysis(c *fiber.Ctx) error {
	manifest, err := h.siteService.Analysis(c.Context(), c.Params("id"))
	if err != nil {
		return apperrors.Respond(c, err)
	}
	c.Set(fiber.HeaderContentType, fiber.MIMEApplicationJSON)
	return c.Send(manifest)
}

func (h *SiteHandler) Missing(c *fiber.Ctx) error {
	missing, err := h.siteService.MissingAssets(c.Context(), c.Params("id"))
	if err != nil {
		return apperrors.Respond(c, err)
	}
	return c.JSON(api.Base{Data: fiber.Map{"missing": missing}})
}

func (h *SiteHandler) Publish(c *fiber.Ctx) error {
	site, err := h.siteService.Publish(c.Context(), c.Params("id"))
	if err != nil {
		return apperrors.Respond(c, err)
	}
	return c.JSON(api.Base{Data: site})
}
