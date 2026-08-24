package enum

import (
	"encoding/json"
	"testing"
)

// Swift synthesises Codable for an enum with associated values as a single-key
// object. macOS's UploadedSite.State decoder expects exactly that shape, and
// web/lib/site-record.ts:28-31 translates it for the browser. If this test
// changes, the macOS client stops decoding.
func TestSiteStatePayloadMarshalsSwiftShape(t *testing.T) {
	cases := []struct {
		in   SiteStatePayload
		want string
	}{
		{SiteStatePayload{Kind: StateReady}, `{"ready":{}}`},
		{SiteStatePayload{Kind: StateImporting}, `{"importing":{}}`},
		{SiteStatePayload{Kind: StateProcessing}, `{"processing":{}}`},
		{SiteStatePayload{Kind: StateCancelled}, `{"cancelled":{}}`},
		{SiteStatePayload{Kind: StateInterrupted}, `{"interrupted":{}}`},
		{SiteStatePayload{Kind: StateFailed, Message: "metashape exited 1"},
			`{"failed":{"_0":"metashape exited 1"}}`},
		// A failed state with no message must still carry _0; Swift's decoder
		// requires the associated value.
		{SiteStatePayload{Kind: StateFailed}, `{"failed":{"_0":"Processing failed."}}`},
	}
	for _, c := range cases {
		got, err := json.Marshal(c.in)
		if err != nil {
			t.Errorf("Marshal(%+v) error: %v", c.in, err)
			continue
		}
		if string(got) != c.want {
			t.Errorf("Marshal(%+v) = %s, want %s", c.in, got, c.want)
		}
	}

	if _, err := json.Marshal(SiteStatePayload{Kind: "bogus"}); err == nil {
		t.Error("Marshal of an unknown state = nil error, want an error")
	}
}

func TestSiteStatePayloadUnmarshal(t *testing.T) {
	cases := map[string]SiteStatePayload{
		`{"ready":{}}`:                    {Kind: StateReady},
		`"ready"`:                         {Kind: StateReady}, // bare string, as decodeState tolerates
		`{"failed":{"_0":"boom"}}`:        {Kind: StateFailed, Message: "boom"},
		`{"failed":{}}`:                   {Kind: StateFailed},
		`{"processing":{"ignored":true}}`: {Kind: StateProcessing},
	}
	for in, want := range cases {
		var got SiteStatePayload
		if err := json.Unmarshal([]byte(in), &got); err != nil {
			t.Errorf("Unmarshal(%s) error: %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("Unmarshal(%s) = %+v, want %+v", in, got, want)
		}
	}

	for _, in := range []string{`"nonsense"`, `{"nonsense":{}}`, `{"ready":{},"failed":{}}`, `5`} {
		var got SiteStatePayload
		if err := json.Unmarshal([]byte(in), &got); err == nil {
			t.Errorf("Unmarshal(%s) = nil error, want an error", in)
		}
	}
}

// A round trip through the wire form must be lossless in both directions.
func TestSiteStatePayloadRoundTrip(t *testing.T) {
	for _, in := range []SiteStatePayload{
		{Kind: StateReady},
		{Kind: StateFailed, Message: "disk full"},
		{Kind: StateInterrupted},
	} {
		b, err := json.Marshal(in)
		if err != nil {
			t.Fatal(err)
		}
		var out SiteStatePayload
		if err := json.Unmarshal(b, &out); err != nil {
			t.Fatal(err)
		}
		if out.Kind != in.Kind || (in.Message != "" && out.Message != in.Message) {
			t.Errorf("round trip of %+v gave %+v", in, out)
		}
	}
}
