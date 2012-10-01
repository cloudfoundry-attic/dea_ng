package directoryserver

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

type ByteRange struct {
	start, end *int64
}

func (byteRange ByteRange) IsBadRange(entitySize int64) bool {
	if entitySize < 0 {
		return true
	}

	if byteRange.start == nil {
		if byteRange.end == nil || *(byteRange.end) > entitySize {
			return true
		}
	}

	if *(byteRange.start) >= entitySize {
			return true
	}

	if byteRange.end != nil && *(byteRange.end) >= entitySize {
		return true
	}

	return false
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
		// Byte range can't be malformed or have negative values.
		if len(pair) > 2 {
			return nil, errors.New(errMsg)
		}

		var pStart *int64 = nil
		pair[0] = strings.TrimSpace(pair[0])
		if len(pair[0]) > 0 {
			start, err := strconv.ParseInt(pair[0], 10, 64)
			// start of the range can't be malformed.
			if err != nil {
				return nil, errors.New(errMsg)
			}

			pStart = &start
		}

		var pEnd *int64 = nil
		if len(pair) > 1 && len(pair[1]) > 0 {
			pair[1] = strings.TrimSpace(pair[1])
			end, err := strconv.ParseInt(pair[1], 10, 64)
			// end of the range can't be malformed.
			if err != nil {
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
