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

func entityNotFound() (*int, *map[string]string, *string) {
	statusCode := 404

	body := "Entity not found.\n"

	headers := make(map[string]string)
	headers["Content-Type"] = "text/plain"
	headers["X-Cascade"] = "pass"

	return &statusCode, &headers, &body
}

func (h handler) writeDeaServerError(err *error, w http.ResponseWriter) {
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

func (h handler) listDir(dirPath string) (*int, *map[string]string,
	*string, error) {
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

	body := bodyBuffer.String()

	headers := make(map[string]string)
	headers["Content-Type"] = "text/plain"

	return &statusCode, &headers, &body, nil
}

func (h handler) listPath(path string) (*int, *map[string]string,
	*string, error) {
	info, err := os.Stat(path)
	if err != nil {
		statusCode, headers, body := entityNotFound()
		return statusCode, headers, body, nil
	}

	if info.IsDir() {
		return h.listDir(path)
	}

	// TODO(kowshik): Streaming files.
	return nil, nil, nil, nil
}

func (h handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if h.deaClient == nil {
		dc := newDeaClient(h.deaHost, h.deaPort)
		h.deaClient = &dc
	}

	response, err := h.deaClient.Get(r.URL.String())

	if err != nil {
		h.writeDeaServerError(&err, w)
		return
	}

	jsonBlob := make([]byte, response.ContentLength)
	_, err = response.Body.Read(jsonBlob)
	if err != nil {
		h.writeDeaServerError(&err, w)
		return
	}

	log.Print(response)
	if response.StatusCode == 200 {
		var jsonObj interface{}
		err := json.Unmarshal(jsonBlob, &jsonObj)
		if err != nil {
			h.writeDeaServerError(&err, w)
			return
		}

		path := jsonObj.(map[string]interface{})["instance_path"].(string)
		statusCode, headers, body, err := h.listPath(path)
		if err != nil {
			h.writeServerError(&err, w)
		}

		for header, value := range *headers {
			w.Header()[header] = []string{value}
		}

		w.Header()["Content-Length"] = []string{strconv.
			Itoa(len(*body))}
		w.WriteHeader(*statusCode)
		fmt.Fprintf(w, *body)
	} else {
		contentLength := []string{strconv.
			FormatInt(response.ContentLength, 10)}

		w.Header()["Content-Length"] = contentLength
		w.WriteHeader(response.StatusCode)
		w.Write(jsonBlob)
	}
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
