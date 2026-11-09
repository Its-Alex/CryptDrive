//go:build js && wasm

// Command wasm builds CryptDrive's engine for the browser: rclone with the
// Google Drive, crypt and memory backends, exposed to JavaScript as
// globalThis.cryptdriveGo. It runs in a Web Worker (app/web/cryptdrive/worker.js).
package main

import (
	"context"
	"errors"
	"syscall/js"

	"github.com/Its-Alex/CryptDrive/native/bridge"

	_ "github.com/rclone/rclone/backend/alias"
	_ "github.com/rclone/rclone/backend/crypt"
	_ "github.com/rclone/rclone/backend/drive"
	_ "github.com/rclone/rclone/backend/memory"
)

var storage *bridge.EncryptedMemoryStorage

func main() {
	js.Global().Set("cryptdriveGo", js.ValueOf(map[string]any{
		"initialize": js.FuncOf(initialize),
		"unlock":     js.FuncOf(unlock),
		"rpc":        js.FuncOf(rpc),
		"putFile":    js.FuncOf(putFile),
		"readFile":   js.FuncOf(readFile),
		"finalize":   js.FuncOf(finalize),
	}))
	select {}
}

// initialize(onConfigSaved: (encryptedConf: string) => void): null | error message
func initialize(_ js.Value, args []js.Value) any {
	onConfigSaved := args[0]
	storage = bridge.NewEncryptedMemoryStorage(func(encryptedConf string) {
		onConfigSaved.Invoke(encryptedConf)
	})
	return errorValue(bridge.InitializeWithStorage(storage))
}

// unlock(password: string, encryptedConf: string): null | error message
func unlock(_ js.Value, args []js.Value) any {
	if storage == nil {
		return errorValue(errors.New("initialize first"))
	}
	return errorValue(storage.Unlock(args[0].String(), args[1].String()))
}

// rpc(method: string, inputJson: string): Promise<{output: string, status: number}>
func rpc(_ js.Value, args []js.Value) any {
	method, input := args[0].String(), args[1].String()
	return promise(func() (any, error) {
		output, status := bridge.RPC(method, input)
		return map[string]any{"output": output, "status": status}, nil
	})
}

// putFile(fs: string, remote: string, data: Uint8Array, statsGroup: string): Promise<null>
func putFile(_ js.Value, args []js.Value) any {
	fsString, remote, statsGroup := args[0].String(), args[1].String(), args[3].String()
	data := make([]byte, args[2].Get("length").Int())
	js.CopyBytesToGo(data, args[2])
	return promise(func() (any, error) {
		return nil, bridge.PutFile(context.Background(), fsString, remote, data, statsGroup)
	})
}

// readFile(fs: string, remote: string, offset: number, count: number): Promise<Uint8Array>
func readFile(_ js.Value, args []js.Value) any {
	fsString, remote := args[0].String(), args[1].String()
	offset, count := int64(args[2].Float()), int64(args[3].Float())
	return promise(func() (any, error) {
		data, err := bridge.ReadFile(context.Background(), fsString, remote, offset, count)
		if err != nil {
			return nil, err
		}
		array := js.Global().Get("Uint8Array").New(len(data))
		js.CopyBytesToJS(array, data)
		return array, nil
	})
}

func finalize(_ js.Value, _ []js.Value) any {
	bridge.Finalize()
	return nil
}

func errorValue(err error) any {
	if err == nil {
		return nil
	}
	return err.Error()
}

// promise runs work on a goroutine: blocking the JavaScript caller would also
// block the fetch calls rclone's HTTP transport relies on.
func promise(work func() (any, error)) js.Value {
	executor := js.FuncOf(func(_ js.Value, args []js.Value) any {
		resolve, reject := args[0], args[1]
		go func() {
			result, err := work()
			if err != nil {
				reject.Invoke(js.Global().Get("Error").New(err.Error()))
				return
			}
			resolve.Invoke(result)
		}()
		return nil
	})
	defer executor.Release()
	return js.Global().Get("Promise").New(executor)
}
