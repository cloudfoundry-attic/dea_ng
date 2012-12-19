package directoryserver

import (
	"github.com/howeyc/fsnotify"
	"io"
	"net/http"
	"os"
	"time"
)

type StreamHandler struct {
	File          *os.File
	FlushInterval time.Duration
	IdleTimeout   time.Duration
}

func (x *StreamHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var err error

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		w.WriteHeader(500)
		return
	}

	defer func() {
		// Clean up
		watcher.Close()

		// Drain channels (just to make sure watcher's routines exit)
		for _ = range watcher.Event {
		}
		for _ = range watcher.Error {
		}
	}()

	err = watcher.Watch(x.File.Name())
	if err != nil {
		w.WriteHeader(500)
		return
	}

	// Setup max latency writer
	var u io.Writer = w
	var mlw *maxLatencyWriter
	if x.FlushInterval != 0 {
		if v, ok := w.(writeFlusher); ok {
			mlw = NewMaxLatencyWriter(v, x.FlushInterval)
			defer mlw.Stop()
			u = mlw
		}
	}

	// Write header before starting stream
	w.WriteHeader(200)

	// Setup idle timeout
	if x.IdleTimeout == 0 {
		x.IdleTimeout = 1 * time.Minute
	}

	for stop := false; !stop; {
		select {
		case <-time.After(x.IdleTimeout):
			hj, ok := w.(http.Hijacker)
			if !ok {
				panic("not a http.Hijacker")
			}

			// Stop max latency writer before hijacking connection to prevent flush
			// on hijacked connection
			if mlw != nil {
				mlw.Stop()
			}

			conn, _, err := hj.Hijack()
			if err != nil {
				panic(err)
			}

			conn.Close()

			stop = true
		case ev, ok := <-watcher.Event:
			if !ok {
				stop = true
				break
			}

			// Break on rename
			if ev.IsRename() {
				stop = true
				break
			}

			_, err = io.Copy(u, x.File)
			if err != nil {
				stop = true
				break
			}
		case _, ok := <-watcher.Error:
			if !ok {
				stop = true
				break
			}
		}
	}
}
