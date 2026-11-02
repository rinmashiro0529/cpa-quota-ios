package monitor

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
)

var ErrStorage = errors.New("state storage unavailable")

const maxStateBytes = 32 * 1024 * 1024

var stateHeader = []byte("QMON1\x00")

type Persistence interface {
	Load() ([]byte, error)
	Save([]byte) error
}

// FileStore is a single-writer, AES-256-GCM authenticated state file. OS locks release after crashes.
type FileStore struct {
	mu     sync.Mutex
	path   string
	aead   cipher.AEAD
	lock   *os.File
	closed bool
}

func OpenFileStore(path string, key []byte) (*FileStore, error) {
	if len(key) != 32 || path == "" {
		return nil, ErrStorage
	}
	block, e := aes.NewCipher(key)
	if e != nil {
		return nil, ErrStorage
	}
	a, e := cipher.NewGCM(block)
	if e != nil {
		return nil, ErrStorage
	}
	path, e = filepath.Abs(path)
	if e != nil {
		return nil, ErrStorage
	}
	if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return nil, ErrStorage
	}
	if !secureStateDirectory(filepath.Dir(path)) {
		return nil, ErrStorage
	}
	for _, p := range []string{path, path + ".lock"} {
		if st, e := os.Lstat(p); e == nil && (st.Mode()&os.ModeSymlink != 0 || !st.Mode().IsRegular()) {
			return nil, ErrStorage
		} else if e != nil && !os.IsNotExist(e) {
			return nil, ErrStorage
		}
	}
	lock, e := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, ErrStorage
	}
	if e = lockStateFile(lock); e != nil {
		lock.Close()
		return nil, ErrStorage
	}
	return &FileStore{path: path, aead: a, lock: lock}, nil
}
func (f *FileStore) Load() ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return nil, ErrStorage
	}
	st, e := os.Lstat(f.path)
	if os.IsNotExist(e) {
		return nil, nil
	}
	if e != nil || !st.Mode().IsRegular() || st.Size() > maxStateBytes {
		return nil, ErrStorage
	}
	in, e := os.Open(f.path)
	if e != nil {
		return nil, ErrStorage
	}
	defer in.Close()
	b, e := io.ReadAll(io.LimitReader(in, maxStateBytes+1))
	if e != nil || len(b) > maxStateBytes || len(b) < len(stateHeader)+f.aead.NonceSize()+f.aead.Overhead() || !bytes.Equal(b[:len(stateHeader)], stateHeader) {
		return nil, ErrStorage
	}
	b = b[len(stateHeader):]
	plain, e := f.aead.Open(nil, b[:f.aead.NonceSize()], b[f.aead.NonceSize():], stateHeader)
	if e != nil {
		return nil, ErrStorage
	}
	return plain, nil
}
func (f *FileStore) Save(b []byte) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed || len(b) > maxStateBytes-128 {
		return ErrStorage
	}
	nonce := make([]byte, f.aead.NonceSize())
	if _, e := rand.Read(nonce); e != nil {
		return ErrStorage
	}
	out := append(append([]byte{}, stateHeader...), nonce...)
	out = f.aead.Seal(out, nonce, b, stateHeader)
	tmp, e := os.CreateTemp(filepath.Dir(f.path), ".quota-state-*")
	if e != nil {
		return ErrStorage
	}
	name := tmp.Name()
	defer os.Remove(name)
	if e = tmp.Chmod(0600); e == nil {
		_, e = tmp.Write(out)
	}
	if e == nil {
		e = tmp.Sync()
	}
	closeErr := tmp.Close()
	if e != nil || closeErr != nil {
		return ErrStorage
	}
	if replaceStateFile(name, f.path) != nil {
		return ErrStorage
	}
	if syncStateDirectory(filepath.Dir(f.path)) != nil {
		return ErrStorage
	}
	return nil
}
func (f *FileStore) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return nil
	}
	f.closed = true
	return f.lock.Close()
}
