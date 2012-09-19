package directoryserver

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

type deaClient interface {
	Get(path string) (*http.Response, error)
}

type deaClientImpl struct {
	host       string
	port       uint16
	httpClient *http.Client
}

func (dc *deaClientImpl) ConstructDeaRequest(path string) (*http.Request, error) {
	url := fmt.Sprintf("http://%s:%d%s", dc.host, dc.port, path)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	return req, nil
}

func (dc *deaClientImpl) Get(path string) (*http.Response, error) {
	if dc.httpClient == nil {
		dc.httpClient = &http.Client{}
	}

	deaRequest, err := dc.ConstructDeaRequest(path)
	if err != nil {
		return nil, err
	}

	log.Printf("Sending HTTP request to DEA: %s", deaRequest)
	return dc.httpClient.Do(deaRequest)
}

func newDeaClient(host string, port uint16) deaClientImpl {
	return deaClientImpl{host: host, port: port}
}

type handler struct {
	deaHost          string
	deaPort          uint16
	deaClient        deaClient
	streamingTimeout uint32
}

func fileSizeFormat(size int64) string {
	if size >= (1 << 40) {
		return fmt.Sprintf("%.1fT", float64(size)/(1<<40))
	}

	if size >= (1 << 30) {
		return fmt.Sprintf("%.1fG", float64(size)/(1<<30))
	}

	if size >= (1 << 20) {
		return fmt.Sprintf("%.1fM", float64(size)/(1<<20))
	}

	if size >= (1 << 10) {
		return fmt.Sprintf("%.1fK", float64(size)/(1<<10))
	}

	return fmt.Sprintf("%dB", size)
}

func (h handler) writeEntityNotFound(writer http.ResponseWriter) {
	response := "Entity not found.\n"

	writer.Header()["Content-Length"] = []string{strconv.
		Itoa(len(response))}
	writer.Header()["Content-Type"] = []string{"text/plain"}
	writer.Header()["X-Cascade"] = []string{"pass"}

	writer.WriteHeader(400)

	fmt.Fprintf(writer, response)
}

func (h handler) writeDeaClientError(err *error, w http.ResponseWriter) {
	msgFormat := "Can't read the body of HTTP response"
	msgFormat += " from DEA due to error: %s"
	msg := fmt.Sprintf(msgFormat, (*err).Error())
	log.Print(msg)
	w.WriteHeader(500)
	fmt.Fprintf(w, msg)
}

func (h handler) writeServerError(err *error, w http.ResponseWriter) {
	msgFormat := "Can't serve request due to error: %s"
	msg := fmt.Sprintf(msgFormat, (*err).Error())
	log.Print(msg)
	w.WriteHeader(500)
	fmt.Fprintf(w, msg)
}

func (h handler) listDir(writer http.ResponseWriter, dirPath string) {
	entries, err := ioutil.ReadDir(dirPath)
	if err != nil {
		h.writeServerError(&err, writer)
		return
	}

	var bodyBuffer bytes.Buffer
	for _, entry := range entries {
		basename := entry.Name()

		var size string
		if entry.IsDir() {
			size = "-"
			basename += "/"
		} else {
			size = fileSizeFormat(entry.Size())
		}

		entryStr := fmt.Sprintf("%-35s %10s\n", basename, size)
		bodyBuffer.WriteString(entryStr)
	}

	body := bodyBuffer.Bytes()

	writer.Header()["Content-Type"] = []string{"text/plain"}
	writer.Header()["Content-Length"] = []string{strconv.
		Itoa(len(body))}

	writer.Write(body)
}

func set(fdSetPtr *syscall.FdSet, fd int) {
	(*fdSetPtr).Bits[fd/64] |= 1 << uint64(fd%64)
}

func isSet(fdSetPtr *syscall.FdSet, fd int) bool {
	return ((*fdSetPtr).Bits[fd/64] & (1 << uint64(fd%64))) != 0
}

func clearAll(fdSetPtr *syscall.FdSet) {
	for index, _ := range (*fdSetPtr).Bits {
		(*fdSetPtr).Bits[index] = 0
	}
}

func timeout(t time.Time, timeout uint32) bool {
	return time.Now().Sub(t).Seconds() > float64(timeout)
}

