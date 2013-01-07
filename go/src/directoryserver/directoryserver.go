/*
 Package directoryserver implements a HTTP-based directory server that can list
 directories and stream/dump files based on the path specified in the HTTP
 request. All HTTP requests are validated with a HTTP end-point in the
 DEA co-located in the same host at a specified port. If validation with the
 DEA is successful, the HTTP request is served. Otherwise, the same HTTP
 response from the DEA is served as response to the HTTP request.

 Directory listing lists sub-directories and files contained inside the
 directory along with the file sizes. Streaming of files uses HTTP chunked
 transfer encoding. The server also handles HTTP byte range requests.
*/
package directoryserver

import (
	"bytes"
	"common"
	"fmt"
	"io/ioutil"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"
)

// Returns a string representation of the file size.
func fileSizeFormat(size int64) string {
	if size >= (1 << 40) {
		return fmt.Sprintf("%.1fT", float64(size)/(1<<40))
	}

	if size >= (1 << 30) {
		return fmt.Sprintf("%.1fG", float64(size)/(1<<30))
	}

	if size >= (1 << 20) {
		return fmt.Sprintf("%.1fM", float64(size)/(1<<20))
	}

	if size >= (1 << 10) {
		return fmt.Sprintf("%.1fK", float64(size)/(1<<10))
	}

	return fmt.Sprintf("%dB", size)
}

// Defines a handler to serve HTTP requests received by the directory server.
type handler struct {
	deaHost          string
	deaPort          uint16
	deaClient        *DeaClient
	streamingTimeout uint32
}

// Writes the entity not found response in the HTTP response and sets the HTTP
// response status code to 400.
func (h handler) writeEntityNotFound(writer http.ResponseWriter) {
	response := "Entity not found.\n"

	writer.Header().Set("Content-Length", strconv.Itoa(len(response)))
	writer.Header().Set("Content-Type", "text/plain")
	writer.Header().Set("X-Cascade", "pass")

	writer.WriteHeader(400)

	fmt.Fprintf(writer, response)
}

// Prefixes the error message indicating that the error arose when a HTTP
// request was sent to the DEA. Writes the new error message in the HTTP
// response and sets the HTTP response status code to 500.
func (h handler) writeDeaClientError(err *error, w http.ResponseWriter) {
	msgFormat := "Can't read the body of HTTP response"
	msgFormat += " from DEA due to error: %s"
	msg := fmt.Sprintf(msgFormat, (*err).Error())
	log.Info(msg)
	w.WriteHeader(500)
	fmt.Fprintf(w, msg)
}

// Prefixes the error message indicating an internal server error.
// Writes the new error message in the HTTP response and sets the HTTP response
// status code to 500.
func (h handler) writeServerError(err *error, w http.ResponseWriter) {
	msgFormat := "Can't serve request due to error: %s"
	msg := fmt.Sprintf(msgFormat, (*err).Error())
	log.Info(msg)
	w.WriteHeader(500)
	fmt.Fprintf(w, msg)
}

// Writes the directory listing of the directory path in the HTTP response.
// Files in the directory are reported along with their sizes.
func (h handler) listDir(writer http.ResponseWriter, dirPath string) {
	entries, err := ioutil.ReadDir(dirPath)
	if err != nil {
		h.writeServerError(&err, writer)
		return
	}

	var bodyBuffer bytes.Buffer
	for _, entry := range entries {
		basename := entry.Name()

		var size string
		if entry.IsDir() {
			size = "-"
			basename += "/"
		} else {
			size = fileSizeFormat(entry.Size())
		}

		entryStr := fmt.Sprintf("%-35s %10s\n", basename, size)
		bodyBuffer.WriteString(entryStr)
	}

	body := bodyBuffer.Bytes()

	writer.Header().Set("Content-Type", "text/plain")
	writer.Header().Set("Content-Length", strconv.Itoa(len(body)))

	writer.Write(body)
}

// Dumps the contents of the specified file in the HTTP response.
// Also handles HTTP byte range requests.
// Returns an error if there is a problem in opening/closing the file.
func (h handler) dumpFile(request *http.Request, writer http.ResponseWriter,
	path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}

	handle, err := os.Open(path)
	if err != nil {
		return err
	}

	// This takes care of serving HTTP byte range request if present.
	// Otherwise dumps the entire file in the HTTP response.
	http.ServeContent(writer, request, path, info.ModTime(), handle)
	return handle.Close()
}

func (h handler) writeFile(request *http.Request,
	writer http.ResponseWriter, path string) {
	var err error
	if _, present := request.URL.Query()["tail"]; present {
		f, err := os.Open(path)
		if err == nil {
			_, err = f.Seek(0, os.SEEK_END)
			if err == nil {
				s := &StreamHandler{
					File:          f,
					FlushInterval: 50 * time.Millisecond,
					IdleTimeout:   time.Duration(h.streamingTimeout) * time.Second,
				}
				s.ServeHTTP(writer, request)
			}
		}
	} else {
		err = h.dumpFile(request, writer, path)
	}

	if err != nil {
		h.writeServerError(&err, writer)
	}
}

// Lists directory, or writes file contents in the HTTP response as per the
// the response received from the DEA. If the "tail" parameter is part of
// the HTTP request, then the file contents are streamed through chunked
// HTTP transfer encoding. Otherwise, the entire file is dumped in the HTTP
// response.
//
// Writes appropriate errors and status codes in the HTTP response if there is
// a problem in reading the file or directory.
func (h handler) listPath(w http.ResponseWriter, r *http.Request, path string) {
	info, err := os.Stat(path)
	if err != nil {
		log.Warnf("%s", err)
		h.writeEntityNotFound(w)
		return
	}

	if info.IsDir() {
		h.listDir(w, path)
	} else {
		h.writeFile(r, w, path)
	}
}

// If validation with the DEA is successful, the HTTP request is served.
// Otherwise, the same HTTP response from the DEA is served as response to
// the HTTP request.
func (h handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p, err := h.deaClient.LookupPath(w, r)
	if err != nil {
		log.Warnf("Error in LookupPath: %s", err)
		return
	}

	h.listPath(w, r, p)
}

// Starts the directory server at the specified host, port. Validates HTTP
// requests with the DEA's HTTP server which serves requests on the same host and
// specified DAE port.
func Start(host string, config *common.Config) error {
	address := host + ":" + strconv.Itoa(int(config.Server.DirServerPort))
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}

	initializeLogger()

	msg := fmt.Sprintf("Starting HTTP server at host: %s on port: %d",
		host,
		config.Server.DirServerPort)
	log.Info(msg)

	h := handler{
		deaHost:          "127.0.0.1",
		deaPort:          config.Server.DeaPort,
		streamingTimeout: config.Server.StreamingTimeout,
	}

	h.deaClient = &DeaClient{Host: h.deaHost, Port: h.deaPort}

	return http.Serve(listener, h)
}
