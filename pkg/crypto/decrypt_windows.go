//go:build windows

package crypto

import (
	"bytes"
	"errors"
	"syscall"
	"unsafe"
)

var (
	dllCrypt32          = syscall.NewLazyDLL("crypt32.dll")
	procCryptUnprotect  = dllCrypt32.NewProc("CryptUnprotectData")
)

type dataBlob struct {
	cbData uint32
	pbData *byte
}

// Decrypt decrypts the credential data for Windows using DPAPI.
func Decrypt(raw []byte, service string) ([]byte, error) {
	if len(raw) == 0 {
		return nil, errors.New("data is empty")
	}

	var encrypted []byte
	if len(raw) >= 3 && bytes.Equal(raw[:3], []byte("v10")) {
		encrypted = raw[3:]
	} else if len(raw) >= 5 && bytes.Equal(raw[:5], []byte("DPAPI")) {
		encrypted = raw[5:]
	} else {
		encrypted = raw
	}

	if len(encrypted) == 0 {
		return nil, errors.New("encrypted payload is empty")
	}

	var inBlob dataBlob
	inBlob.cbData = uint32(len(encrypted))
	inBlob.pbData = &encrypted[0]

	var outBlob dataBlob

	r, _, err := procCryptUnprotect.Call(
		uintptr(unsafe.Pointer(&inBlob)),
		0,
		0,
		0,
		0,
		0,
		uintptr(unsafe.Pointer(&outBlob)),
	)
	if r == 0 {
		if err != nil {
			return nil, err
		}
		return nil, errors.New("CryptUnprotectData failed")
	}
	defer syscall.LocalFree(syscall.Handle(unsafe.Pointer(outBlob.pbData)))

	// Copy outBlob to Go slice
	result := make([]byte, outBlob.cbData)
	// unsafe.Slice is available in Go 1.17+
	srcSlice := unsafe.Slice(outBlob.pbData, outBlob.cbData)
	copy(result, srcSlice)

	return result, nil
}
