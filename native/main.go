// Command cryptdrive builds CryptDrive's native library: the same C API on
// every platform, as a c-shared library or (iOS) a c-archive.
package main

/*
#include <stdlib.h>

struct RcloneRPCResult {
	char*	Output;
	int	Status;
};
*/
import "C"

import (
	"unsafe"

	"github.com/Its-Alex/CryptDrive/native/bridge"

	_ "github.com/rclone/rclone/backend/all"
)

// CryptDriveInitialize returns NULL on success, else an error message the caller frees with RcloneFreeString.
//
//export CryptDriveInitialize
func CryptDriveInitialize(configPath *C.char) *C.char {
	return errorToCString(bridge.Initialize(C.GoString(configPath)))
}

//export RcloneFinalize
func RcloneFinalize() {
	bridge.Finalize()
}

// RcloneRPC returns Output as JSON, freed by the caller with RcloneFreeString.
//
//export RcloneRPC
func RcloneRPC(method *C.char, input *C.char) (result C.struct_RcloneRPCResult) {
	output, status := bridge.RPC(C.GoString(method), C.GoString(input))
	result.Output = C.CString(output)
	result.Status = C.int(status)
	return result
}

//export RcloneFreeString
func RcloneFreeString(str *C.char) {
	C.free(unsafe.Pointer(str))
}

// CryptDriveSetConfigPassword returns NULL on success, else an error message the caller frees with RcloneFreeString.
//
//export CryptDriveSetConfigPassword
func CryptDriveSetConfigPassword(password *C.char) *C.char {
	return errorToCString(bridge.SetConfigPassword(C.GoString(password)))
}

func errorToCString(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

func main() {}
