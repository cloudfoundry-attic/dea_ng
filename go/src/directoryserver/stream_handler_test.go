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
	File    *os.File
	Handler *StreamHandler
}

var _ = Suite(&StreamHandlerSuite{})

func (s *StreamHandlerSuite) SetUpTest(c *C) {
	s.CreateTempFile(c)
}

func (s *StreamHandlerSuite) TearDownTest(c *C) {
	s.RemoveTempFile(c)

	if s.Handler != nil {
		s.Handler.File.Close()
		s.Handler = nil
	}
}

func (s *StreamHandlerSuite) CreateTempFile(c *C) {
	f, err := os.OpenFile(s.TempFileName(c), os.O_RDWR, 0600)
	c.Assert(err, IsNil)

	s.File = f
}

func (s *StreamHandlerSuite) RemoveTempFile(c *C) {
	s.File.Close()
	os.Remove(s.File.Name())
}

func (s *StreamHandlerSuite) TempFileName(c *C) string {
	f, err := ioutil.TempFile("", "stream-handler-suite")
	c.Assert(err, IsNil)
	f.Close()
	return f.Name()
}

func (s *StreamHandlerSuite) Get(c *C) *http.Response {
	f, err := os.Open(s.File.Name())
	c.Assert(err, IsNil)

	_, err = f.Seek(0, os.SEEK_END)
	c.Assert(err, IsNil)

	s.Handler = &StreamHandler{
		File:          f,
		FlushInterval: 1 * time.Millisecond,
	}

	l, err := net.Listen("tcp", "localhost:")
	c.Assert(err, IsNil)

	x := http.Server{Handler: s.Handler}
	go x.Serve(l)
	defer l.Close()

	res, err := http.Get(fmt.Sprintf("http://%s/", l.Addr()))
	c.Assert(err, IsNil)

	return res
}

func (s *StreamHandlerSuite) TestStream(c *C) {
	res := s.Get(c)
	c.Check(res.StatusCode, Equals, 200)

	// The header was already sent, now write something to the file
	fmt.Fprintf(s.File, "hello\n")

	r := bufio.NewReader(res.Body)
	l, err := r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "hello\n")
}

func (s *StreamHandlerSuite) TestStreamFromCurrentPosition(c *C) {
	fmt.Fprintf(s.File, "hello\n")

	res := s.Get(c)
	c.Check(res.StatusCode, Equals, 200)

	fmt.Fprintf(s.File, "world\n")

	r := bufio.NewReader(res.Body)
	l, err := r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "world\n")
}

func (s *StreamHandlerSuite) TestStreamUntilRename(c *C) {
	var l string
	var err error

	res := s.Get(c)
	c.Check(res.StatusCode, Equals, 200)

	r := bufio.NewReader(res.Body)

	// Write before rename
	fmt.Fprintf(s.File, "hello\n")

	// Read bytes written before rename
	l, err = r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "hello\n")

	// Rename
	err = os.Rename(s.File.Name(), s.TempFileName(c))
	c.Assert(err, IsNil)

	// Write after rename
	fmt.Fprintf(s.File, "world\n")

	// Read EOF
	l, err = r.ReadString('\n')
	c.Check(err, Equals, io.EOF)
	c.Check(l, Equals, "")
}
