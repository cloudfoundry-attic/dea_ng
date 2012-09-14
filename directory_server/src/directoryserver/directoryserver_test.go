package directoryserver

import (
	"fmt"
	"net"
	"net/http"
	"strconv"
	"testing"
	"time"
)

func getBodyString(response *http.Response) (*string, error) {
	body := make([]byte, response.ContentLength)
	_, err := response.Body.Read(body)
	if err != nil {
		return nil, err
	}

	bodyStr := string(body)
	return &bodyStr, nil
}

func checkRequest(received *http.Request, expected *http.Request) bool {
	badMethod := received.Method != expected.Method
	badUrl := received.URL.String() != "/path"
	badProto := received.Proto != expected.Proto
	badHost := received.Host != expected.Host
	expAuth := expected.Header["Authorization"]

	var badAuth bool = false
	if len(expAuth) > 0 {
		badAuth = true
		receivedAuth := received.Header["Authorization"]
		badAuth = len(receivedAuth) != 2
		badAuth = badAuth || (receivedAuth[0] != expAuth[0])
		badAuth = badAuth || (receivedAuth[1] != expAuth[1])
	}

	if badMethod || badUrl || badProto || badHost || badAuth {
		return false
	}

	return true
}

type dummyDeaHandler struct {
	t            *testing.T
	expRequest   *http.Request
	responseBody string
}

func (handler dummyDeaHandler) ServeHTTP(w http.ResponseWriter,
	r *http.Request) {
	if !checkRequest(r, handler.expRequest) {
		handler.t.Fail()
	}

	w.Header()["Content-Length"] = []string{strconv.
		Itoa(len(handler.responseBody))}
	fmt.Fprintf(w, handler.responseBody)
}

func TestDeaClientImpl_ConstructDeaRequest(t *testing.T) {
	dc := deaClientImpl{host: "host", port: 10}

	auth := []string{"username", "password"}
	expRequest, _ := http.NewRequest("GET", "http://host:10/path", nil)

	req, _ := dc.ConstructDeaRequest("/path", auth)

	if req.Method != expRequest.Method {
		t.Fail()
	}
	if req.URL.String() != expRequest.URL.String() {
		t.Fail()
	}
	if req.Proto != expRequest.Proto {
		t.Fail()
	}
	if req.Body != expRequest.Body {
		t.Fail()
	}
	if req.ContentLength != expRequest.ContentLength {
		t.Fail()
	}
	if req.Host != expRequest.Host {
		t.Fail()
	}

	headerSize := 0
	for k, v := range req.Header {
		if k != "Authorization" {
			t.Fail()
		}
		if len(v) != 2 {
			t.Fail()
		}
		if v[0] != auth[0] {
			t.Fail()
		}
		if v[1] != auth[1] {
			t.Fail()
		}

		headerSize += 1
	}

	if headerSize != 1 {
		t.Fail()
	}
}

func TestDeaClientImpl_Get(t *testing.T) {
	dc := deaClientImpl{host: "localhost", port: 1234}

	l, err := net.Listen("tcp", "localhost:"+strconv.Itoa(1234))
	if err != nil {
		t.Error(err)
	}
	auth := []string{"username", "password"}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1234/path", nil)
	expRequest.Header["Authorization"] = auth
	responseBody := "dummy"
	// Start mock DEA server in a separate thread and wait for it to start.
	go http.Serve(l, dummyDeaHandler{t, expRequest, responseBody})
	time.Sleep(2 * time.Millisecond)

	response, err := dc.Get("/path", auth)
	if err != nil {
		t.Error(err)
	}

	if response.StatusCode != 200 {
		t.Fail()
	}

	body, err := getBodyString(response)
	if err != nil {
		t.Error(err)
	}
	if *body != responseBody {
		t.Fail()
	}

	l.Close()
}
