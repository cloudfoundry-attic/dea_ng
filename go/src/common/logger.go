package common

import (
	steno "github.com/cloudfoundry/gosteno"
	"os"
)

func SetupSteno(logConfig *LogConfig) {
	level, err := steno.GetLogLevel(logConfig.Level)
	if err != nil {
		panic(err)
	}

	sinks := make([]steno.Sink, 0)
	if logConfig.File != "" {
		sinks = append(sinks, steno.NewFileSink(logConfig.File))
	} else {
		sinks = append(sinks, steno.NewIOSink(os.Stdout))
	}
	if logConfig.Syslog != "" {
		sinks = append(sinks, steno.NewSyslogSink(logConfig.Syslog))
	}

	stenoConfig := &steno.Config{
		Sinks: sinks,
		Codec: steno.NewJsonCodec(),
		Level: level,
	}

	steno.Init(stenoConfig)
}
