package enum

// Priority mirrors CoralSite.Priority on macOS and SitePriority on web.
type Priority string

const (
	PriorityHigh   Priority = "high"
	PriorityMedium Priority = "medium"
	PriorityLow    Priority = "low"
)

func (p Priority) Valid() bool {
	switch p {
	case PriorityHigh, PriorityMedium, PriorityLow:
		return true
	}
	return false
}
