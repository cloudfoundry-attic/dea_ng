package directoryserver

import (
	"bytes"
	"fmt"
	"github.com/go-check/check"
	"io"
	"io/ioutil"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func dump(file *os.File, t *check.C, numLines int) error {
	handle, err := os.OpenFile(file.Name(), syscall.O_WRONLY, 0666)
	if err != nil {
		t.Error(err)
	}

	for i := 0; i < numLines; i++ {
		_, err = handle.WriteString(fmt.Sprintf("blah%d", i))
		if err != nil {
			t.Error(err)
		}
		time.Sleep(250 * time.Millisecond)
	}

	err = handle.Close()
	return err
}

type denyingDeaHandler struct {
	t            *check.C
	expRequest   *http.Request
	responseBody *[]byte
}

func (handler denyingDeaHandler) ServeHTTP(w http.ResponseWriter,
	r *http.Request) {
	if !checkRequest(r, handler.expRequest) {
		handler.t.Fail()
	}

	w.Header().Set("Content-Length", strconv.
		Itoa(len(*(handler.responseBody))))
	w.WriteHeader(400)
	w.Write(*(handler.responseBody))
}

type DirectoryServerSuite struct{}

var _ = check.Suite(&DirectoryServerSuite{})

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_RequestToDeaFailed(t *check.C) {
	lc, hc, pc := startTestServer(http.NotFoundHandler())
	lc.Close()

	h := handler{
		deaHost:          hc,
		deaPort:          pc,
		streamingTimeout: 1,
		deaClient:        &DeaClient{Host: hc, Port: pc},
	}

	ld, hd, pd := startTestServer(h)
	defer ld.Close()

	response, err := http.Get(fmt.Sprintf("http://%s:%d/path", hd, pd))
	if err != nil {
		t.Error(err)
	}

	if response.StatusCode != 500 {
		t.Fail()
	}
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_RequestDeniedByDea(t *check.C) {
	responseBody := []byte("{\"instance_path\" : \"dummy\"}")
	fc := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write(responseBody)
	}

	lc, hc, pc := startTestServer(http.HandlerFunc(fc))
	defer lc.Close()

	h := handler{
		deaHost:          hc,
		deaPort:          pc,
		streamingTimeout: 1,
		deaClient:        &DeaClient{Host: hc, Port: pc},
	}

	ld, hd, pd := startTestServer(h)
	defer ld.Close()

	response, err := http.Get(fmt.Sprintf("http://%s:%d/path", hd, pd))
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
	if bytes.Compare(body, responseBody) != 0 {
		t.Fail()
	}
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_EntityNotFound(t *check.C) {
	responseBody := []byte("{\"instance_path\" : \"dummy\"}")
	fc := func(w http.ResponseWriter, r *http.Request) {
		w.Write(responseBody)
	}

	lc, hc, pc := startTestServer(http.HandlerFunc(fc))
	defer lc.Close()

	h := handler{
		deaHost:          hc,
		deaPort:          pc,
		streamingTimeout: 1,
		deaClient:        &DeaClient{Host: hc, Port: pc},
	}

	ld, hd, pd := startTestServer(h)
	defer ld.Close()

	response, err := http.Get(fmt.Sprintf("http://%s:%d/path", hd, pd))
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 400 {
		t.Fail()
	}

	// Check headers.
	if response.Header.Get("Content-Type") != "text/plain" {
		t.Fail()
	}
	if response.Header.Get("X-Cascade") != "pass" {
		t.Fail()
	}

	// Check body.
	body, err := getBody(response)
	if err != nil {
		t.Error(err)
	}
	if strings.ToLower(string(body)) != "entity not found.\n" {
		t.Fail()
	}
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_ReturnDirectoryListing(t *check.C) {
	// Create temp directory listing for this unit test.
	tmpDir, err := ioutil.TempDir("", "")
	if err != nil {
		t.Error(err)
	}
	_, err = ioutil.TempDir(tmpDir, "testdir_")
	if err != nil {
		t.Error(err)
	}
	tmpFile, err := ioutil.TempFile(tmpDir, "testfile_")
	if err != nil {
		t.Error(err)
	}
	err = tmpFile.Close()
	if err != nil {
		t.Error(err)
	}
	var dump bytes.Buffer
	for index := 0; index < 10000; index++ {
		dump.WriteString("A")
	}
	err = ioutil.WriteFile(tmpFile.Name(), []byte(dump.String()), 0600)
	if err != nil {
		t.Error(err)
	}

	responseBody := []byte(fmt.Sprintf(`{"instance_path": "%s"}`, tmpDir))
	fc := func(w http.ResponseWriter, r *http.Request) {
		w.Write(responseBody)
	}

	lc, hc, pc := startTestServer(http.HandlerFunc(fc))
	defer lc.Close()

	h := handler{
		deaHost:          hc,
		deaPort:          pc,
		streamingTimeout: 1,
		deaClient:        &DeaClient{Host: hc, Port: pc},
	}

	ld, hd, pd := startTestServer(h)
	defer ld.Close()

	response, err := http.Get(fmt.Sprintf("http://%s:%d/path", hd, pd))
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 200 {
		t.Fail()
	}

	// Check headers.
	if response.Header.Get("Content-Type") != "text/plain" {
		t.Fail()
	}

	// Check body.
	body, err := getBody(response)
	if err != nil {
		t.Error(err)
	}

	pattern := "\\s*testdir_.*/\\s*-\\n\\s*testfile_.*\\s*9\\.8K"
	matched, _ := regexp.Match(pattern, body)
	if !matched {
		t.Fail()
	}

	// Clean up.
	if err = os.RemoveAll(tmpDir); err != nil {
		t.Error(err)
	}
}

func fetchStreamingResponse(t *check.C, url string) (*http.Response, string) {
	// Create temp file for this unit test.
	tmpFile, err := ioutil.TempFile("", "testfile_")
	if err != nil {
		t.Error(err)
	}

	err = tmpFile.Close()
	if err != nil {
		t.Error(err)
	}

	responseBody := []byte(fmt.Sprintf(`{"instance_path": "%s"}`, tmpFile.Name()))
	fc := func(w http.ResponseWriter, r *http.Request) {
		w.Write(responseBody)
	}

	lc, hc, pc := startTestServer(http.HandlerFunc(fc))
	defer lc.Close()

	h := handler{
		deaHost:          hc,
		deaPort:          pc,
		streamingTimeout: 1,
		deaClient:        &DeaClient{Host: hc, Port: pc},
	}

	ld, hd, pd := startTestServer(h)
	defer ld.Close()

	// Start writing content to the temp file in a separate thread.
	go dump(tmpFile, t, 10) // thread.
	time.Sleep(1 * time.Second)

	response, err := http.Get(fmt.Sprintf("http://%s:%d%s", hd, pd, url))
	if err != nil {
		t.Error(err)
	}

	body := make([]byte, 100)
	_, err = response.Body.Read(body)
	if err != nil {
		// If no data comes through before timeout expires
		// stream handler will just close the connection
		// causing EOF error which is ok.
		if err != io.EOF && err != io.ErrUnexpectedEOF {
			t.Error(err)
		}
	}

	if err = os.Remove(tmpFile.Name()); err != nil {
		t.Error(err)
	}

	return response, string(body)
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_StreamFile(t *check.C) {
	response, body := fetchStreamingResponse(t, "/path?tail=&tail_offset=0")
	t.Check(response.StatusCode, check.Equals, 200)

	// Check transfer encoding.
	te := response.TransferEncoding
	if len(te) != 1 || te[0] != "chunked" {
		t.Fail()
	}

	matched, _ := regexp.MatchString("^blah[^12]", body)
	if !matched {
		t.Fail()
	}
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_StreamFileFromValidOffset(t *check.C) {
	response, body := fetchStreamingResponse(t, "/path?tail=&tail_offset=0")
	t.Check(response.StatusCode, check.Equals, 200)

	// Check transfer encoding.
	te := response.TransferEncoding
	if len(te) != 1 || te[0] != "chunked" {
		t.Fail()
	}

	matched, _ := regexp.MatchString("^blah0blah1blah2", body)
	if !matched {
		t.Fail()
	}
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_StreamFileFromOffsetLargerThanFile(t *check.C) {
	response, body := fetchStreamingResponse(t, "/path?tail=&tail_offset=1000000")
	t.Check(response.StatusCode, check.Equals, 200)

	trimmed_body := strings.Trim(body, string(0))
	t.Check(len(trimmed_body), check.Equals, 0)
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_StreamFileFromOffsetThatOverflowsInt32(t *check.C) {
	response, body := fetchStreamingResponse(t, "/path?tail=&tail_offset=1000000000000000000000000000000")
	t.Check(response.StatusCode, check.Equals, 500)
	t.Check(body, check.Matches, ".*Tail offset must be a positive integer.*")
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_StreamFileFromNonNumericOffset(t *check.C) {
	response, body := fetchStreamingResponse(t, "/path?tail=&tail_offset=abc")
	t.Check(response.StatusCode, check.Equals, 500)
	t.Check(body, check.Matches, ".*Tail offset must be a positive integer.*")
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_StreamFileFromNegavtiveOffset(t *check.C) {
	response, body := fetchStreamingResponse(t, "/path?tail=&tail_offset=-1")
	t.Check(response.StatusCode, check.Equals, 500)
	t.Check(body, check.Matches, ".*Tail offset must be a positive integer.*")
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_DumpFile(t *check.C) {
	// Create temp file for this unit test.
	tmpFile, err := ioutil.TempFile("", "testfile_")
	if err != nil {
		t.Error(err)
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
		t.Error(err)
	}

	responseBody := []byte(fmt.Sprintf(`{"instance_path": "%s"}`, tmpFile.Name()))
	fc := func(w http.ResponseWriter, r *http.Request) {
		w.Write(responseBody)
	}

	lc, hc, pc := startTestServer(http.HandlerFunc(fc))
	defer lc.Close()

	h := handler{
		deaHost:          hc,
		deaPort:          pc,
		streamingTimeout: 1,
		deaClient:        &DeaClient{Host: hc, Port: pc},
	}

	ld, hd, pd := startTestServer(h)
	defer ld.Close()

	response, err := http.Get(fmt.Sprintf("http://%s:%d/path", hd, pd))
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
	if string(body) != dump.String() {
		t.Fail()
	}

	// Clean up.
	if err = os.Remove(tmpFile.Name()); err != nil {
		t.Error(err)
	}
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_DumpFile_RangeQuery(t *check.C) {
	// Create temp file for this unit test.
	tmpFile, err := ioutil.TempFile("", "testfile_")
	if err != nil {
		t.Error(err)
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
		t.Error(err)
	}

	responseBody := []byte(fmt.Sprintf(`{"instance_path": "%s"}`, tmpFile.Name()))
	fc := func(w http.ResponseWriter, r *http.Request) {
		w.Write(responseBody)
	}

	lc, hc, pc := startTestServer(http.HandlerFunc(fc))
	defer lc.Close()

	h := handler{
		deaHost:          hc,
		deaPort:          pc,
		streamingTimeout: 1,
		deaClient:        &DeaClient{Host: hc, Port: pc},
	}

	ld, hd, pd := startTestServer(h)
	defer ld.Close()

	request, err := http.NewRequest("GET", fmt.Sprintf("http://%s:%d/path", hd, pd), nil)
	if err != nil {
		t.Error(err)
	}

	request.Header.Set("Range", "bytes=5-10")

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 206 {
		t.Fail()
	}

	// Check headers.
	headerValue := response.Header["Content-Range"]
	if len(headerValue) != 1 || headerValue[0] != "bytes 5-10/1000" {
		t.Fail()
	}

	// Check body.
	body, err := getBody(response)
	if err != nil {
		t.Error(err)
	}
	if string(body) != dump.String()[5:11] {
		t.Fail()
	}

	// Clean up.
	if err = os.Remove(tmpFile.Name()); err != nil {
		t.Error(err)
	}
}

func (s *DirectoryServerSuite) TestHandler_ServeHTTP_DumpFile_FailedRangeQuery(t *check.C) {
	// Create temp file for this unit test.
	tmpFile, err := ioutil.TempFile("", "testfile_")
	if err != nil {
		t.Error(err)
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
		t.Error(err)
	}

	responseBody := []byte(fmt.Sprintf(`{"instance_path": "%s"}`, tmpFile.Name()))
	fc := func(w http.ResponseWriter, r *http.Request) {
		w.Write(responseBody)
	}

	lc, hc, pc := startTestServer(http.HandlerFunc(fc))
	defer lc.Close()

	h := handler{
		deaHost:          hc,
		deaPort:          pc,
		streamingTimeout: 1,
		deaClient:        &DeaClient{Host: hc, Port: pc},
	}

	ld, hd, pd := startTestServer(h)
	defer ld.Close()

	request, err := http.NewRequest("GET", fmt.Sprintf("http://%s:%d/path", hd, pd), nil)
	if err != nil {
		t.Error(err)
	}

	request.Header.Set("Range", "bytes=10000-")

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Error(err)
	}

	// Check status code.
	if response.StatusCode != 416 {
		t.Fail()
	}

	// Clean up.
	if err = os.Remove(tmpFile.Name()); err != nil {
		t.Error(err)
	}
}
