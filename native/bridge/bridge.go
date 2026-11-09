// Package bridge is the Go side of CryptDrive's native library: a thin layer
// over rclone's internal librclone package plus the helpers the rc API lacks.
package bridge

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/rc"
	"github.com/rclone/rclone/librclone/librclone"

	_ "github.com/rclone/rclone/fs/operations"
	_ "github.com/rclone/rclone/fs/sync"
)

var initializeOnce sync.Once

// Initialize points rclone at configPath and starts the library.
//
// The path is set before rclone installs its config storage: rclone skips
// installing file storage when the path is empty, and would otherwise read
// the user's own ~/.config/rclone/rclone.conf.
func Initialize(configPath string) error {
	return initialize(configPath, nil)
}

// InitializeWithStorage starts the library with its config kept in storage
// instead of a file (the browser has no file system).
func InitializeWithStorage(storage config.Storage) error {
	// Only a non-empty path makes rclone use a config storage at all; nothing is read from it.
	return initialize("/cryptdrive/rclone.conf", storage)
}

func initialize(configPath string, storage config.Storage) error {
	var initializeErr error
	initializeOnce.Do(func() {
		if err := config.SetConfigPath(configPath); err != nil {
			initializeErr = err
			return
		}
		globalConfig := fs.GetConfig(context.Background())
		// rclone would otherwise block on a terminal prompt for a wrong config password.
		globalConfig.AskPassword = false
		globalConfig.LogLevel = fs.LogLevelNotice
		librclone.Initialize()
		if storage != nil {
			config.SetData(storage)
		}
	})
	return initializeErr
}

// RPC runs one rc method with a JSON input and returns JSON plus an HTTP status.
func RPC(method, input string) (string, int) {
	return librclone.RPC(method, input)
}

// SetConfigPassword sets the key of the encrypted rclone.conf and checks it
// against the file on disk. Kept off the rc API so the password never reaches
// rc's parameter logging.
func SetConfigPassword(password string) error {
	if err := config.SetConfigPassword(password); err != nil {
		return err
	}
	err := config.Data().Load()
	if errors.Is(err, config.ErrorConfigFileNotFound) {
		return nil
	}
	return err
}

// Finalize stops in-flight async jobs, which librclone.Finalize leaves running.
func Finalize() {
	stopRunningJobs(5 * time.Second)
	librclone.Finalize()
}

// stopRunningJobs calls the job rc functions directly: going through RPC would
// register the listing call itself as a running job.
func stopRunningJobs(timeout time.Duration) {
	ctx := context.Background()
	runningJobIDs := func() []int64 {
		out, err := rc.Calls.Get("job/list").Fn(ctx, rc.Params{})
		if err != nil {
			return nil
		}
		ids, _ := out["runningIds"].([]int64)
		return ids
	}
	stopJob := rc.Calls.Get("job/stop").Fn
	for _, jobID := range runningJobIDs() {
		_, _ = stopJob(ctx, rc.Params{"jobid": jobID})
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) && len(runningJobIDs()) > 0 {
		time.Sleep(50 * time.Millisecond)
	}
}

func init() {
	rc.Add(rc.Call{
		Path:  "cryptdrive/authorize",
		Fn:    rcAuthorize,
		Title: "Run an OAuth authorization in process and return the token.",
		Help: `Equivalent of "rclone authorize" without printing to stdout.

Parameters:

- backend - backend type, default "drive"
- client_id - OAuth client ID
- client_secret - OAuth client secret
- scope - (optional) backend scope option, e.g. "drive"

The local auth server URL is available from config/oauthstatus while the
call runs; config/oauthstop cancels it. Call with _async = true.

Returns:

- token - the oauth2.Token as JSON, ready for the "token" config key
`,
	})
}

func rcAuthorize(ctx context.Context, in rc.Params) (rc.Params, error) {
	backendType, err := in.GetString("backend")
	if rc.NotErrParamNotFound(err) {
		return nil, err
	}
	if backendType == "" {
		backendType = "drive"
	}
	clientID, err := in.GetString("client_id")
	if err != nil {
		return nil, err
	}
	clientSecret, err := in.GetString("client_secret")
	if rc.NotErrParamNotFound(err) {
		return nil, err
	}
	scope, err := in.GetString("scope")
	if rc.NotErrParamNotFound(err) {
		return nil, err
	}

	regInfo, err := fs.Find(backendType)
	if err != nil {
		return nil, err
	}
	if regInfo.Config == nil {
		return nil, fmt.Errorf("can't authorize backend %q", backendType)
	}

	ctx, ctxConfig := fs.AddConfig(ctx)
	ctxConfig.AutoConfirm = true
	ctx = fs.ConfigOAuthOnly(ctx)

	inputMap := configmap.Simple{
		config.ConfigAuthorize:     "true",
		config.ConfigAuthNoBrowser: "true",
		config.ConfigClientID:      clientID,
		config.ConfigClientSecret:  clientSecret,
	}
	if scope != "" {
		inputMap["scope"] = scope
	}

	const temporaryRemoteName = "**temp-fs**"
	mapper := fs.ConfigMap(regInfo.Prefix, regInfo.Options, temporaryRemoteName, inputMap)
	outputMap := configmap.Simple{}
	mapper.ClearSetters()
	mapper.AddSetter(outputMap)
	mapper.AddGetter(outputMap, configmap.PriorityNormal)

	if err := config.PostConfig(ctx, temporaryRemoteName, mapper, regInfo); err != nil {
		return nil, err
	}
	token := outputMap["token"]
	if token == "" {
		return nil, errors.New("authorization finished without a token")
	}
	return rc.Params{"token": token}, nil
}
