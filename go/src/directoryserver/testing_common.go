package directoryserver

import (
	steno "github.com/cloudfoundry/gosteno"
	"os"
)

func initLoggerInTest() {
	stenoConfig := &steno.Config{
		Sinks: []steno.Sink{steno.NewIOSink(os.Stderr)},
		Codec: steno.NewJsonCodec(),
		Level: steno.LOG_ALL,
	}
	steno.Init(stenoConfig)
	log = steno.NewLogger("test_directory_server")
}
