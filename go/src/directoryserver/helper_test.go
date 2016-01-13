package directoryserver

import (
	"io/ioutil"
	"net"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"github.com/go-check/check"
)

func Test(t *testing.T) { check.TestingT(t) }

func getBody(response *http.Response) ([]byte, error) {
	defer response.Body.Close()
	return ioutil.ReadAll(response.Body)
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
	t            *check.C
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

func startTestServer(h http.Handler) (net.Listener, string, uint16) {
	l, err := net.Listen("tcp", "localhost:0")
	if err != nil {
		panic(err)
	}

	x := http.Server{Handler: h}
	go x.Serve(l)

	hs, ps, err := net.SplitHostPort(l.Addr().String())
	if err != nil {
		panic(err)
	}

	hx := hs
	px, _ := strconv.Atoi(ps)

	return l, hx, uint16(px)
}
