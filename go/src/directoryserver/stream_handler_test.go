package directoryserver

import (
	"bufio"
	"fmt"
	"io"
	"io/ioutil"
	. "launchpad.net/gocheck"
	"net"
	"net/http"
	"os"
	"time"
)

type StreamHandlerSuite struct {
	FileName string
	Handler  *StreamHandler
}

var _ = Suite(&StreamHandlerSuite{})

func (s *StreamHandlerSuite) SetUpTest(c *C) {
	s.FileName = s.TempFileName(c)
}

func (s *StreamHandlerSuite) TearDownTest(c *C) {
	os.Remove(s.FileName)

	if s.Handler != nil {
		s.Handler.File.Close()
		s.Handler = nil
	}
}

func (s *StreamHandlerSuite) Printf(c *C, format string, a ...interface{}) {
	f, err := os.OpenFile(s.FileName, os.O_RDWR|os.O_APPEND, 0600)
	c.Assert(err, IsNil)

	fmt.Fprintf(f, format, a...)

	f.Sync()
	f.Close()
}

func (s *StreamHandlerSuite) TempFileName(c *C) string {
	f, err := ioutil.TempFile("", "stream-handler-suite")
	c.Assert(err, IsNil)
	f.Close()
	return f.Name()
}

type PanicReportingHandler struct {
	Checker *C
	Handler http.Handler
}

func (p *PanicReportingHandler) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	defer func() {
		err := recover()
		p.Checker.Assert(err, IsNil)
	}()

	p.Handler.ServeHTTP(rw, req)
}

func (s *StreamHandlerSuite) GetFile(c *C, f *os.File) *http.Response {
	s.Handler = &StreamHandler{
		File:          f,
		FlushInterval: 1 * time.Millisecond,
		IdleTimeout:   20 * time.Millisecond,
	}

	l, err := net.Listen("tcp", "localhost:0")
	c.Assert(err, IsNil)

	panicReportingHandler := &PanicReportingHandler{
		Checker: c,
		Handler: s.Handler,
	}

	x := http.Server{Handler: panicReportingHandler}
	go x.Serve(l)
	defer l.Close()

	res, err := http.Get(fmt.Sprintf("http://%s/", l.Addr()))
	c.Assert(err, IsNil)

	return res
}

func (s *StreamHandlerSuite) Get(c *C) *http.Response {
	f, err := os.Open(s.FileName)
	c.Assert(err, IsNil)

	_, err = f.Seek(0, os.SEEK_END)
	c.Assert(err, IsNil)

	return s.GetFile(c, f)
}

func (s *StreamHandlerSuite) TestStream(c *C) {
	res := s.Get(c)
	c.Check(res.StatusCode, Equals, 200)

	// The header was already sent, now write something to the file
	s.Printf(c, "hello\n")

	r := bufio.NewReader(res.Body)
	l, err := r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "hello\n")
}

func (s *StreamHandlerSuite) TestStreamFromCurrentPosition(c *C) {
	s.Printf(c, "hello\n")

	res := s.Get(c)
	c.Check(res.StatusCode, Equals, 200)

	s.Printf(c, "world\n")

	r := bufio.NewReader(res.Body)
	l, err := r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "world\n")
}

func (s *StreamHandlerSuite) TestStreamFlushesBeforeTailing(c *C) {
	s.Printf(c, "hello\n")

	f, err := os.Open(s.FileName)
	c.Assert(err, IsNil)

	_, err = f.Seek(3, os.SEEK_SET)
	c.Assert(err, IsNil)

	res := s.GetFile(c, f)
	c.Check(res.StatusCode, Equals, 200)

	r := bufio.NewReader(res.Body)

	l, err := r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "lo\n")

	s.Printf(c, "world\n")

	l, err = r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "world\n")
}

func (s *StreamHandlerSuite) TestStreamWithIdleTimeout(c *C) {
	var l string
	var err error

	res := s.Get(c)
	c.Check(res.StatusCode, Equals, 200)

	r := bufio.NewReader(res.Body)

	// Write before timing out
	time.Sleep(15 * time.Millisecond)
	s.Printf(c, "hi there!\n")

	// Read the write
	l, _ = r.ReadString('\n')
	c.Check(l, Equals, "hi there!\n")

	// Write after timing out
	time.Sleep(25 * time.Millisecond)

	// Wait again to ensure the timeout logic is no longer in use
	time.Sleep(25 * time.Millisecond)

	s.Printf(c, "what?\n")

	// Read an unexepected EOF
	_, err = r.ReadString('\n')
	c.Check(err, Equals, io.ErrUnexpectedEOF)
}

func (s *StreamHandlerSuite) TestStreamUntilRenamed(c *C) {
	var l string
	var err error

	res := s.Get(c)
	c.Check(res.StatusCode, Equals, 200)

	r := bufio.NewReader(res.Body)

	// Write before rename
	s.Printf(c, "hello\n")

	// Read bytes written before rename
	l, err = r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "hello\n")

	// Rename
	y := s.TempFileName(c)
	err = os.Rename(s.FileName, y)
	c.Assert(err, IsNil)

	// Read EOF
	l, err = r.ReadString('\n')
	c.Check(err, Equals, io.EOF)
	c.Check(l, Equals, "")
}

func (s *StreamHandlerSuite) TestStreamUntilRemoved(c *C) {
	var l string
	var err error

	res := s.Get(c)
	c.Check(res.StatusCode, Equals, 200)

	r := bufio.NewReader(res.Body)

	// Write before rename
	s.Printf(c, "hello\n")

	// Read bytes written before rename
	l, err = r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "hello\n")

	// Remove
	err = os.Remove(s.FileName)
	c.Assert(err, IsNil)

	// Read EOF
	l, err = r.ReadString('\n')
	c.Check(err, Equals, io.EOF)
	c.Check(l, Equals, "")
}
