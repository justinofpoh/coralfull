package main

import (
	"os"

	"github.com/spf13/cobra"

	"coralfull/backend/cmd/apiserver/app"
	"coralfull/backend/config"
)

var (
	rootCMD = &cobra.Command{
		Use:   "coralfull-backend",
		Short: "Serves reef scan sites to the web and macOS viewers",
	}

	configCMD = &cobra.Command{
		Use:   "config",
		Short: "Show resolved settings",
		Run:   func(*cobra.Command, []string) { config.Show() },
	}

	serverCMD = &cobra.Command{
		Use:   "server",
		Short: "Run the API server",
		Run:   func(*cobra.Command, []string) { app.Run() },
	}

	migrateCMD = &cobra.Command{
		Use:   "migrate [up|down|version|force]",
		Short: "Run database migrations",
		Run:   func(_ *cobra.Command, args []string) { app.Migrate(args) },
	}
)

func main() {
	cobra.OnInitialize(config.Init)

	rootCMD.AddCommand(configCMD, serverCMD, migrateCMD)
	if err := rootCMD.Execute(); err != nil {
		os.Exit(1)
	}
}
