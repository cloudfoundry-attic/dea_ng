package directoryserver

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

type DeaClient struct {
	Host string
	Port uint16
}

var (
	ErrUnreachable = errors.New("DEA is unreachable")
	ErrNotOK       = errors.New("DEA did not respond with 200 status")
	ErrInvalidJson = errors.New("DEA responded with invalid JSON")
)

// LookupPath makes a request to a DEA on behalf of the specified request.
// On errors, it writes the error to the specified response writer and returns
// one of the defined errors to the caller.
// On success, it returns the path extracted from the DEA response.
func (x *DeaClient) LookupPath(w http.ResponseWriter, r *http.Request) (string, error) {
	y := fmt.Sprintf("http://%s:%d%s", x.Host, x.Port, r.URL.String())

	log.Infof("Sending HTTP request to DEA: %s", y)

	res, err := http.Get(y)
	if err != nil {
		http.Error(w, ErrUnreachable.Error(), http.StatusInternalServerError)
		return "", ErrUnreachable
	}

	defer res.Body.Close()

	if res.StatusCode != 200 {
		// Forward DEA response
		for h, i := range res.Header {
			w.Header().Del(h)
			for _, j := range i {
				w.Header().Add(h, j)
			}
		}

		w.WriteHeader(res.StatusCode)
		io.Copy(w, res.Body)
		return "", ErrNotOK
	}

	d := json.NewDecoder(res.Body)
	m := make(map[string]interface{})
	err = d.Decode(&m)
	if err != nil {
		http.Error(w, ErrInvalidJson.Error(), http.StatusInternalServerError)
		return "", ErrInvalidJson
	}

	p, ok := m["instance_path"].(string)
	if !ok {
		http.Error(w, ErrInvalidJson.Error(), http.StatusInternalServerError)
		return "", ErrInvalidJson
	}

	return p, nil
}
