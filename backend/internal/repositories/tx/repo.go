package tx

import (
	"context"

	"coralfull/backend/pkg/clients/db"
)

// Run executes fn in a transaction. It is reentrant: if ctx already carries one,
// fn joins it rather than opening a nested transaction.
func (r *txRepo) Run(ctx context.Context, fn func(ctx context.Context) error) error {
	if existing := db.TxFrom(ctx); existing != nil {
		return fn(ctx)
	}

	tx := r.dbdget.BeginTx()
	if tx.Error != nil {
		return tx.Error
	}

	defer func() {
		if p := recover(); p != nil {
			r.dbdget.Rollback(tx)
			panic(p)
		}
	}()

	if err := fn(db.TxContext(ctx, tx)); err != nil {
		r.dbdget.Rollback(tx)
		return err
	}

	if err := r.dbdget.Commit(tx); err != nil {
		r.dbdget.Rollback(tx)
		return err
	}
	return nil
}
