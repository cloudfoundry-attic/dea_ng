package directoryserver

import (
	"net/http"
	"testing"
)

func checkByteRange(start *int64, end *int64, r ByteRange, t *testing.T) {
	if start == nil && r.start != nil || start != nil && r.start == nil {
		t.Fail()
	}

	if start != nil && *start != *(r.start) {
		t.Fail()
	}

	if end == nil && r.end != nil || end != nil && r.end == nil {
		t.Fail()
	}

	if end != nil && *end != *(r.end) {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_AbsentRanges(t *testing.T) {
	request := http.Request{}
	request.Header = make(http.Header)

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err != nil {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_EmptyRanges(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err != nil {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_DisallowNonNumericStartValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "a-0")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err == nil {
		t.Fail()
	}

	if err.Error() != "Byte range: a-0 is invalid." {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_DisallowNegativeStartValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "-1-2")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err == nil {
		t.Fail()
	}

	if err.Error() != "Byte range: -1-2 is invalid." {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_DisallowNonNumericEndValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "0-a")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err == nil {
		t.Fail()
	}

	if err.Error() != "Byte range: 0-a is invalid." {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_DisallowNegativeEndValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "0--1")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err == nil {
		t.Fail()
	}

	if err.Error() != "Byte range: 0--1 is invalid." {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_MalformedByteRange(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "-0--1-")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err == nil {
		t.Fail()
	}

	if err.Error() != "Byte range: -0--1- is invalid." {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_TrimWhiteSpaceInStartValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "  0  -1")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges == nil || len(byteRanges) != 1 {
		t.Fail()
	}

	if err != nil {
		t.Fail()
	}

	expStart := int64(0)
	expEnd := int64(1)
	checkByteRange(&expStart, &expEnd, byteRanges[0], t)
}

func Test_ParseHttpRangeHeader_TrimWhiteSpaceInEndValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "0-  1  ")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges == nil || len(byteRanges) != 1 {
		t.Fail()
	}

	if err != nil {
		t.Fail()
	}

	expStart := int64(0)
	expEnd := int64(1)
	checkByteRange(&expStart, &expEnd, byteRanges[0], t)
}

func Test_ParseHttpRangeHeader_EmptyStartValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "-1")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges == nil || len(byteRanges) != 1 {
		t.Fail()
	}

	if err != nil {
		t.Fail()
	}

	expEnd := int64(1)
	checkByteRange(nil, &expEnd, byteRanges[0], t)
}

func Test_ParseHttpRangeHeader_EmptyEndValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "0-")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges == nil || len(byteRanges) != 1 {
		t.Fail()
	}

	if err != nil {
		t.Fail()
	}

	expStart := int64(0)
	checkByteRange(&expStart, nil, byteRanges[0], t)
}

func Test_ParseHttpRangeHeader_DisallowEmptyStartAndEndValues(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "-")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err == nil {
		t.Fail()
	}

	if err.Error() != "One of the byte ranges is empty." {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_DisallowEndValueGreaterThanStartValue(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "1-0")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges != nil {
		t.Fail()
	}

	if err == nil {
		t.Fail()
	}

	if err.Error() != "Byte range: 1-0 is invalid." {
		t.Fail()
	}
}

func Test_ParseHttpRangeHeader_ReturnByteRanges(t *testing.T) {
	header := make(http.Header)
	header.Set("Range", "0-1,2-,-5,6-7")
	request := http.Request{}
	request.Header = header

	byteRanges, err := ParseHttpRangeHeader(&request)
	if byteRanges == nil {
		t.Fail()
	}

	if err != nil {
		t.Fail()
	}

	if len(byteRanges) != 4 {
		t.Fail()
	}

	expStart := int64(0)
	expEnd := int64(1)
	checkByteRange(&expStart, &expEnd, byteRanges[0], t)

	expStart = int64(2)
	checkByteRange(&expStart, nil, byteRanges[1], t)

	expEnd = int64(5)
	checkByteRange(nil, &expEnd, byteRanges[2], t)

	expStart = int64(6)
	expEnd = int64(7)
	checkByteRange(&expStart, &expEnd, byteRanges[3], t)
}

func Test_IsBadRange_NegativeEntitySize(t *testing.T) {
	byteRange := ByteRange{nil, nil}
	if !byteRange.IsBadRange(-1) {
		t.Fail()
	}
}

func Test_IsBadRange_EmptyRange(t *testing.T) {
	byteRange := ByteRange{nil, nil}
	if !byteRange.IsBadRange(10) {
		t.Fail()
	}
}

func Test_IsBadRange_EmptyStartAndEndExceedsEntitySize(t *testing.T) {
	end := int64(11)
	byteRange := ByteRange{nil, &end}
	if !byteRange.IsBadRange(end - 1) {
		t.Fail()
	}
}

func Test_IsBadRange_StartExceedsEntitySize(t *testing.T) {
	start := int64(10)
	byteRange := ByteRange{&start, nil}
	if !byteRange.IsBadRange(start) {
		t.Fail()
	}
}

func Test_IsBadRange_EndExceedsEntitySize(t *testing.T) {
	start := int64(0)
	end := int64(10)
	byteRange := ByteRange{&start, &end}
	if !byteRange.IsBadRange(end) {
		t.Fail()
	}
}

func Test_IsBadRange_NotBadRange(t *testing.T) {
	start := int64(0)
	end := int64(10)
	byteRange := ByteRange{&start, &end}
	if byteRange.IsBadRange(end + 1) {
		t.Fail()
	}

}
