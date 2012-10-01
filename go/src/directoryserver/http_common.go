package directoryserver

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

type ByteRange struct {
	start, end *uint64
}

func (byteRange ByteRange) IsBadRange(entitySize uint64) bool {
	if byteRange.start == nil && byteRange.end == nil {
		return false
	}

	if byteRange.start == nil {
		if *(byteRange.end) > entitySize {
			return false
		}
	}

	if byteRange.end == nil {
		if *(byteRange.start) >= entitySize {
			return false
		}
	}

	return true
}

// Parses the "Range" header into a slice of byte ranges.
func ParseHttpRangeHeader(request *http.Request) ([]ByteRange, error) {
	rangeValue := request.Header.Get("Range")
	if len(rangeValue) == 0 {
		return nil, nil
	}

	byteRangesStr := strings.Split(rangeValue, ",")
	byteRanges := make([]ByteRange, len(byteRangesStr))
	for index, byteRangeStr := range byteRangesStr {
		errMsg := fmt.Sprintf("Byte range: %s is invalid.",
			byteRangeStr)
		pair := strings.Split(byteRangeStr, "-")
		if len(pair) > 2 {
			return nil, errors.New(errMsg)
		}

		var pStart *uint64 = nil
		pair[0] = strings.TrimSpace(pair[0])
		if len(pair[0]) > 0 {
			start, err := strconv.ParseUint(pair[0], 10, 64)
			// start of the range can't be malformed or negative.
			if err != nil || start < 0 {
				return nil, errors.New(errMsg)
			}

			pStart = &start
		}

		var pEnd *uint64 = nil
		if len(pair) > 1 && len(pair[1]) > 0 {
			pair[1] = strings.TrimSpace(pair[1])
			end, err := strconv.ParseUint(pair[1], 10, 64)
			// end of the range can't be malformed or negative.
			if err != nil || end < 0 {
				return nil, errors.New(errMsg)
			}

			pEnd = &end
		}

		// both start and end of the range can't be empty.
		if pStart == nil && pEnd == nil {
			errMsg = "One of the byte ranges is empty."
			return nil, errors.New(errMsg)
		}

		// start of the range cannot be greater than end of the range.
		if pStart != nil && pEnd != nil && *pStart > *pEnd {
			return nil, errors.New(errMsg)
		}

		byteRanges[index] = ByteRange{pStart, pEnd}
	}

	return byteRanges, nil
}
