package tx

import (
	"context"

	"coralfull/backend/pkg/clients/db"
)

// TxRepo runs a function inside a database transaction. Per the skeleton's
// layer rules it is called from the service layer only.
type TxRepo interface {
	Run(ctx context.Context, fn func(ctx context.Context) error) error
}

type txRepo struct {
	dbdget db.DBGormDelegate
}

func NewTxRepo(dbdget db.DBGormDelegate) TxRepo { return &txRepo{dbdget: dbdget} }
