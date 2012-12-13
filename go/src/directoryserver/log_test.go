package directoryserver

import (
	steno "github.com/cloudfoundry/gosteno"
	"os"
)

func init() {
	steno.Init(&steno.Config{
		Sinks: []steno.Sink{steno.NewIOSink(os.Stderr)},
		Codec: steno.NewJsonCodec(),
		Level: steno.LOG_ALL,
	})

	log = steno.NewLogger("directory_server_test")
}
