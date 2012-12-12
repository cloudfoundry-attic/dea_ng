package directoryserver

import (
	"github.com/howeyc/fsnotify"
	"io"
	"net/http"
	"os"
	"time"
)

type StreamHandler struct {
	FlushInterval time.Duration
}

func (x *StreamHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var err error

	// Open file
	file, err := os.Open(r.URL.Path)
	if err != nil {
		if os.IsNotExist(err) {
			w.WriteHeader(404)
		} else {
			w.WriteHeader(500)
		}
		return
	}

	defer file.Close()

	// Seek to end
	_, err = file.Seek(0, os.SEEK_END)
	if err != nil {
		w.WriteHeader(500)
		return
	}

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

	err = watcher.Watch(r.URL.Path)
	if err != nil {
		w.WriteHeader(500)
		return
	}

	// Setup max latency writer
	var u io.Writer = w
	if x.FlushInterval != 0 {
		if v, ok := w.(writeFlusher); ok {
			u = &maxLatencyWriter{dst: v, latency: x.FlushInterval}
		}
	}

	// Kickstart max latency writer
	u.Write(nil)

	for ok := true; ok && err == nil; {
		select {
		case _, ok = <-watcher.Event:
			if !ok {
				break
			}

			_, err = io.Copy(u, file)
			if err != nil {
				break
			}
		case err, ok = <-watcher.Error:
			if !ok {
				break
			}
		}
	}
}