func (h handler) streamFile(writer http.ResponseWriter, path string) error {
	handle, err := os.Open(path)
	if err != nil {
		return err
	}

	// Seek to EOF.
	_, err = handle.Seek(0, 2)
	if err != nil {
		return err
	}

	reader := bufio.NewReader(handle)
	readBuffer := make([]byte, 4096)

	inotifyFd, err := syscall.InotifyInit()
	if err != nil {
		return err
	}

	watchDesc, err := syscall.InotifyAddWatch(inotifyFd, path, syscall.IN_MODIFY)
	if err != nil {
		return err
	}

	eventsBuffer := make([]byte, syscall.SizeofInotifyEvent*4096)

	selectTimeout := syscall.Timeval{}
	selectTimeout.Sec = int64(h.streamingTimeout)

	inotifyFdSet := syscall.FdSet{}
	lastWriteTime := time.Now()

	canScan := true
	for canScan && !timeout(lastWriteTime, h.streamingTimeout) {
		clearAll(&inotifyFdSet)
		set(&inotifyFdSet, inotifyFd)
		_, err := syscall.Select(inotifyFd+1, &inotifyFdSet,
			nil, nil, &selectTimeout)

		if err != nil {
			break
		}

		if !isSet(&inotifyFdSet, inotifyFd) {
			continue
		}

		numEventsBytes, err := syscall.Read(inotifyFd, eventsBuffer[0:])
		if numEventsBytes < syscall.SizeofInotifyEvent {
			if numEventsBytes < 0 {
				err = errors.New("inotify: read failed.")
			} else {
				err = errors.New("inotify: short read.")
			}

			break
		}

		var offset uint32 = 0
		for offset <= uint32(numEventsBytes-syscall.SizeofInotifyEvent) {
			event := (*syscall.InotifyEvent)(unsafe.
				Pointer(&eventsBuffer[offset]))

			n, err := reader.Read(readBuffer)
			if err != nil {
				// We ignore EOF error because
				// we would like to continue polling
				// the file until timeout.
				if err == io.EOF {
					err = nil
				}
				break
			}

			buffer := make([]byte, n)
			for index := 0; index < n; index++ {
				buffer[index] = readBuffer[index]
			}

			_, err = writer.Write(buffer)
			if err != nil {
				// Client has disconnected, so we don't proceed.
				canScan = false
				break
			}

			lastWriteTime = time.Now()
			// Move to the next event.
			offset += syscall.SizeofInotifyEvent + event.Len
		}
	}

	// The inotify watch gets automatically removed by the inotify system
	// when the file is removed. If the above loop times out, but the file
	// is removed only just before the if block below is executed, then the
	// removal of the watch below will throw an error as the watch
	// descriptor is obsolete. We ignore this error because it is harmless.
	syscall.InotifyRmWatch(inotifyFd, uint32(watchDesc))

	// Though we return the first error that occured, we still need to
	// attempt to close all the file descriptors.
	inotifyCloseErr := syscall.Close(inotifyFd)
	handleCloseErr := handle.Close()

	if err != nil {
		return err
	} else if inotifyCloseErr != nil {
		return inotifyCloseErr
	}

	return handleCloseErr
}

func (h handler) dumpFile(writer http.ResponseWriter, path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}

	writer.Header()["Content-Length"] = []string{strconv.
		FormatInt(info.Size(), 10)}

	handle, err := os.Open(path)
	if err != nil {
		return err
	}

	reader := bufio.NewReader(handle)
	readBuffer := make([]byte, 4096)

	for {
		n, err := reader.Read(readBuffer)
		if err != nil {
			if err == io.EOF {
				break
			}
			return err
		}

		buffer := make([]byte, n)
		for index := 0; index < n; index++ {
			buffer[index] = readBuffer[index]
		}

		_, err = writer.Write(buffer)
		if err != nil {
			// Client has disconnected, so we don't proceed.
			break
		}
	}

	return nil
}

func (h handler) listPath(request *http.Request, writer http.ResponseWriter,
	deaResponse *http.Response) {
	path, err := h.getPath(deaResponse)
	if err != nil {
		h.writeDeaClientError(&err, writer)
		return
	}

	info, err := os.Stat(*path)
	if err != nil {
		h.writeEntityNotFound(writer)
		return
	}

	if info.IsDir() {
		h.listDir(writer, *path)
	} else {
		tail := false
		for key, _ := range request.URL.Query() {
			if strings.ToLower(key) == "tail" {
				tail = true
				break
			}
		}

		if tail {
			err = h.streamFile(writer, *path)
		} else {
			err = h.dumpFile(writer, *path)
		}

		if err != nil {
			h.writeServerError(&err, writer)
		}
	}
}

func (h handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if h.deaClient == nil {
		dc := newDeaClient(h.deaHost, h.deaPort)
		h.deaClient = &dc
	}

	deaResponse, err := h.deaClient.Get(r.URL.String())
	if err != nil {
		h.writeDeaClientError(&err, w)
		return
	}

	log.Print("HTTP response from DEA: ", deaResponse)
	if deaResponse.StatusCode == 200 {
		h.listPath(r, w, deaResponse)
	} else {
		h.forwardDeaResponse(w, deaResponse)
	}
}

func (h handler) getPath(deaResponse *http.Response) (*string, error) {
	jsonBlob := make([]byte, (*deaResponse).ContentLength)
	_, err := (*deaResponse).Body.Read(jsonBlob)
	if err != nil {
		return nil, err
	}

	var jsonObj interface{}
	err = json.Unmarshal(jsonBlob, &jsonObj)
	if err != nil {
		return nil, err
	}

	path := jsonObj.(map[string]interface{})["instance_path"].(string)
	return &path, nil
}

func (h handler) forwardDeaResponse(w http.ResponseWriter,
	deaResponse *http.Response) {
	body := make([]byte, deaResponse.ContentLength)
	_, err := deaResponse.Body.Read(body)
	if err != nil {
		h.writeServerError(&err, w)
		return
	}

	for header, value := range (*deaResponse).Header {
		w.Header()[header] = value
	}

	w.WriteHeader(deaResponse.StatusCode)
	w.Write(body)
}

func startServer(listener *net.Listener, deaHost string, deaPort uint16,
	streamingTimeout uint32) error {
	h := handler{}
	h.deaHost = deaHost
	h.deaPort = deaPort
	h.streamingTimeout = streamingTimeout

	return http.Serve(*listener, h)
}

func Start(host string, port uint16, deaPort uint16, streamingTimeout uint32) error {
	address := host + ":" + strconv.Itoa(int(port))
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}

	log.Printf("Starting HTTP server at host: %s on port: %d", host, port)
	return startServer(&listener, host, deaPort, streamingTimeout)
}
