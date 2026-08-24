package api

// Base is the success envelope. Both fields are omitempty so a bare data
// response and a bare message response are both clean.
type Base struct {
	Message string      `json:"message,omitempty"`
	Data    interface{} `json:"data,omitempty"`
}
