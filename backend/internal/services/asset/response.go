package asset

type PutResponse struct {
	RelPath     string `json:"relPath"`
	StorageKey  string `json:"storageKey"`
	ContentType string `json:"contentType"`
	Bytes       int64  `json:"bytes"`
}

type AssetResponse struct {
	RelPath     string `json:"relPath"`
	ContentType string `json:"contentType"`
	Bytes       int64  `json:"bytes"`
	URL         string `json:"url"`
}
