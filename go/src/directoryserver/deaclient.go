package directoryserver

import (
	"fmt"
	"log"
	"net/http"
)

/*
 Defines an API to communicate with the DEA through HTTP.
*/
type deaClient interface {
	/*
	   Sends the specified path to the DEA through HTTP and returns
	   the response from the DEA. Returns errors (if any) when communicating
	   with the DEA.
	*/
	get(path string) (*http.Response, error)
}

type deaClientImpl struct {
	host       string
	port       uint16
	httpClient *http.Client
}

/*
 Constructs the HTTP request to be sent to the DEA.
*/
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
