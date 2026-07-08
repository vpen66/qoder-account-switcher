//go:build !darwin && !windows

package crypto

import "errors"

// Decrypt returns an error since decryption is only supported on macOS and Windows.
func Decrypt(raw []byte, service string) ([]byte, error) {
	return nil, errors.New("decryption is not supported on this platform")
}
