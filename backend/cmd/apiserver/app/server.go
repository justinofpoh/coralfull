package app

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"coralfull/backend/cmd/apiserver/app/routes"
	"coralfull/backend/cmd/apiserver/app/store"
	"coralfull/backend/config"
	"coralfull/backend/pkg/blobstore"
	"coralfull/backend/pkg/clients/db"
	"coralfull/backend/pkg/utils/logs"
)

func Run() {
	loc, err := time.LoadLocation(config.Config.System.TimeZone)
	if err != nil {
		panic("invalid timezone: " + config.Config.System.TimeZone)
	}
	time.Local = loc

	logs.Init(config.Config.DB.Debug)

	dbdget := db.NewDBDelegate()
	if err := dbdget.Init(); err != nil {
		logs.Log.Fatalf("database: %v", err)
	}
	defer dbdget.Close()

	blobs, err := blobstore.New(config.Config.Storage.DataDir)
	if err != nil {
		logs.Log.Fatalf("blob store: %v", err)
	}

	appStore := store.New(dbdget, blobs, config.Config.Storage.MaxAssetBytes)
	app := routes.NewHTTPServer(appStore)

	go func() {
		logs.Log.Infof("listening on %s (data=%s, origins=%v)",
			config.Config.System.AppAddr,
			config.Config.Storage.DataDir,
			config.Config.AllowedOrigins)
		if err := app.Listen(config.Config.System.AppAddr); err != nil {
			logs.Log.Fatalf("listen: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	logs.Log.Warn("shutdown signal received")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := app.ShutdownWithContext(ctx); err != nil {
		logs.Log.Errorf("graceful shutdown: %v", err)
	}
	logs.Log.Warn("server stopped")
}
