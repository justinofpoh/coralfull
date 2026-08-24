package errors

import "fmt"

// AppError is the single error type crossing layer boundaries. Repositories and
// services return it; handlers hand it to Respond.
type AppError struct {
	Code    string   `json:"code"`
	Message string   `json:"message"`
	Status  int      `json:"status"`
	Details []string `json:"details,omitempty"`
}

func (e *AppError) Error() string {
	return fmt.Sprintf("%s - %s", e.Code, e.Message)
}

// From builds an AppError from the registry. An unknown code is a programming
// error, so it degrades to a 500 rather than inventing a status.
func From(code string) *AppError {
	if e, ok := Registry[code]; ok {
		return &AppError{Code: e.Code, Status: e.Status, Message: e.Message}
	}
	return &AppError{
		Code:    "INTERNAL_SERVER_ERROR",
		Status:  500,
		Message: "Unhandled error",
	}
}

func (e *AppError) WithMessage(msg string) *AppError {
	e.Message = msg
	return e
}

func (e *AppError) WithStatus(status int) *AppError {
	e.Status = status
	return e
}

func (e *AppError) WithDetail(detail string) *AppError {
	e.Details = append(e.Details, detail)
	return e
}

func (e *AppError) WithDetails(details []string) *AppError {
	e.Details = append(e.Details, details...)
	return e
}
