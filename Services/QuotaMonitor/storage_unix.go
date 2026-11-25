//go:build !windows

package monitor

import (
	"os"
	"syscall"
)

func lockStateFile(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
}
func replaceStateFile(from, to string) error { return os.Rename(from, to) }
func syncStateDirectory(path string) error {
	f, e := os.Open(path)
	if e != nil {
		return e
	}
	defer f.Close()
	return f.Sync()
}
func secureStateDirectory(path string) bool {
	s, e := os.Stat(path)
	return e == nil && s.IsDir() && s.Mode().Perm()&0022 == 0
}
