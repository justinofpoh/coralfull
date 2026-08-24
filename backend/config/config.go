package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/caarlos0/env/v6"
	"github.com/joho/godotenv"
)

// Config is the global resolved setting. Populated by Init.
var Config = struct {
	DB struct {
		Username            string `env:"DB_USERNAME" envDefault:"coralfull"`
		Password            string `env:"DB_PASSWORD" envDefault:"coralfull"`
		Name                string `env:"DB_NAME" envDefault:"coralfull"`
		Host                string `env:"DB_HOST" envDefault:"127.0.0.1"`
		Port                string `env:"DB_PORT" envDefault:"5433"`
		SSLMode             string `env:"DB_SSLMODE" envDefault:"disable"`
		TimeZone            string `env:"DB_TIMEZONE" envDefault:"Asia/Jakarta"`
		MaxConns            int    `env:"DB_MAXCONNS" envDefault:"20"`
		MaxIdleConns        int    `env:"DB_MAXIDLECONNS" envDefault:"10"`
		ConnMaxLifetimeMins int    `env:"DB_CONNMAXLIFETIME_MINUTES" envDefault:"30"`
		Debug               bool   `env:"DB_DEBUG" envDefault:"false"`
	}

	System struct {
		AppName  string `env:"SYSTEM_APP_NAME" envDefault:"coralfull-backend"`
		AppAddr  string `env:"SYSTEM_ADDR" envDefault:":8321"`
		TimeZone string `env:"SYSTEM_TIME_ZONE" envDefault:"Asia/Jakarta"`
	}

	Storage struct {
		DataDir       string `env:"STORAGE_DATA_DIR" envDefault:"./data"`
		MaxAssetBytes int64  `env:"STORAGE_MAX_ASSET_BYTES" envDefault:"536870912"`
	}

	AllowedOrigins []string `env:"ALLOWED_ORIGINS" envSeparator:"," envDefault:"http://localhost:3000"`
}{}

// Init loads ./.env when present, then parses the environment.
func Init() {
	if _, err := os.Stat("./.env"); err == nil {
		if err := godotenv.Load(); err != nil {
			panic(err)
		}
	}
	if err := env.Parse(&Config); err != nil {
		panic(err)
	}
}

// DSN is the gorm connection string. SSLMode is included here, unlike the
// skeleton, which only passed it to golang-migrate.
func DSN() string {
	c := Config.DB
	return fmt.Sprintf("host=%s user=%s password=%s dbname=%s port=%s sslmode=%s TimeZone=%s",
		c.Host, c.Username, c.Password, c.Name, c.Port, c.SSLMode, c.TimeZone)
}

// MigrateURL is the golang-migrate connection string.
func MigrateURL() string {
	c := Config.DB
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		c.Username, c.Password, c.Host, c.Port, c.Name, c.SSLMode)
}

// Show prints the resolved config with secrets masked.
func Show() {
	Init()
	shown := Config
	shown.DB.Password = mask(shown.DB.Password)
	str, _ := json.MarshalIndent(shown, "", "  ")
	fmt.Printf("Config: %s\n", str)
}

func mask(s string) string {
	if s == "" {
		return ""
	}
	return strings.Repeat("*", len(s))
}
