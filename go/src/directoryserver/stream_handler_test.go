package directoryserver

import (
	"bufio"
	"fmt"
	"io"
	"io/ioutil"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/go-check/check"
)

type StreamHandlerSuite struct {
	FileName string
	Handler  *StreamHandler
}

var _ = check.Suite(&StreamHandlerSuite{})

func (s *StreamHandlerSuite) SetUpTest(c *check.C) {
	s.FileName = s.TempFileName(c)
}

func (s *StreamHandlerSuite) TearDownTest(c *check.C) {
	os.Remove(s.FileName)

	if s.Handler != nil {
		s.Handler = nil
	}
}

func (s *StreamHandlerSuite) Printf(c *check.C, format string, a ...interface{}) {
	f, err := os.OpenFile(s.FileName, os.O_RDWR|os.O_APPEND, 0600)
	c.Assert(err, check.IsNil)

	fmt.Fprintf(f, format, a...)

	f.Sync()
	f.Close()
}

func (s *StreamHandlerSuite) TempFileName(c *check.C) string {
	f, err := ioutil.TempFile("", "stream-handler-suite")
	c.Assert(err, check.IsNil)
	f.Close()
	return f.Name()
}

type PanicReportingHandler struct {
	Checker *check.C
	Handler http.Handler
}

func (p *PanicReportingHandler) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	defer func() {
		err := recover()
		p.Checker.Assert(err, check.IsNil)
	}()

	p.Handler.ServeHTTP(rw, req)
}

func (s *StreamHandlerSuite) BuildFile(c *check.C) *os.File {
	f, err := os.Open(s.FileName)
	c.Assert(err, check.IsNil)

	_, err = f.Seek(0, os.SEEK_END)
	c.Assert(err, check.IsNil)

	return f
}

func (s *StreamHandlerSuite) BuildHandler(f *os.File) *StreamHandler {
	return &StreamHandler{
		File:          f,
		FlushInterval: 1 * time.Millisecond,
		// Large idle timeout is needed to avoid
		// flaky test behaviour when system is under load.
		IdleTimeout: 5 * time.Minute,
	}
}

func (s *StreamHandlerSuite) GetFromHandler(c *check.C, h *StreamHandler) *http.Response {
	s.Handler = h

	panicReportingHandler := &PanicReportingHandler{
		Checker: c,
		Handler: h,
	}

	x := http.Server{
		Handler: panicReportingHandler,
	}

	l, err := net.Listen("tcp", "localhost:0")
	c.Assert(err, check.IsNil)

	go x.Serve(l)
	defer l.Close()

	res, err := http.Get(fmt.Sprintf("http://%s/", l.Addr()))
	c.Assert(err, check.IsNil)

	return res
}

func (s *StreamHandlerSuite) Get(c *check.C) *http.Response {
	f := s.BuildFile(c)
	h := s.BuildHandler(f)
	return s.GetFromHandler(c, h)
}

func (s *StreamHandlerSuite) TestStream(c *check.C) {
	res := s.Get(c)
	c.Check(res.StatusCode, check.Equals, 200)

	// The header was already sent, now write something to the file
	s.Printf(c, "hello\n")

	r := bufio.NewReader(res.Body)
	l, err := r.ReadString('\n')
	c.Check(err, check.IsNil)
	c.Check(l, check.Equals, "hello\n")
}

func (s *StreamHandlerSuite) TestStreamFromCurrentPosition(c *check.C) {
	s.Printf(c, "hello\n")

	res := s.Get(c)
	c.Check(res.StatusCode, check.Equals, 200)

	s.Printf(c, "world\n")

	r := bufio.NewReader(res.Body)
	l, err := r.ReadString('\n')
	c.Check(err, check.IsNil)
	c.Check(l, check.Equals, "world\n")
}

func (s *StreamHandlerSuite) TestStreamFlushesBeforeTailing(c *check.C) {
	s.Printf(c, "hello\n")

	f, err := os.Open(s.FileName)
	c.Assert(err, check.IsNil)

	_, err = f.Seek(3, os.SEEK_SET)
	c.Assert(err, check.IsNil)

	h := s.BuildHandler(f)
	res := s.GetFromHandler(c, h)
	c.Check(res.StatusCode, check.Equals, 200)

	r := bufio.NewReader(res.Body)

	l, err := r.ReadString('\n')
	c.Check(err, check.IsNil)
	c.Check(l, check.Equals, "lo\n")

	s.Printf(c, "world\n")

	l, err = r.ReadString('\n')
	c.Check(err, check.IsNil)
	c.Check(l, check.Equals, "world\n")
}

func (s *StreamHandlerSuite) TestStreamWithIdleTimeout(c *check.C) {
	var l string
	var err error

	f := s.BuildFile(c)

	handler := &StreamHandler{
		File:          f,
		FlushInterval: 1 * time.Millisecond,
		IdleTimeout:   200 * time.Millisecond,
	}

	res := s.GetFromHandler(c, handler)
	c.Check(res.StatusCode, check.Equals, 200)

	r := bufio.NewReader(res.Body)

	// Write before timing out
	time.Sleep(15 * time.Millisecond)
	s.Printf(c, "hi there!\n")

	// Read the write
	l, _ = r.ReadString('\n')
	c.Check(l, check.Equals, "hi there!\n")

	// Write after timing out
	time.Sleep(250 * time.Millisecond)

	// Wait again to ensure the timeout logic is no longer in use
	time.Sleep(250 * time.Millisecond)

	s.Printf(c, "what?\n")

	// Read an unexepected EOF
	_, err = r.ReadString('\n')
	c.Check(err, check.Equals, io.ErrUnexpectedEOF)
}

func (s *StreamHandlerSuite) TestStreamUntilRenamed(c *check.C) {
	var l string
	var err error

	res := s.Get(c)
	c.Check(res.StatusCode, check.Equals, 200)

	r := bufio.NewReader(res.Body)

	// Write before rename
	s.Printf(c, "hello\n")

	// Read bytes written before rename
	l, err = r.ReadString('\n')
	c.Check(err, check.IsNil)
	c.Check(l, check.Equals, "hello\n")

	// Rename
	y := s.TempFileName(c)
	err = os.Rename(s.FileName, y)
	c.Assert(err, check.IsNil)

	// Read EOF
	l, err = r.ReadString('\n')
	c.Check(err, check.Equals, io.EOF)
	c.Check(l, check.Equals, "")
}

func (s *StreamHandlerSuite) TestStreamUntilRemoved(c *check.C) {
	var l string
	var err error

	// Create a second file in the same directory
	tbd := filepath.Join(filepath.Dir(s.FileName), "to_be_deleted")
	_, err = os.Create(tbd)
	c.Check(err, check.IsNil)

	res := s.Get(c)
	c.Check(res.StatusCode, check.Equals, 200)

	r := bufio.NewReader(res.Body)

	// Write before remove
	s.Printf(c, "hello\n")

	// Remove second file - this should not cause a fail
	err = os.Remove(tbd)
	c.Check(err, check.IsNil)

	// Read bytes written before remove
	l, err = r.ReadString('\n')
	c.Check(err, check.IsNil)
	c.Check(l, check.Equals, "hello\n")

	// Remove
	err = os.Remove(s.FileName)
	c.Assert(err, check.IsNil)

	// Read EOF
	l, err = r.ReadString('\n')
	c.Check(err, check.Not(check.IsNil))
	c.Check(l, check.Equals, "")
}
