// Package validator wraps go-playground/validator with a single entry point
// that returns a human-readable message alongside the error.
//
// The skeleton's version carried a custom-tag registry, a message overwriter and
// an i18n translation table across five files. None of that is used here.
package validator

import (
	"fmt"
	"reflect"
	"strings"

	"github.com/go-playground/validator/v10"
)

var inner *validator.Validate

func init() {
	inner = validator.New()
	// Report the JSON name, so messages match the field the client sent.
	inner.RegisterTagNameFunc(func(fld reflect.StructField) string {
		name := strings.SplitN(fld.Tag.Get("json"), ",", 2)[0]
		if name == "-" {
			return ""
		}
		return name
	})
}

// Validate returns a message describing the first failure, plus the raw error.
func Validate(input any) (string, error) {
	err := inner.Struct(input)
	return Message(err), err
}

// Message renders the first validation failure.
func Message(err error) string {
	if err == nil {
		return ""
	}
	errs, ok := err.(validator.ValidationErrors)
	if !ok || len(errs) == 0 {
		return "Failed input validation"
	}
	e := errs[0]
	if param := e.Param(); param != "" {
		return fmt.Sprintf("%s does not meet %s(%s) criteria", e.Field(), e.Tag(), param)
	}
	return fmt.Sprintf("%s does not meet %s criteria", e.Field(), e.Tag())
}
