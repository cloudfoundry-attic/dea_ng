// Copyright (c) 2012 The Go Authors. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package directoryserver

import (
	"io"
	"net/http"
	"sync"
	"time"
)

type writeFlusher interface {
	io.Writer
	http.Flusher
}

type maxLatencyWriter struct {
	flusher writeFlusher
	latency time.Duration

	writeLock sync.Mutex // protects Write + Flush
	stopLock  sync.Mutex // protects Stop
	done      chan bool
}

func NewMaxLatencyWriter(flusher writeFlusher, latency time.Duration) *maxLatencyWriter {
	writer := &maxLatencyWriter{
		flusher: flusher,
		latency: latency,
		done:    make(chan bool),
	}

	go writer.flushLoop(writer.done)

	return writer
}

func (writer *maxLatencyWriter) Write(bytes []byte) (int, error) {
	writer.writeLock.Lock()
	defer writer.writeLock.Unlock()
	return writer.flusher.Write(bytes)
}

func (writer *maxLatencyWriter) flushLoop(done chan bool) {
	ticker := time.NewTicker(writer.latency)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			writer.writeLock.Lock()
			writer.flusher.Flush()
			writer.writeLock.Unlock()
		case <-done:
			return
		}
	}
	panic("unreached")
}

func (writer *maxLatencyWriter) Stop() {
	writer.stopLock.Lock()
	defer writer.stopLock.Unlock()

	if writer.done != nil {
		writer.done <- true
		writer.done = nil
	}
}
