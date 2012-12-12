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
	File *os.File
}

var _ = Suite(&StreamHandlerSuite{})

func (s *StreamHandlerSuite) SetUpTest(c *C) {
	s.CreateTempFile(c)
}

func (s *StreamHandlerSuite) TeardownTest(c *C) {
	s.RemoveTempFile(c)
}

func (s *StreamHandlerSuite) CreateTempFile(c *C) {
	f, err := ioutil.TempFile("", "stream-handler-suite")
	c.Assert(err, IsNil)

	s.File = f
}

func (s *StreamHandlerSuite) RemoveTempFile(c *C) {
	s.File.Close()
	os.Remove(s.File.Name())
}

func (s *StreamHandlerSuite) Get(c *C, h http.Handler) *http.Response {
	l, err := net.Listen("tcp", "localhost:")
	c.Assert(err, IsNil)

	x := http.Server{Handler: h}
	go x.Serve(l)
	defer l.Close()

	res, err := http.Get(fmt.Sprintf("http://%s/%s", l.Addr(), s.File.Name()))
	c.Assert(err, IsNil)

	return res
}

func (s *StreamHandlerSuite) TestNotFound(c *C) {
	s.RemoveTempFile(c)

	h := &StreamHandler{}
	res := s.Get(c, h)

	c.Check(res.StatusCode, Equals, 404)

	r := bufio.NewReader(res.Body)
	_, err := r.ReadString('\n')
	c.Check(err, Equals, io.EOF)
}

func (s *StreamHandlerSuite) TestStream(c *C) {
	h := &StreamHandler{FlushInterval: 1 * time.Millisecond}
	res := s.Get(c, h)

	c.Check(res.StatusCode, Equals, 200)

	// The header was already sent, now write something to the file
	fmt.Fprintf(s.File, "hello\n")

	r := bufio.NewReader(res.Body)
	l, err := r.ReadString('\n')
	c.Check(err, IsNil)
	c.Check(l, Equals, "hello\n")
}
