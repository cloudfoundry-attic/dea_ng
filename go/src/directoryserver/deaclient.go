package directoryserver

import (
	"fmt"
	"net/http"
)

type deaClient struct {
	host       string
	port       uint16
	httpClient *http.Client
}

// Constructs the HTTP request to be sent to the DEA.
func (dc *deaClient) constructDeaRequest(path string) (*http.Request, error) {
	url := fmt.Sprintf("http://%s:%d%s", dc.host, dc.port, path)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	return req, nil
}

// Sends the specified path to the DEA through HTTP and returns
// the response from the DEA. Returns errors (if any) when communicating
// with the DEA.
func (dc *deaClient) get(path string) (*http.Response, error) {
	deaRequest, err := dc.constructDeaRequest(path)
	if err != nil {
		return nil, err
	}

	log.Info(fmt.Sprintf("Sending HTTP request to DEA: %s", deaRequest))
	return dc.httpClient.Do(deaRequest)
}
