package directoryserver

import (
	"github.com/go-check/check"
	"time"
)

type testWriteFlusher struct {
	WriteCounter int
	FlushCounter int
}

func (x *testWriteFlusher) Write(data []byte) (int, error) {
	x.WriteCounter += len(data)
	return len(data), nil
}

func (x *testWriteFlusher) Flush() {
	x.FlushCounter++
}

type MaxLatencyWriterSuite struct{}

var _ = check.Suite(&MaxLatencyWriterSuite{})

func (s *MaxLatencyWriterSuite) TestWrite(c *check.C) {
	x := &testWriteFlusher{}
	y := NewMaxLatencyWriter(x, 10*time.Millisecond)

	c.Check(x.WriteCounter, check.Equals, 0)

	y.Write([]byte("x"))

	c.Check(x.WriteCounter, check.Equals, 1)

	y.Stop()
}

func (s *MaxLatencyWriterSuite) TestFlush(c *check.C) {
	x := &testWriteFlusher{}
	y := NewMaxLatencyWriter(x, 10*time.Millisecond)

	y.writeLock.Lock()
	c.Check(x.FlushCounter, check.Equals, 0)
	y.writeLock.Unlock()

	time.Sleep(15 * time.Millisecond)

	y.writeLock.Lock()
	c.Check(x.FlushCounter, check.Equals, 1)
	y.writeLock.Unlock()

	y.Stop()
}

func (s *MaxLatencyWriterSuite) TestStop(c *check.C) {
	x := &testWriteFlusher{}
	y := NewMaxLatencyWriter(x, 10*time.Millisecond)

	c.Check(x.FlushCounter, check.Equals, 0)

	y.Stop()

	time.Sleep(15 * time.Millisecond)

	c.Check(x.FlushCounter, check.Equals, 0)
}

func (s *MaxLatencyWriterSuite) TestDoubleStop(c *check.C) {
	x := &testWriteFlusher{}
	y := NewMaxLatencyWriter(x, 10*time.Millisecond)

	c.Check(x.FlushCounter, check.Equals, 0)

	y.Stop()
	y.Stop()

	time.Sleep(15 * time.Millisecond)

	c.Check(x.FlushCounter, check.Equals, 0)
}
