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
	"encoding/json"
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
	deaClient        *deaClient
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
func (h handler) listPath(request *http.Request, writer http.ResponseWriter,
	deaResponse *http.Response) {
	path, err := h.getPath(deaResponse)
	if err != nil {
		h.writeDeaClientError(&err, writer)
		return
	}

	info, err := os.Stat(*path)
	if err != nil {
		h.writeEntityNotFound(writer)
		return
	}

	if info.IsDir() {
		h.listDir(writer, *path)
	} else {
		h.writeFile(request, writer, *path)
	}
}

// If validation with the DEA is successful, the HTTP request is served.
// Otherwise, the same HTTP response from the DEA is served as response to
// the HTTP request.
func (h handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if h.deaClient == nil {
		h.deaClient = &deaClient{host: h.deaHost, port: h.deaPort,
			httpClient: &http.Client{}}
	}

	deaResponse, err := h.deaClient.get(r.URL.String())
	if err != nil {
		h.writeDeaClientError(&err, w)
		return
	}

	log.Infof("HTTP response from DEA: %s", deaResponse)
	if deaResponse.StatusCode == 200 {
		h.listPath(r, w, deaResponse)
	} else {
		h.forwardDeaResponse(w, deaResponse)
	}
}

// Extracts the path of the file/directory from the JSON response received
// from the DEA. Returns an error if there is a problem.
func (h handler) getPath(deaResponse *http.Response) (*string, error) {
	jsonBlob := make([]byte, (*deaResponse).ContentLength)
	_, err := (*deaResponse).Body.Read(jsonBlob)
	if err != nil {
		return nil, err
	}

	var jsonObj interface{}
	err = json.Unmarshal(jsonBlob, &jsonObj)
	if err != nil {
		return nil, err
	}

	path := jsonObj.(map[string]interface{})["instance_path"].(string)
	return &path, nil
}

// Forwards the response received from the DEA as the response of the HTTP
// request. If there is a problem in reading the body of the HTTP response from
// the DEA, then writes an internal server error message in the HTTP response
// and status code to 500.
func (h handler) forwardDeaResponse(w http.ResponseWriter,
	deaResponse *http.Response) {
	body := make([]byte, deaResponse.ContentLength)
	_, err := deaResponse.Body.Read(body)
	if err != nil {
		h.writeServerError(&err, w)
		return
	}

	for header, value := range (*deaResponse).Header {
		w.Header()[header] = value
	}

	w.WriteHeader(deaResponse.StatusCode)
	w.Write(body)
}

func startServer(listener *net.Listener, deaHost string, deaPort uint16,
	streamingTimeout uint32) error {
	h := handler{}
	h.deaHost = deaHost
	h.deaPort = deaPort
	h.streamingTimeout = streamingTimeout

	return http.Serve(*listener, h)
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

	msg := fmt.Sprintf("Starting HTTP server at host: %s on port: %d",
		host,
		config.Server.DirServerPort)
	log.Info(msg)

	return startServer(&listener, "127.0.0.1", config.Server.DeaPort,
		config.Server.StreamingTimeout)
}
