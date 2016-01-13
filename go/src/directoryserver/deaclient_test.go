package directoryserver

import (
	"fmt"
	"io/ioutil"
	"github.com/go-check/check"
	"net"
	"net/http"
	"strconv"
	"strings"
)

type DeaClientSuite struct {
	DeaListener net.Listener
}

var _ = check.Suite(&DeaClientSuite{})

func (s *DeaClientSuite) SetUpTest(c *check.C) {
	// Nothing to see...
}

func (s *DeaClientSuite) TearDownTest(c *check.C) {
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

func (s *DeaClientSuite) TestDeaNotStarted(c *check.C) {
	s.StartDea(http.NotFoundHandler())
	s.StopDea()

	r := s.Get("/")
	c.Check(r.StatusCode, check.Equals, http.StatusInternalServerError)
	c.Check(readBody(r), check.Matches, ".*unreachable")
}

func (s *DeaClientSuite) TestDeaStatusOK(c *check.C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{ "instance_path": "/tmp/fuz" }`)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, check.Equals, http.StatusOK)
	c.Check(readBody(r), check.Equals, "/tmp/fuz")
}

func (s *DeaClientSuite) TestDeaStatusInternalServerError(c *check.C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintln(w, `internal server error`)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, check.Equals, http.StatusInternalServerError)
	c.Check(readBody(r), check.Matches, "internal server error")
}

func (s *DeaClientSuite) TestDeaStatusInternalServerErrorHeader(c *check.C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Hello", "World")
		w.WriteHeader(http.StatusInternalServerError)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, check.Equals, http.StatusInternalServerError)
	c.Check(r.Header.Get("X-Hello"), check.Equals, "World")
}

func (s *DeaClientSuite) TestDeaRequestPath(c *check.C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{ "instance_path": "%s" }`, r.URL.String())
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/some/path/?query")
	c.Check(r.StatusCode, check.Equals, http.StatusOK)
	c.Check(readBody(r), check.Equals, "/some/path/?query")
}

func (s *DeaClientSuite) TestDeaInvalidJson(c *check.C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{ "instance_path": xxxx }`)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, check.Equals, http.StatusInternalServerError)
	c.Check(readBody(r), check.Matches, ".*invalid JSON")
}

func (s *DeaClientSuite) TestDeaInvalidJsonField(c *check.C) {
	f := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{ "other_instance_path": "/tmp/fuz" }`)
	}

	s.StartDea(http.HandlerFunc(f))

	r := s.Get("/")
	c.Check(r.StatusCode, check.Equals, http.StatusInternalServerError)
	c.Check(readBody(r), check.Matches, ".*invalid JSON")
}
