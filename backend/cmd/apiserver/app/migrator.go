package app

import (
	"errors"
	"fmt"
	"os"
	"strconv"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/source/file"

	"coralfull/backend/config"
)

// migrationsSource is relative, so these commands must run from the backend
// directory. That is what the Makefile targets do.
const migrationsSource = "file://cmd/apiserver/app/migrations"

// Migrate runs golang-migrate. It is a separate command on purpose: the
// skeleton's master branch called m.Up() inside db.Init() on every boot, which
// makes a bad migration a startup crash.
func Migrate(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: migrate <up|down|version|force> [version]")
		os.Exit(1)
	}

	m, err := migrate.New(migrationsSource, config.MigrateURL())
	if err != nil {
		fmt.Printf("migration init failed: %v\n", err)
		os.Exit(1)
	}
	defer m.Close()

	switch args[0] {
	case "up":
		if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
			fail("migrate up", err)
		}
		fmt.Println("migration up completed")
	case "down":
		if err := m.Down(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
			fail("migrate down", err)
		}
		fmt.Println("migration down completed")
	case "version":
		version, dirty, err := m.Version()
		if err != nil {
			fail("check version", err)
		}
		fmt.Printf("version: %d, dirty: %v\n", version, dirty)
	case "force":
		if len(args) < 2 {
			fmt.Println("force requires a version argument")
			os.Exit(1)
		}
		v, err := strconv.Atoi(args[1])
		if err != nil {
			fmt.Printf("invalid version %q: %v\n", args[1], err)
			os.Exit(1)
		}
		if err := m.Force(v); err != nil {
			fail("force", err)
		}
		fmt.Println("force completed")
	default:
		fmt.Printf("unknown command: %s\n", args[0])
		os.Exit(1)
	}
}

func fail(what string, err error) {
	fmt.Printf("%s failed: %v\n", what, err)
	os.Exit(1)
}
