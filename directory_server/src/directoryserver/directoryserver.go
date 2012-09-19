package directoryserver

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
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

func (h handler) writeDeaServerError(err *error, w http.ResponseWriter) {
	msgFormat := "Can't read the body of HTTP response"
	msgFormat += " from DEA due to error: %s"
	msg := fmt.Sprintf(msgFormat, (*err).Error())
	log.Print(msg)
	w.WriteHeader(500)
	fmt.Fprintf(w, msg)
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
		jsonObj := make(map[interface{}]interface{})
		err := json.Unmarshal(jsonBlob, &jsonObj)
		if err != nil {
			h.writeDeaServerError(&err, w)
			return
		}

		// TODO(kowshik): Read contents in the path string
		// and serve the response.
		path := jsonObj["instance_path"].(string)

		fmt.Fprintf(w, path)
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
