package directoryserver

import (
	"fmt"
	"log"
	"net/http"
)

type deaClient interface {
	Get(path string) (*http.Response, error)
}

type deaClientImpl struct {
	host       string
	port       uint16
	httpClient *http.Client
}

func (dc *deaClientImpl) ConstructDeaRequest(path string) (*http.Request, error) {
	url := fmt.Sprintf("http://%s:%d%s", dc.host, dc.port, path)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	return req, nil
}

func (dc *deaClientImpl) Get(path string) (*http.Response, error) {
	if dc.httpClient == nil {
		dc.httpClient = &http.Client{}
	}

	deaRequest, err := dc.ConstructDeaRequest(path)
	if err != nil {
		return nil, err
	}

	log.Printf("Sending HTTP request to DEA: %s", deaRequest)
	return dc.httpClient.Do(deaRequest)
}

func newDeaClient(host string, port uint16) deaClientImpl {
	return deaClientImpl{host: host, port: port}
}
