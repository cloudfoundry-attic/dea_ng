package directoryserver

import (
	"fmt"
	"io/ioutil"
	. "launchpad.net/gocheck"
	"net"
	"net/http"
	"strconv"
	"strings"
)

type DeaClientSuite struct {
	DeaListener net.Listener
}

var _ = Suite(&DeaClientSuite{})

func (s *DeaClientSuite) SetUpTest(c *C) {
	// Nothing to see...
}

func (s *DeaClientSuite) TearDownTest(c *C) {
	s.StopDea()
}

func (s *DeaClientSuite) StartDea(h http.Handler) {
	l, _, _ := startTestServer(h)
	s.DeaListener = l
}

func (s *DeaClientSuite) StopDea() {
	if s.DeaListener != nil {
		s.DeaListener.Close()
	}
}

func (s *DeaClientSuite) Get(path string) *http.Response {
	hs, ps, err := net.SplitHostPort(s.DeaListener.Addr().String())
	if err != nil {
		panic(err)
	}

	h := hs
	p, _ := strconv.Atoi(ps)
	d := &DeaClient{Host: h, Port: uint16(p)}

	f := func(w http.ResponseWriter, r *http.Request) {
		p, err := d.LookupPath(w, r)
		if err != nil {
			return
		}

		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, p)
	}

	l, hx, px := startTestServer(http.HandlerFunc(f))
	defer l.Close()

	r, err := http.Get(fmt.Sprintf("http://%s:%d%s", hx, px, path))
	if err != nil {
		panic(err)
	}

	return r
}

func readBody(r *http.Response) string {
	b, err := ioutil.ReadAll(r.Body)
	if err != nil {
		panic(err)
	}

	r.Body.Close()

	return strings.TrimSpace(string(b))
}

func (s *DeaClientSuite) TestDeaNotStarted(c *C) {
	s.StartDea(http.NotFoundHandler())
	s.StopDea()

	r := s.Get("/")
	c.Check(r.StatusCode, Equals, http.StatusInternalServerError)
	c.Check(readBody(r), Matches, ".*unreachable")
}

func (s *DeaClientSuite) TestDeaStatusOK(c *C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{ "instance_path": "/tmp/fuz" }`)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, Equals, http.StatusOK)
	c.Check(readBody(r), Equals, "/tmp/fuz")
}

func (s *DeaClientSuite) TestDeaStatusInternalServerError(c *C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintln(w, `internal server error`)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, Equals, http.StatusInternalServerError)
	c.Check(readBody(r), Matches, "internal server error")
}

func (s *DeaClientSuite) TestDeaStatusInternalServerErrorHeader(c *C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Hello", "World")
		w.WriteHeader(http.StatusInternalServerError)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, Equals, http.StatusInternalServerError)
	c.Check(r.Header.Get("X-Hello"), Equals, "World")
}

func (s *DeaClientSuite) TestDeaRequestPath(c *C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{ "instance_path": "%s" }`, r.URL.String())
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/some/path/?query")
	c.Check(r.StatusCode, Equals, http.StatusOK)
	c.Check(readBody(r), Equals, "/some/path/?query")
}

func (s *DeaClientSuite) TestDeaInvalidJson(c *C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{ "instance_path": xxxx }`)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, Equals, http.StatusInternalServerError)
	c.Check(readBody(r), Matches, ".*invalid JSON")
}

func (s *DeaClientSuite) TestDeaInvalidJsonField(c *C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{ "other_instance_path": "/tmp/fuz" }`)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, Equals, http.StatusInternalServerError)
	c.Check(readBody(r), Matches, ".*invalid JSON")
}
