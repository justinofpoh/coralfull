package enum

import (
	"encoding/json"
	"errors"
	"fmt"
)

// SiteState mirrors UploadedSite.State on both clients.
type SiteState string

const (
	StateImporting   SiteState = "importing"
	StateProcessing  SiteState = "processing"
	StateReady       SiteState = "ready"
	StateFailed      SiteState = "failed"
	StateCancelled   SiteState = "cancelled"
	StateInterrupted SiteState = "interrupted"
)

var siteStates = map[SiteState]struct{}{
	StateImporting: {}, StateProcessing: {}, StateReady: {},
	StateFailed: {}, StateCancelled: {}, StateInterrupted: {},
}

func (s SiteState) Valid() bool {
	_, ok := siteStates[s]
	return ok
}

func (s SiteState) IsTerminal() bool {
	switch s {
	case StateReady, StateFailed, StateCancelled, StateInterrupted:
		return true
	}
	return false
}

// SiteStatePayload is the wire form of a site's state.
//
// Swift synthesises Codable for an enum with associated values as a
// single-key object -- {"ready":{}} and {"failed":{"_0":"message"}} -- and
// macOS's UploadedSite.State decoder expects exactly that. web/lib/site-record.ts
// exists solely to translate it for the browser. Emitting anything else means a
// decode failure on macOS, so the shape is pinned here and covered by a test.
type SiteStatePayload struct {
	Kind    SiteState
	Message string
}

var errBadState = errors.New("unrecognised site state")

func (p SiteStatePayload) MarshalJSON() ([]byte, error) {
	if !p.Kind.Valid() {
		return nil, fmt.Errorf("%w: %q", errBadState, p.Kind)
	}
	if p.Kind == StateFailed {
		msg := p.Message
		if msg == "" {
			msg = "Processing failed."
		}
		return json.Marshal(map[string]map[string]string{"failed": {"_0": msg}})
	}
	return json.Marshal(map[string]struct{}{string(p.Kind): {}})
}

// UnmarshalJSON accepts the Swift object form and, tolerantly, a bare string --
// web/lib/site-record.ts decodeState accepts both, so we do too.
func (p *SiteStatePayload) UnmarshalJSON(b []byte) error {
	var bare string
	if err := json.Unmarshal(b, &bare); err == nil {
		if !SiteState(bare).Valid() {
			return fmt.Errorf("%w: %q", errBadState, bare)
		}
		p.Kind = SiteState(bare)
		return nil
	}

	var wrapped map[string]json.RawMessage
	if err := json.Unmarshal(b, &wrapped); err != nil {
		return err
	}
	if len(wrapped) != 1 {
		return fmt.Errorf("%w: expected exactly one key, got %d", errBadState, len(wrapped))
	}
	for k, v := range wrapped {
		if !SiteState(k).Valid() {
			return fmt.Errorf("%w: %q", errBadState, k)
		}
		p.Kind = SiteState(k)
		if p.Kind == StateFailed {
			var inner struct {
				Zero string `json:"_0"`
			}
			// A failed payload without _0 is still a valid failed state.
			_ = json.Unmarshal(v, &inner)
			p.Message = inner.Zero
		}
	}
	return nil
}
