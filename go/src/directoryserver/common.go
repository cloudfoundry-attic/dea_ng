package directoryserver

import (
	. "launchpad.net/gocheck"
	"net/http"
	"strconv"
	"strings"
)

func getBody(response *http.Response) ([]byte, error) {
	if response.ContentLength <= 0 {
		return nil, nil
	}

	body := make([]byte, response.ContentLength)
	_, err := response.Body.Read(body)
	if err != nil {
		return nil, err
	}

	return body, nil
}

func checkRequest(received *http.Request, expected *http.Request) bool {
	badMethod := received.Method != expected.Method
	badUrl := !strings.HasSuffix(expected.URL.String(),
		received.URL.String())
	badProto := received.Proto != expected.Proto
	badHost := received.Host != expected.Host

	if badMethod || badUrl || badProto || badHost {
		return false
	}

	return true
}

type dummyDeaHandler struct {
	t            *C
	expRequest   *http.Request
	responseBody *[]byte
}

func (handler dummyDeaHandler) ServeHTTP(w http.ResponseWriter,
	r *http.Request) {
	if !checkRequest(r, handler.expRequest) {
		handler.t.Fail()
	}

	w.Header()["Content-Length"] = []string{strconv.
		Itoa(len(*(handler.responseBody)))}
	w.Write(*(handler.responseBody))
}
