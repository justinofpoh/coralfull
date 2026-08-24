package errors

import "net/http"

// Registry is the whole error vocabulary. Adding a code here is the only way to
// add one; From falls back to a 500 for anything unlisted.
var Registry = map[string]AppError{
	"BAD_REQUEST":           {Code: "BAD_REQUEST", Status: http.StatusBadRequest, Message: "Bad request"},
	"VALIDATION_FAILED":     {Code: "VALIDATION_FAILED", Status: http.StatusUnprocessableEntity, Message: "Validation failed"},
	"DATA_NOT_FOUND":        {Code: "DATA_NOT_FOUND", Status: http.StatusNotFound, Message: "Data not found"},
	"INTERNAL_SERVER_ERROR": {Code: "INTERNAL_SERVER_ERROR", Status: http.StatusInternalServerError, Message: "Internal server error"},

	// Assets
	"INVALID_ASSET_PATH": {Code: "INVALID_ASSET_PATH", Status: http.StatusBadRequest, Message: "Asset path is not a valid site-relative path"},
	"ASSET_TOO_LARGE":    {Code: "ASSET_TOO_LARGE", Status: http.StatusRequestEntityTooLarge, Message: "Asset exceeds the maximum allowed size"},
	"EMPTY_BODY":         {Code: "EMPTY_BODY", Status: http.StatusBadRequest, Message: "Request body is empty"},

	// Sites
	"SITE_INCOMPLETE":  {Code: "SITE_INCOMPLETE", Status: http.StatusConflict, Message: "Site cannot be published while manifest assets are missing"},
	"SITE_NO_MANIFEST": {Code: "SITE_NO_MANIFEST", Status: http.StatusConflict, Message: "Site has no analysis manifest"},
}
