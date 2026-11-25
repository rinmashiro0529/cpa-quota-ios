package monitor

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestEncryptedAtomicRecovery(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.enc")
	key := bytes.Repeat([]byte{7}, 32)
	s, e := OpenFileStore(path, key)
	if e != nil {
		t.Fatal(e)
	}
	plain := []byte(`{"push_token":"private-device-token"}`)
	if e = s.Save(plain); e != nil {
		t.Fatal(e)
	}
	disk, _ := os.ReadFile(path)
	if bytes.Contains(disk, []byte("private-device-token")) {
		t.Fatal("APNs token persisted in plaintext")
	}
	got, e := s.Load()
	if e != nil || !bytes.Equal(got, plain) {
		t.Fatal("recovery", e)
	}
	if e = s.Save([]byte(`{"revision":2}`)); e != nil {
		t.Fatal(e)
	}
	s.Close()
	s, e = OpenFileStore(path, key)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	got, e = s.Load()
	if e != nil || string(got) != `{"revision":2}` {
		t.Fatal("atomic replacement recovery", e)
	}
	disk, _ = os.ReadFile(path)
	disk[len(disk)-1] ^= 1
	os.WriteFile(path, disk, 0600)
	if _, e = s.Load(); e == nil {
		t.Fatal("tampered ciphertext accepted")
	}
}
func TestStoreKeyAndExclusiveWriter(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.enc")
	if s, e := OpenFileStore(path, []byte("short")); e == nil {
		s.Close()
		t.Fatal("weak encryption key accepted")
	}
	key := bytes.Repeat([]byte{1}, 32)
	s, e := OpenFileStore(path, key)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if other, e := OpenFileStore(path, key); e == nil {
		other.Close()
		t.Fatal("two state writers accepted")
	}
}
