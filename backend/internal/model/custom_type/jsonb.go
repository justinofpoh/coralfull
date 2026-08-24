package custom_type

import (
	"database/sql/driver"
	"errors"
	"fmt"
)

// JSONB carries raw JSON to and from a Postgres jsonb column.
//
// A plain []byte field would be encoded as bytea by the driver and rejected by
// a jsonb column, so the value is handed over as a string.
type JSONB []byte

func (j JSONB) Value() (driver.Value, error) {
	if len(j) == 0 {
		return nil, nil
	}
	return string(j), nil
}

func (j *JSONB) Scan(src any) error {
	switch v := src.(type) {
	case nil:
		*j = nil
	case []byte:
		*j = append((*j)[:0], v...)
	case string:
		*j = append((*j)[:0], v...)
	default:
		return fmt.Errorf("custom_type: cannot scan %T into JSONB", src)
	}
	return nil
}

func (j JSONB) MarshalJSON() ([]byte, error) {
	if len(j) == 0 {
		return []byte("null"), nil
	}
	return j, nil
}

func (j *JSONB) UnmarshalJSON(b []byte) error {
	if j == nil {
		return errors.New("custom_type: UnmarshalJSON on nil JSONB")
	}
	*j = append((*j)[:0], b...)
	return nil
}
