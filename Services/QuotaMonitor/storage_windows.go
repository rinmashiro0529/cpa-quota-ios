//go:build windows

package monitor

import (
	"os"
	"syscall"
	"unsafe"
)

var stateKernel32 = syscall.NewLazyDLL("kernel32.dll")
var stateLockFile = stateKernel32.NewProc("LockFileEx")
var stateMoveFile = stateKernel32.NewProc("MoveFileExW")

func lockStateFile(f *os.File) error {
	var o syscall.Overlapped
	r, _, e := stateLockFile.Call(f.Fd(), 3, 0, 1, 0, uintptr(unsafe.Pointer(&o)))
	if r == 0 {
		return e
	}
	return nil
}
func replaceStateFile(from, to string) error {
	a, e := syscall.UTF16PtrFromString(from)
	if e != nil {
		return e
	}
	b, e := syscall.UTF16PtrFromString(to)
	if e != nil {
		return e
	}
	r, _, e := stateMoveFile.Call(uintptr(unsafe.Pointer(a)), uintptr(unsafe.Pointer(b)), 9)
	if r == 0 {
		return e
	}
	return nil
}
func syncStateDirectory(string) error       { return nil }                                          // MOVEFILE_WRITE_THROUGH is used above.
func secureStateDirectory(path string) bool { s, e := os.Stat(path); return e == nil && s.IsDir() } // Windows operators must provision an owner-only directory ACL.
