//go:build darwin

package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha1"
	"errors"
	"os/exec"
	"strings"

	"golang.org/x/crypto/pbkdf2"
)

// Decrypt decrypts the credential data for macOS using the Keychain and AES-CBC.
func Decrypt(raw []byte, service string) ([]byte, error) {
	if len(raw) < 3 {
		return nil, errors.New("data too short")
	}

	// 1. Get password from macOS Keychain
	// Service name is like "Qoder CN Safe Storage" or "QoderWork CN Safe Storage"
	cmd := exec.Command("security", "find-generic-password", "-w", "-s", service+" Safe Storage")
	out, err := cmd.Output()
	if err != nil {
		return nil, errors.New("failed to retrieve password from Keychain: " + err.Error())
	}
	password := strings.TrimSpace(string(out))
	if password == "" {
		return nil, errors.New("keychain password is empty")
	}

	// 2. Derive key using PBKDF2-HMAC-SHA1
	// Key length is 16 bytes (AES-128)
	key := pbkdf2.Key([]byte(password), []byte("saltysalt"), 1003, 16, sha1.New)

	// 3. AES-128-CBC Decryption
	// IV is 16 space characters
	iv := []byte("                ")
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}

	ciphertext := raw[3:] // skip 'v10' or similar 3-byte prefix
	if len(ciphertext)%aes.BlockSize != 0 {
		return nil, errors.New("ciphertext block size is invalid")
	}

	mode := cipher.NewCBCDecrypter(block, iv)
	plaintext := make([]byte, len(ciphertext))
	mode.CryptBlocks(plaintext, ciphertext)

	// 4. Remove PKCS#7 padding
	if len(plaintext) == 0 {
		return nil, errors.New("decrypted plaintext is empty")
	}
	padding := int(plaintext[len(plaintext)-1])
	if padding < 1 || padding > aes.BlockSize {
		return nil, errors.New("invalid PKCS#7 padding size")
	}
	// Verify padding
	for i := len(plaintext) - padding; i < len(plaintext); i++ {
		if int(plaintext[i]) != padding {
			return nil, errors.New("invalid PKCS#7 padding content")
		}
	}

	return plaintext[:len(plaintext)-padding], nil
}
