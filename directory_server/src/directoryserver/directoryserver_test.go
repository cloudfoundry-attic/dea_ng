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

	if badMethod || badUrl || badProto || badHost {
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

type denyingDeaHandler struct {
	t            *testing.T
	expRequest   *http.Request
	responseBody string
}

func (handler denyingDeaHandler) ServeHTTP(w http.ResponseWriter,
	r *http.Request) {
	if !checkRequest(r, handler.expRequest) {
		handler.t.Fail()
	}

	w.Header()["Content-Length"] = []string{strconv.
		Itoa(len(handler.responseBody))}
	w.WriteHeader(400)
	fmt.Fprintf(w, handler.responseBody)
}

func TestDeaClientImpl_ConstructDeaRequest(t *testing.T) {
	dc := deaClientImpl{host: "host", port: 10}

	expRequest, _ := http.NewRequest("GET", "http://host:10/path", nil)

	req, _ := dc.ConstructDeaRequest("/path")

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
}

func TestDeaClientImpl_Get(t *testing.T) {
	dc := deaClientImpl{host: "localhost", port: 1234}

	l, err := net.Listen("tcp", "localhost:"+strconv.Itoa(1234))
	if err != nil {
		t.Error(err)
	}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1234/path", nil)
	responseBody := "dummy"
	// Start mock DEA server in a separate thread and wait for it to start.
	go http.Serve(l, dummyDeaHandler{t, expRequest, responseBody})
	time.Sleep(2 * time.Millisecond)

	response, err := dc.Get("/path")
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

func TestHandler_ServeHTTP_RequestToDeaFailed(t *testing.T) {
	address := "localhost:" + strconv.Itoa(1235)
	dirServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	// Start mock dir server in a separate thread and wait for it to start.
	// "badhost" causes the HTTP request to DEA to fail.
	go startServer(&dirServerListener, "badhost", 0)
	time.Sleep(2 * time.Millisecond)

	response, err := http.Get("http://localhost:1235/path")
	if err != nil {
		t.Error(err)
	}

	if response.StatusCode != 500 {
		t.Fail()
	}

	// Shutdown server.
	dirServerListener.Close()
}

func TestHandler_ServeHTTP_RequestDeniedByDea(t *testing.T) {
	address := "localhost:" + strconv.Itoa(1235)
	dirServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	// Start mock dir server in a separate thread and wait for it to start.
	go startServer(&dirServerListener, "localhost", 1236)
	time.Sleep(2 * time.Millisecond)

	address = "localhost:" + strconv.Itoa(1236)
	deaServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1236/path", nil)
	responseBody := "dummy"
	// Start mock DEA server in a separate thread and wait for it to start.
	go http.Serve(deaServerListener,
		denyingDeaHandler{t, expRequest, responseBody})
	time.Sleep(2 * time.Millisecond)

	response, err := http.Get("http://localhost:1235/path")
	fmt.Println(response)
	if err != nil {
		t.Error(err)
	}

	if response.StatusCode != 400 {
		t.Fail()
	}

	body, err := getBodyString(response)
	if err != nil {
		t.Error(err)
	}
	if *body != responseBody {
		t.Fail()
	}

	// Shutdown servers.
	deaServerListener.Close()
	dirServerListener.Close()
}

// TODO(kowshik): This is only a placeholder and will change during next phase
// of implementation.
func TestHandler_ServeHTTP_RequestApprovedByDea(t *testing.T) {
}
