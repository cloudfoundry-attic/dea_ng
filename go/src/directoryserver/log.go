package directoryserver

import (
	steno "github.com/cloudfoundry/gosteno"
)

var log *steno.Logger

func init() {
	initializeLogger()
}

func initializeLogger() {
	log = steno.NewLogger("directory_server")
}
