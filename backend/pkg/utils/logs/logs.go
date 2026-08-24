package logs

import (
	"os"
	"time"

	"github.com/sirupsen/logrus"
)

// Log is the process-wide logger. Init must run before first use.
var Log *logrus.Logger

type Fields = logrus.Fields

// Init configures structured JSON logging to stdout.
//
// The skeleton's version also shipped every entry to a remote HTTP endpoint via
// resty. Dropped: nothing here needs it, and it hid failures behind a client.
func Init(debug bool) {
	l := logrus.New()
	l.SetOutput(os.Stdout)
	l.SetFormatter(&logrus.JSONFormatter{TimestampFormat: time.RFC3339})
	if debug {
		l.SetLevel(logrus.DebugLevel)
	}
	Log = l
}
