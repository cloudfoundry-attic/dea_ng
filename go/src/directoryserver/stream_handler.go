package directoryserver

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/go-fsnotify/fsnotify"
)

type StreamHandler struct {
	File          *os.File
	FlushInterval time.Duration
	IdleTimeout   time.Duration
}

func (handler *StreamHandler) ServeHTTP(writer http.ResponseWriter, r *http.Request) {
	var err error

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		writer.WriteHeader(500)
		writer.Write([]byte(fmt.Sprintf("Failed to setup file tailer: %s", err.Error())))
		return
	}

	defer func() {
		// Clean up
		watcher.Close()

		// Drain channels (just to make sure watcher's routines exit)
		for _ = range watcher.Events {
		}
		for _ = range watcher.Errors {
		}
	}()

	err = watcher.Add(handler.File.Name())
	if err != nil {
		writer.WriteHeader(500)
		writer.Write([]byte(fmt.Sprintf("Failed to tail file: %s", err.Error())))
		return
	}

	// Add a watcher for the parent dir
	err = watcher.Add(filepath.Dir(handler.File.Name()))
	if err != nil {
		watcher.Remove(handler.File.Name())
		writer.WriteHeader(500)
		writer.Write([]byte(fmt.Sprintf("Failed to tail parent dir of file: %s", err.Error())))
	}

	// Setup max latency writer
	var ioWriter io.Writer = writer
	var latencyWriter *maxLatencyWriter
	if handler.FlushInterval != 0 {
		if flusher, ok := writer.(writeFlusher); ok {
			latencyWriter = NewMaxLatencyWriter(flusher, handler.FlushInterval)
			defer latencyWriter.Stop()
			ioWriter = latencyWriter
		}
	}

	// Write header before starting stream
	latencyWriter.writeLock.Lock()
	writer.WriteHeader(200)
	latencyWriter.writeLock.Unlock()

	// Setup idle timeout
	if handler.IdleTimeout == 0 {
		handler.IdleTimeout = 1 * time.Minute
	}

	// Flush content before starting stream
	_, err = io.Copy(ioWriter, handler.File)
	if err != nil {
		return
	}

	for {
		select {
		case <-time.After(handler.IdleTimeout):
			hj, ok := writer.(http.Hijacker)
			if !ok {
				panic("not a http.Hijacker")
			}

			// Stop max latency writer before hijacking connection to prevent flush
			// on hijacked connection
			if latencyWriter != nil {
				latencyWriter.Stop()
			}

			conn, _, err := hj.Hijack()
			if err != nil {
				panic(err)
			}

			// Close connection forcibly to prevent sending EOF chunk
			// since this is not an _expected_ end of stream
			conn.Close()
			return

		case ev, ok := <-watcher.Events:
			if !ok || ev.Op&fsnotify.Rename == fsnotify.Rename {
				return
			}

			// Since we keep the inode open
			// we will not receive delete_self notification
			_, err = os.Stat(handler.File.Name())
			if err != nil {
				return
			}

			_, err = io.Copy(ioWriter, handler.File)
			if err != nil {
				return
			}

		case _, ok := <-watcher.Errors:
			if !ok {
				return
			}
		}
	}
}
