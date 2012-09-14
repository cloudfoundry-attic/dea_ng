package directoryserver

import (
	"fmt"
	"log"
	"net/http"
)

type deaClient interface {
	Host() string
	Port() int
	HttpClient() *http.Client

	SetHost(host string)
	SetPort(port int)
	SetHttpClient(httpClient *http.Client)

	ConstructDeaRequest(path string, auth []string) (*http.Request, error)
	Get(path string, auth []string) (*http.Response, error)
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

func (dc *deaClientImpl) ConstructDeaRequest(path string,
	auth []string) (*http.Request, error) {
	url := fmt.Sprintf("http://%s:%d%s", dc.Host(), dc.Port(), path)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	// Forward the authentication credentials to the DEA.
	req.Header["Authorization"] = auth
	return req, nil
}

func (dc *deaClientImpl) Get(path string,
	auth []string) (*http.Response, error) {
	if dc.HttpClient() == nil {
		dc.SetHttpClient(&http.Client{})
	}

	deaRequest, err := dc.ConstructDeaRequest(path, auth)
	if err != nil {
		return nil, err
	}

	log.Printf("Sending HTTP request to DEA: %s", deaRequest)
	return dc.HttpClient().Do(deaRequest)
}

func newDeaClient(host string, port int) deaClientImpl {
	return deaClientImpl{host: host, port: port}
}
