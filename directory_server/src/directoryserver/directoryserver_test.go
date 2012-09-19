package directoryserver

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func dump(file *os.File, t *testing.T, numLines int) error {
	handle, err := os.OpenFile(file.Name(), syscall.O_WRONLY, 0666)
	if err != nil {
		t.Error(err)
	}

	for count := 0; count < numLines; count++ {
		_, err = handle.WriteString("blah")
		if err != nil {
			t.Error(err)
		}
		time.Sleep(250 * time.Millisecond)
	}

	err = handle.Close()
	return err
}

func getBody(response *http.Response) (*[]byte, error) {
	if response.ContentLength <= 0 {
		return nil, nil
	}

	body := make([]byte, response.ContentLength)
	_, err := response.Body.Read(body)
	if err != nil {
		return nil, err
	}

	return &body, nil
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
	t            *testing.T
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

type denyingDeaHandler struct {
	t            *testing.T
	expRequest   *http.Request
	responseBody *[]byte
}

func (handler denyingDeaHandler) ServeHTTP(w http.ResponseWriter,
	r *http.Request) {
	if !checkRequest(r, handler.expRequest) {
		handler.t.Fail()
	}

	w.Header()["Content-Length"] = []string{strconv.
		Itoa(len(*(handler.responseBody)))}
	w.WriteHeader(400)
	w.Write(*(handler.responseBody))
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

	response, err := dc.Get("/path")
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

func TestHandler_ServeHTTP_RequestToDeaFailed(t *testing.T) {
	// Start mock dir server in a separate thread and wait for it to start.
	address := "localhost:" + strconv.Itoa(1235)
	dirServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	// "badhost" causes the HTTP request to DEA to fail.
	go startServer(&dirServerListener, "badhost", 0, 1) // thread.
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
	time.Sleep(2 * time.Millisecond)
}

func TestHandler_ServeHTTP_RequestDeniedByDea(t *testing.T) {
	// Start mock dir server in a separate thread and wait for it to start.
	address := "localhost:" + strconv.Itoa(1236)
	dirServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	go startServer(&dirServerListener, "localhost", 1237, 1) // thread.
	time.Sleep(2 * time.Millisecond)

	// Start mock DEA server in a separate thread and wait for it to start.
	address = "localhost:" + strconv.Itoa(1237)
	deaServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1237/path", nil)
	responseBody := []byte("{\"instance_path\" : \"dummy\"}")
	go http.Serve(deaServerListener,
		denyingDeaHandler{t, expRequest, &responseBody}) // thread.
	time.Sleep(2 * time.Millisecond)

	response, err := http.Get("http://localhost:1236/path")
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 400 {
		t.Fail()
	}

	// Check body.
	body, err := getBody(response)
	if err != nil {
		t.Error(err)
	}
	if bytes.Compare(*body, responseBody) != 0 {
		t.Fail()
	}

	// Shutdown servers.
	deaServerListener.Close()
	dirServerListener.Close()
	time.Sleep(2 * time.Millisecond)
}

func TestHandler_ServeHTTP_EntityNotFound(t *testing.T) {
	// Start mock dir server in a separate thread and wait for it to start.
	address := "localhost:" + strconv.Itoa(1238)
	dirServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	go startServer(&dirServerListener, "localhost", 1239, 1) // thread.
	time.Sleep(2 * time.Millisecond)

	// Start mock DEA server in a separate thread and wait for it to start.
	address = "localhost:" + strconv.Itoa(1239)
	deaServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1239/path", nil)
	responseBody := []byte("{\"instance_path\" : \"dummy\"}")
	go http.Serve(deaServerListener,
		dummyDeaHandler{t, expRequest, &responseBody}) // thread.
	time.Sleep(2 * time.Millisecond)

	response, err := http.Get("http://localhost:1238/path")
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 400 {
		t.Fail()
	}

	// Check headers.
	headerValue := response.Header["Content-Type"]
	if len(headerValue) != 1 || headerValue[0] != "text/plain" {
		t.Fail()
	}

	headerValue = response.Header["X-Cascade"]
	if len(headerValue) != 1 || headerValue[0] != "pass" {
		t.Fail()
	}

	// Check body.
	body, err := getBody(response)
	if err != nil {
		t.Error(err)
	}
	if strings.ToLower(string(*body)) != "entity not found.\n" {
		t.Fail()
	}

	// Shutdown servers.
	deaServerListener.Close()
	dirServerListener.Close()
	time.Sleep(2 * time.Millisecond)
}

func TestHandler_ServeHTTP_ReturnDirectoryListing(t *testing.T) {
	address := "localhost:" + strconv.Itoa(1240)
	dirServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	// Start mock dir server in a separate thread and wait for it to start.
	go startServer(&dirServerListener, "localhost", 1241, 1)
	time.Sleep(2 * time.Millisecond)

	address = "localhost:" + strconv.Itoa(1241)
	deaServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1241/path", nil)
	// Create temp directory listing for this unit test.
	tmpDir, err := ioutil.TempDir("", "")
	if err != nil {
		t.Fail()
	}
	_, err = ioutil.TempDir(tmpDir, "testdir_")
	if err != nil {
		t.Fail()
	}
	tmpFile, err := ioutil.TempFile(tmpDir, "testfile_")
	if err != nil {
		t.Fail()
	}
	err = tmpFile.Close()
	if err != nil {
		t.Fail()
	}
	var dump bytes.Buffer
	for index := 0; index < 10000; index++ {
		dump.WriteString("A")
	}
	err = ioutil.WriteFile(tmpFile.Name(), []byte(dump.String()), 0600)
	if err != nil {
		t.Fail()
	}

	responseBody := []byte(fmt.
		Sprintf("{\"instance_path\" : \"%s\"}", tmpDir))

	// Start mock DEA server in a separate thread and wait for it to start.
	go http.Serve(deaServerListener,
		dummyDeaHandler{t, expRequest, &responseBody})
	time.Sleep(2 * time.Millisecond)

	response, err := http.Get("http://localhost:1240/path")
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 200 {
		t.Fail()
	}

	// Check headers.
	headerValue := response.Header["Content-Type"]
	if len(headerValue) != 1 || headerValue[0] != "text/plain" {
		t.Fail()
	}

	// Check body.
	body, err := getBody(response)
	if err != nil {
		t.Error(err)
	}
	pattern := "\\s*testdir_.*/\\s*-\\n\\s*testfile_.*\\s*9\\.8K"
	matched, _ := regexp.Match(pattern, *body)
	if !matched {
		t.Fail()
	}

	// Clean up.
	if err = os.RemoveAll(tmpDir); err != nil {
		t.Fail()
	}
	deaServerListener.Close()
	dirServerListener.Close()
	time.Sleep(2 * time.Millisecond)
}

func TestHandler_ServeHTTP_StreamFile(t *testing.T) {
	// Start mock dir server in a separate thread and wait for it to start.
	address := "localhost:" + strconv.Itoa(1242)
	dirServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	go startServer(&dirServerListener, "localhost", 1243, 2) // thread.
	time.Sleep(2 * time.Millisecond)

	// Start mock dea server in a separate thread and wait for it to start.
	address = "localhost:" + strconv.Itoa(1243)
	deaServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1243/path?tail", nil)

	// Create temp file for this unit test.
	tmpFile, err := ioutil.TempFile("", "testfile_")
	if err != nil {
		t.Fail()
	}
	err = tmpFile.Close()
	if err != nil {
		t.Error(err)
	}

	responseBody := []byte(fmt.Sprintf("{\"instance_path\" : \"%s\"}", tmpFile.Name()))
	go http.Serve(deaServerListener,
		dummyDeaHandler{t, expRequest, &responseBody}) // thread.
	time.Sleep(2 * time.Millisecond)

	// Start writing content to the temp file in a separate thread.
	go dump(tmpFile, t, 10) // thread.
	time.Sleep(1 * time.Second)

	response, err := http.Get("http://localhost:1242/path?tail")
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 200 {
		t.Fail()
	}

	// Check transfer encoding.
	te := response.TransferEncoding
	if len(te) != 1 || te[0] != "chunked" {
		t.Fail()
	}

	body := make([]byte, 100)
	_, err = response.Body.Read(body)
	matched, _ := regexp.Match("blah", body)
	if !matched {
		t.Fail()
	}

	// Clean up.
	if err = os.Remove(tmpFile.Name()); err != nil {
		t.Fail()
	}
	deaServerListener.Close()
	dirServerListener.Close()
	time.Sleep(2 * time.Millisecond)
}

func TestHandler_ServeHTTP_DumpFile(t *testing.T) {
	// Start mock dir server in a separate thread and wait for it to start.
	address := "localhost:" + strconv.Itoa(1242)
	dirServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	go startServer(&dirServerListener, "localhost", 1243, 2) // thread.
	time.Sleep(2 * time.Millisecond)

	// Start mock dea server in a separate thread and wait for it to start.
	address = "localhost:" + strconv.Itoa(1243)
	deaServerListener, err := net.Listen("tcp", address)
	if err != nil {
		t.Error(err)
	}
	expRequest, _ := http.NewRequest("GET", "http://localhost:1243/path", nil)

	// Create temp file for this unit test.
	tmpFile, err := ioutil.TempFile("", "testfile_")
	if err != nil {
		t.Fail()
	}
	err = tmpFile.Close()
	if err != nil {
		t.Error(err)
	}
	var dump bytes.Buffer
	for index := 0; index < 1000; index++ {
		dump.WriteString("A")
	}
	err = ioutil.WriteFile(tmpFile.Name(), []byte(dump.String()), 0600)
	if err != nil {
		t.Fail()
	}

	responseBody := []byte(fmt.Sprintf("{\"instance_path\" : \"%s\"}", tmpFile.Name()))
	go http.Serve(deaServerListener,
		dummyDeaHandler{t, expRequest, &responseBody}) // thread.
	time.Sleep(2 * time.Millisecond)

	response, err := http.Get("http://localhost:1242/path")
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 200 {
		t.Fail()
	}

	// Check body.
	body, err := getBody(response)
	if err != nil {
		t.Error(err)
	}
	if string(*body) != dump.String() {
		t.Fail()
	}

	// Clean up.
	if err = os.Remove(tmpFile.Name()); err != nil {
		t.Fail()
	}
	deaServerListener.Close()
	dirServerListener.Close()
	time.Sleep(2 * time.Millisecond)
}
