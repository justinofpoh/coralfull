package asset

import (
	"bytes"
	"io"

	"github.com/gofiber/fiber/v2"

	"coralfull/backend/pkg/utils/api"
	apperrors "coralfull/backend/pkg/utils/errors"
)

// Put stores one artifact. The body is the raw file, not multipart: a publish is
// ~134 separate PUTs so that a dropped connection costs one file rather than the
// whole 55 MB, and each is idempotent by content hash.
func (h *AssetHandler) Put(c *fiber.Ctx) error {
	siteID := c.Params("id")
	relPath := c.Params("*")

	body, err := h.bodyReader(c)
	if err != nil {
		return apperrors.Respond(c, err)
	}

	result, err := h.assetService.Put(c.Context(), siteID, relPath, body, string(c.Request().Header.ContentType()))
	if err != nil {
		return apperrors.Respond(c, err)
	}
	return c.Status(fiber.StatusCreated).JSON(api.Base{Data: result})
}

// bodyReader prefers the streaming body so a 12 MB mesh never lands in memory.
//
// The cap is applied here rather than relying on Fiber's BodyLimit: once
// StreamRequestBody is on, fasthttp swallows ErrBodyTooLarge and streams anyway
// (http.go:1358), so BodyLimit stops rejecting anything. blobstore.Put takes the
// real limit and reads one byte past it to tell "at the limit" from "over".
func (h *AssetHandler) bodyReader(c *fiber.Ctx) (io.Reader, error) {
	if stream := c.Context().RequestBodyStream(); stream != nil {
		return io.LimitReader(stream, h.maxBytes+1), nil
	}
	// Small bodies, or a client that sent no Content-Length, arrive buffered.
	body := c.Body()
	if len(body) == 0 {
		return nil, apperrors.From("EMPTY_BODY")
	}
	return bytes.NewReader(body), nil
}

// Get streams one artifact.
//
// c.SendFile delegates to a fasthttp FS with AcceptByteRange, which supplies
// Range parsing, 206 with Content-Range, 416, Accept-Ranges, Last-Modified and
// If-Modified-Since. It does NOT supply an ETag -- fasthttp never sets one -- so
// that is handled here. Fiber's etag middleware is not an option: it calls
// Response.Body(), which drains the file into memory.
func (h *AssetHandler) Get(c *fiber.Ctx) error {
	asset, blobPath, err := h.assetService.Resolve(c.Context(), c.Params("id"), c.Params("*"))
	if err != nil {
		return apperrors.Respond(c, err)
	}

	// The storage key is the SHA-256 of the content, so it is already a strong
	// validator -- no size+mtime approximation needed.
	etag := `"` + asset.StorageKey + `"`
	if c.Get(fiber.HeaderIfNoneMatch) == etag {
		return c.SendStatus(fiber.StatusNotModified)
	}
	c.Set(fiber.HeaderETag, etag)
	c.Set(fiber.HeaderContentType, asset.ContentType)
	// Blobs are immutable by construction, so this can be cached forever.
	c.Set(fiber.HeaderCacheControl, "public, max-age=31536000, immutable")

	return c.SendFile(blobPath)
}

func (h *AssetHandler) List(c *fiber.Ctx) error {
	assets, err := h.assetService.List(c.Context(), c.Params("id"))
	if err != nil {
		return apperrors.Respond(c, err)
	}
	return c.JSON(api.Base{Data: assets})
}
