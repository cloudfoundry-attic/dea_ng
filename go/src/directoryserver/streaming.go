package directoryserver

import (
	"bufio"
	"errors"
	"io"
	"os"
	"syscall"
	"time"
	"unsafe"
)

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

// Returns true if the current time is behind the specified time by more than
// maxIdleTime seconds. Returns false otherwise.
func timeout(t time.Time, maxIdleTime uint32) bool {
	return time.Now().Sub(t).Seconds() > float64(maxIdleTime)
}

// Uses the inotify linux kernel subsystem to stream a file to the writer.
// When no file modifications occur, the method waits for a maximum idle time of
// maxIdleTime seconds before returning.

// Returns errors (if any) triggered by the inotify subsystem or when reading
// the file. Errors when writing to the writer are ignored.
func streamFile(writer io.Writer, path string, maxIdleTime uint32) error {
	handle, err := os.Open(path)
	if err != nil {
		return err
	}

	// Seek to EOF.
	_, err = handle.Seek(0, os.SEEK_END)
	if err != nil {
		handle.Close()
		return err
	}

	reader := bufio.NewReader(handle)
	readBuffer := make([]byte, 4096)

	inotifyFd, err := syscall.InotifyInit()
	if err != nil {
		handle.Close()
		return err
	}

	watchDesc, err := syscall.InotifyAddWatch(inotifyFd, path,
		syscall.IN_MODIFY)
	if err != nil {
		syscall.Close(inotifyFd)
		handle.Close()
		return err
	}

	eventsBuffer := make([]byte, syscall.SizeofInotifyEvent*4096)

	selectMaxIdleTime := syscall.Timeval{}
	selectMaxIdleTime.Sec = int64(maxIdleTime)

	inotifyFdSet := syscall.FdSet{}
	lastWriteTime := time.Now()

	canScan := true
	for canScan && !timeout(lastWriteTime, maxIdleTime) {
		clearAll(&inotifyFdSet)
		set(&inotifyFdSet, inotifyFd)
		_, err := syscall.Select(inotifyFd+1, &inotifyFdSet,
			nil, nil, &selectMaxIdleTime)

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
				// Ignore the EOF error and continue polling
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
				// Stop scanning for updates to the file.
				canScan = false
				// Ignore the write error.
				err = nil
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
