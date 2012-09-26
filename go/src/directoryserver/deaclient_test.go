package directoryserver

import (
	"bytes"
	"net"
	"net/http"
	"strconv"
	"testing"
	"time"
)

func TestDeaClientImpl_ConstructDeaRequest(t *testing.T) {
	dc := deaClientImpl{host: "host", port: 10}

	expRequest, _ := http.NewRequest("GET", "http://host:10/path", nil)

	req, _ := dc.constructDeaRequest("/path")

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

	// Start mock DEA server in a separate thread and wait for it to start.
	l, err := net.Listen("tcp", "localhost:"+strconv.Itoa(1234))
	if err != nil {
		t.Error(err)
	}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1234/path", nil)
	responseBody := []byte("{\"instance_path\" : \"dummy\"}")

	go http.Serve(l,
		dummyDeaHandler{t, expRequest, &responseBody}) // thread.
	time.Sleep(2 * time.Millisecond)

	response, err := dc.get("/path")
	if err != nil {
		t.Error(err)
	}

	if response.StatusCode != 200 {
		t.Fail()
	}

	body, err := getBody(response)
	if err != nil {
		t.Error(err)
	}
	if bytes.Compare(*body, responseBody) != 0 {
		t.Fail()
	}

	l.Close()
	time.Sleep(2 * time.Millisecond)
}
