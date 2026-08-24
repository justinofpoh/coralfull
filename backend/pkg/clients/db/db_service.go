package db

import (
	"context"
	"sync"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"gorm.io/gorm/logger"

	"coralfull/backend/config"
)

// txKey is a private type so nothing outside this package can collide with the
// context key. The skeleton used the bare string "tx", which go vet flags.
type txKey struct{}

// TxContext returns ctx carrying tx, for the tx repository.
func TxContext(ctx context.Context, tx *gorm.DB) context.Context {
	return context.WithValue(ctx, txKey{}, tx)
}

// TxFrom returns the transaction carried by ctx, if any.
func TxFrom(ctx context.Context) *gorm.DB {
	tx, ok := ctx.Value(txKey{}).(*gorm.DB)
	if ok && tx != nil {
		return tx
	}
	return nil
}

type DBGormDelegate interface {
	Init() error
	Get(ctx context.Context) *gorm.DB
	BeginTx() *gorm.DB
	Rollback(tx *gorm.DB)
	Commit(tx *gorm.DB) error
	ConflictColumnsToClauseColumns(columns []string) []clause.Column
	Close() error
}

type dbDelegate struct {
	dbGorm *gorm.DB
	once   sync.Once
	err    error
}

func NewDBDelegate() DBGormDelegate { return &dbDelegate{} }

// Init opens the pool. Migrations are NOT run here -- the skeleton's master
// branch called m.Up() on every boot, which makes the binary refuse to start on
// a migration error and forces it to run from the repo root. Use `migrate up`.
func (d *dbDelegate) Init() error {
	d.once.Do(func() {
		logLevel := logger.Silent
		if config.Config.DB.Debug {
			logLevel = logger.Info
		}

		d.dbGorm, d.err = gorm.Open(
			postgres.Open(config.DSN()),
			&gorm.Config{
				DisableForeignKeyConstraintWhenMigrating: true,
				Logger:                                   logger.Default.LogMode(logLevel),
			},
		)
		if d.err != nil {
			return
		}

		// The skeleton read these three settings into config and never applied
		// them, leaving gorm's defaults in place. Apply them.
		sqlDB, err := d.dbGorm.DB()
		if err != nil {
			d.err = err
			return
		}
		sqlDB.SetMaxOpenConns(config.Config.DB.MaxConns)
		sqlDB.SetMaxIdleConns(config.Config.DB.MaxIdleConns)
		sqlDB.SetConnMaxLifetime(time.Duration(config.Config.DB.ConnMaxLifetimeMins) * time.Minute)
	})
	return d.err
}

// Get returns the transaction in ctx when there is one, otherwise the pool.
func (d *dbDelegate) Get(ctx context.Context) *gorm.DB {
	if tx := TxFrom(ctx); tx != nil {
		return tx.WithContext(ctx)
	}
	return d.dbGorm.WithContext(ctx)
}

func (d *dbDelegate) BeginTx() *gorm.DB { return d.dbGorm.Begin() }

func (d *dbDelegate) Rollback(tx *gorm.DB) {
	if tx != nil {
		tx.Rollback()
	}
}

func (d *dbDelegate) Commit(tx *gorm.DB) error {
	if tx != nil {
		return tx.Commit().Error
	}
	return nil
}

func (d *dbDelegate) Close() error {
	if d.dbGorm == nil {
		return nil
	}
	sqlDB, err := d.dbGorm.DB()
	if err != nil {
		return err
	}
	return sqlDB.Close()
}

func (d *dbDelegate) ConflictColumnsToClauseColumns(columns []string) []clause.Column {
	out := make([]clause.Column, len(columns))
	for i, c := range columns {
		out[i] = clause.Column{Name: c}
	}
	return out
}
