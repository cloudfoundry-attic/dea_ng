package directoryserver

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
)

type deaClient interface {
	Host() string
	Port() int
	HttpClient() *http.Client

	SetHost(host string)
	SetPort(port int)
	SetHttpClient(httpClient *http.Client)

	ConstructDeaRequest(path string) (*http.Request, error)
	Get(path string) (*http.Response, error)
}

type deaClientImpl struct {
	host       string
	port       int
	httpClient *http.Client
}

func (dc *deaClientImpl) Host() string {
	return dc.host
}

func (dc *deaClientImpl) Port() int {
	return dc.port
}

func (dc *deaClientImpl) HttpClient() *http.Client {
	return dc.httpClient
}

func (dc *deaClientImpl) SetHost(host string) {
	dc.host = host
}

func (dc *deaClientImpl) SetPort(port int) {
	dc.port = port
}

func (dc *deaClientImpl) SetHttpClient(httpClient *http.Client) {
	dc.httpClient = httpClient
}

func (dc *deaClientImpl) ConstructDeaRequest(path string) (*http.Request, error) {
	url := fmt.Sprintf("http://%s:%d%s", dc.Host(), dc.Port(), path)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	return req, nil
}

func (dc *deaClientImpl) Get(path string) (*http.Response, error) {
	if dc.HttpClient() == nil {
		dc.SetHttpClient(&http.Client{})
	}

	deaRequest, err := dc.ConstructDeaRequest(path)
	if err != nil {
		return nil, err
	}

	log.Printf("Sending HTTP request to DEA: %s", deaRequest)
	return dc.HttpClient().Do(deaRequest)
}

func newDeaClient(host string, port int) deaClientImpl {
	return deaClientImpl{host: host, port: port}
}

type handler struct {
	deaHost   string
	deaPort   int
	deaClient deaClient
}

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

func (h handler) entityNotFound() (*int, *map[string][]string, *[]byte) {
	statusCode := 404

	body := []byte("Entity not found.\n")

	headers := make(map[string][]string)
	headers["Content-Length"] = []string{strconv.Itoa(len(body))}
	headers["Content-Type"] = []string{"text/plain"}
	headers["X-Cascade"] = []string{"pass"}

	return &statusCode, &headers, &body
}

func (h handler) writeDeaClientError(err *error, w http.ResponseWriter) {
	msgFormat := "Can't read the body of HTTP response"
	msgFormat += " from DEA due to error: %s"
	msg := fmt.Sprintf(msgFormat, (*err).Error())
	log.Print(msg)
	w.WriteHeader(500)
	fmt.Fprintf(w, msg)
}

func (h handler) writeServerError(err *error, w http.ResponseWriter) {
	msgFormat := "Can't serve request due to error: %s"
	msg := fmt.Sprintf(msgFormat, (*err).Error())
	log.Print(msg)
	w.WriteHeader(500)
	fmt.Fprintf(w, msg)
}

func (h handler) listDir(dirPath string) (*int, *map[string][]string,
	*[]byte, error) {
	statusCode := 200

	entries, err := ioutil.ReadDir(dirPath)
	if err != nil {
		return nil, nil, nil, err
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

	headers := make(map[string][]string)
	headers["Content-Type"] = []string{"text/plain"}
	headers["Content-Length"] = []string{strconv.Itoa(len(body))}
	return &statusCode, &headers, &body, nil
}

func (h handler) handleFileRequest(w http.ResponseWriter, path string) {
	// TODO(kowshik): Handle file streaming requests here.	
}

func (h handler) listPath(w http.ResponseWriter, path string) {
	info, err := os.Stat(path)

	if err != nil {
		statusCode, headers, body := h.entityNotFound()
		h.writeResponse(w, *statusCode, headers, body)

		return
	}

	if info.IsDir() {
		statusCode, headers, body, err := h.listDir(path)
		if err != nil {
			h.writeServerError(&err, w)
			return
		}

		h.writeResponse(w, *statusCode, headers, body)
	} else {
		h.handleFileRequest(w, path)
	}
}

func (h handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if h.deaClient == nil {
		dc := newDeaClient(h.deaHost, h.deaPort)
		h.deaClient = &dc
	}

	deaResponse, err := h.deaClient.Get(r.URL.String())
	if err != nil {
		h.writeDeaClientError(&err, w)
		return
	}

	log.Print("HTTP response from DEA: ", deaResponse)
	if deaResponse.StatusCode == 200 {
		path, err := h.getPath(deaResponse)
		if err != nil {
			h.writeDeaClientError(&err, w)
			return
		}

		h.listPath(w, *path)
	} else {
		err := h.forwardDeaResponse(deaResponse, w)
		if err != nil {
			h.writeServerError(&err, w)
		}
	}
}

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

func (h handler) forwardDeaResponse(deaResponse *http.Response,
	w http.ResponseWriter) error {
	body := make([]byte, deaResponse.ContentLength)
	_, err := (*deaResponse).Body.Read(body)
	if err != nil {
		return err
	}

	for header, value := range (*deaResponse).Header {
		w.Header()[header] = value
	}
	h.writeResponse(w, (*deaResponse).StatusCode, nil, &body)
	return nil
}

func (h handler) writeResponse(w http.ResponseWriter, statusCode int,
	headers *map[string][]string, body *[]byte) error {
	if headers != nil {
		for header, value := range *headers {
			w.Header()[header] = value
		}
	}

	w.WriteHeader(statusCode)

	if body != nil {
		_, err := w.Write(*body)
		if err != nil {
			return err
		}
	}

	return nil
}

func startServer(listener *net.Listener, deaHost string, deaPort int) error {
	return http.Serve(*listener,
		handler{deaHost: deaHost, deaPort: deaPort})
}

func Start(host string, port int, deaPort int) error {
	address := host + ":" + strconv.Itoa(port)
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}

	log.Printf("Starting HTTP server at host: %s on port: %d", host, port)
	return startServer(&listener, host, deaPort)
}
