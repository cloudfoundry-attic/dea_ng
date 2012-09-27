package directoryserver

import (
	"fmt"
	"log"
	"net/http"
)

type deaClient interface {
	get(path string) (*http.Response, error)
}

type deaClientImpl struct {
	host       string
	port       uint16
	httpClient *http.Client
}

func (dc *deaClientImpl) constructDeaRequest(path string) (*http.Request, error) {
	url := fmt.Sprintf("http://%s:%d%s", dc.host, dc.port, path)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	return req, nil
}

func (dc *deaClientImpl) get(path string) (*http.Response, error) {
	if dc.httpClient == nil {
		dc.httpClient = &http.Client{}
	}

	deaRequest, err := dc.constructDeaRequest(path)
	if err != nil {
		return nil, err
	}

	log.Printf("Sending HTTP request to DEA: %s", deaRequest)
	return dc.httpClient.Do(deaRequest)
}

func newDeaClient(host string, port uint16) deaClientImpl {
	return deaClientImpl{host: host, port: port}
}
