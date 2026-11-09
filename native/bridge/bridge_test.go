package bridge

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "github.com/rclone/rclone/backend/all"
)

func call(t *testing.T, method string, params map[string]any) map[string]any {
	t.Helper()
	input, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	output, status := RPC(method, string(input))
	if status != http.StatusOK {
		t.Fatalf("%s: status %d: %s", method, status, output)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		t.Fatalf("%s: %v: %s", method, err, output)
	}
	return result
}

func TestMain(m *testing.M) {
	configDir, err := os.MkdirTemp("", "cryptdrive-bridge-test")
	if err != nil {
		panic(err)
	}
	if err := Initialize(filepath.Join(configDir, "rclone.conf")); err != nil {
		panic(err)
	}
	code := m.Run()
	Finalize()
	_ = os.RemoveAll(configDir)
	os.Exit(code)
}

func TestEncryptedRoundTripOverLocalRemote(t *testing.T) {
	if err := SetConfigPassword("config password"); err != nil {
		t.Fatal(err)
	}
	storageDir := t.TempDir()
	sourceDir := t.TempDir()
	downloadDir := t.TempDir()
	content := bytes.Repeat([]byte("secret photo bytes "), 1000)
	if err := os.WriteFile(filepath.Join(sourceDir, "photo.jpg"), content, 0o600); err != nil {
		t.Fatal(err)
	}

	call(t, "config/create", map[string]any{
		"name": "backing", "type": "local", "parameters": map[string]any{},
		"opt": map[string]any{"nonInteractive": true},
	})
	call(t, "config/create", map[string]any{
		"name": "vault", "type": "crypt",
		"parameters": map[string]any{
			"remote": "backing:" + storageDir, "password": "vault password", "password2": "vault salt",
		},
		"opt": map[string]any{"nonInteractive": true, "obscure": true},
	})

	call(t, "operations/copyfile", map[string]any{
		"srcFs": sourceDir, "srcRemote": "photo.jpg", "dstFs": "vault:", "dstRemote": "Photos/photo.jpg",
	})

	listing := call(t, "operations/list", map[string]any{"fs": "vault:", "remote": "Photos"})
	items := listing["list"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["Name"] != "photo.jpg" {
		t.Fatalf("unexpected listing: %v", listing)
	}

	err := filepath.Walk(storageDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if strings.Contains(path, "photo") || strings.Contains(path, "Photos") {
			t.Errorf("backing storage exposes a plaintext name: %s", path)
		}
		if !info.IsDir() {
			stored, readErr := os.ReadFile(path)
			if readErr != nil {
				return readErr
			}
			if bytes.Contains(stored, []byte("secret photo bytes")) {
				t.Errorf("backing storage holds plaintext content: %s", path)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	call(t, "operations/copyfile", map[string]any{
		"srcFs": "vault:", "srcRemote": "Photos/photo.jpg", "dstFs": downloadDir, "dstRemote": "photo.jpg",
	})
	downloaded, err := os.ReadFile(filepath.Join(downloadDir, "photo.jpg"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(downloaded, content) {
		t.Fatal("downloaded content differs from uploaded content")
	}

	preview := call(t, "operations/getfile", map[string]any{
		"fs": "vault:", "remote": "Photos/photo.jpg", "count": 6, "base64": true,
	})
	if preview["result"] != "c2VjcmV0" {
		t.Fatalf("unexpected ranged read: %v", preview["result"])
	}
}

func TestConfigFileIsEncryptedOnDisk(t *testing.T) {
	if err := SetConfigPassword("config password"); err != nil {
		t.Fatal(err)
	}
	call(t, "config/create", map[string]any{
		"name": "ondisk", "type": "local", "parameters": map[string]any{},
		"opt": map[string]any{"nonInteractive": true},
	})
	paths := call(t, "config/paths", nil)
	onDisk, err := os.ReadFile(paths["config"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(onDisk), encryptedConfigMarker) || strings.Contains(string(onDisk), "[ondisk]") {
		t.Fatalf("config is not encrypted on disk:\n%s", onDisk)
	}
	if err := SetConfigPassword("wrong password"); err == nil {
		t.Fatal("expected a wrong config password to be rejected")
	}
	if err := SetConfigPassword("config password"); err != nil {
		t.Fatal(err)
	}
}

func TestImportExportRoundTrip(t *testing.T) {
	if err := SetConfigPassword("config password"); err != nil {
		t.Fatal(err)
	}
	plain := "[imported]\ntype = crypt\nremote = /tmp/somewhere\npassword = abc\n"
	imported := call(t, "cryptdrive/importconfig", map[string]any{"conf": plain})
	if names := imported["remotes"].([]any); len(names) != 1 || names[0] != "imported" {
		t.Fatalf("unexpected import result: %v", imported)
	}
	exported := call(t, "cryptdrive/exportconfig", nil)["conf"].(string)
	sections, err := ParseConfig(exported, "")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, section := range sections {
		if section.Name == "imported" {
			found = true
			want := [][2]string{{"type", "crypt"}, {"remote", "/tmp/somewhere"}, {"password", "abc"}}
			if len(section.Entries) != len(want) {
				t.Fatalf("unexpected entries: %v", section.Entries)
			}
			for i := range want {
				if section.Entries[i] != want[i] {
					t.Fatalf("unexpected entries: %v", section.Entries)
				}
			}
		}
	}
	if !found {
		t.Fatalf("imported remote missing from export:\n%s", exported)
	}
}

func TestParseEncryptedConfig(t *testing.T) {
	// Produced by: rclone config encryption set --password-command "echo hunter2" (rclone v1.76.0)
	encrypted, err := os.ReadFile(filepath.Join("testdata", "encrypted-rclone.conf"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseConfig(string(encrypted), ""); err != ErrConfigPasswordRequired {
		t.Fatalf("expected password required, got %v", err)
	}
	if _, err := ParseConfig(string(encrypted), "nope"); err != ErrWrongConfigPassword {
		t.Fatalf("expected wrong password, got %v", err)
	}
	sections, err := ParseConfig(string(encrypted), "hunter2")
	if err != nil {
		t.Fatal(err)
	}
	if len(sections) != 1 || sections[0].Name != "fixture" {
		t.Fatalf("unexpected sections: %v", sections)
	}
}

func TestAuthorizeServesGoogleConsentRedirect(t *testing.T) {
	started := call(t, "cryptdrive/authorize", map[string]any{
		"client_id": "test-client.apps.googleusercontent.com", "client_secret": "test-secret",
		"scope": "drive", "_async": true,
	})
	jobID := started["jobid"]

	var authURL string
	for attempt := 0; attempt < 100 && authURL == ""; attempt++ {
		status := call(t, "config/oauthstatus", nil)
		if status["status"] == "running" {
			authURL = status["authUrl"].(string)
		} else {
			time.Sleep(50 * time.Millisecond)
		}
	}
	if authURL == "" {
		t.Fatal("auth server never started")
	}

	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Get(authURL)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	location := response.Header.Get("Location")
	if !strings.HasPrefix(location, "https://accounts.google.com/") ||
		!strings.Contains(location, "client_id=test-client.apps.googleusercontent.com") ||
		!strings.Contains(location, "redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2F") {
		t.Fatalf("unexpected consent redirect: %s", location)
	}

	call(t, "config/oauthstop", nil)
	for attempt := 0; attempt < 100; attempt++ {
		job := call(t, "job/status", map[string]any{"jobid": jobID})
		if job["finished"] == true {
			if job["success"] == true {
				t.Fatal("cancelled authorization reported success")
			}
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("authorization job did not stop")
}

func TestDriveRemoteAcceptsInjectedToken(t *testing.T) {
	if err := SetConfigPassword("config password"); err != nil {
		t.Fatal(err)
	}
	token := `{"access_token":"ya29.fake","token_type":"Bearer","refresh_token":"1//fake","expiry":"2099-01-01T00:00:00Z"}`
	call(t, "config/create", map[string]any{
		"name": "gdrive", "type": "drive",
		"parameters": map[string]any{
			"client_id": "test-client.apps.googleusercontent.com", "client_secret": "test-secret",
			"scope": "drive", "token": token, "config_is_local": "false",
		},
		"opt": map[string]any{"nonInteractive": true, "obscure": true},
	})
	stored := call(t, "config/get", map[string]any{"name": "gdrive"})
	if stored["token"] != token || stored["scope"] != "drive" || stored["type"] != "drive" {
		t.Fatalf("unexpected drive remote: %v", stored)
	}
}

func TestStopRunningJobsCancelsAsyncJobs(t *testing.T) {
	started := call(t, "cryptdrive/authorize", map[string]any{
		"client_id": "test-client", "client_secret": "test-secret", "_async": true,
	})
	for attempt := 0; attempt < 100 && call(t, "config/oauthstatus", nil)["status"] != "running"; attempt++ {
		time.Sleep(50 * time.Millisecond)
	}
	began := time.Now()
	stopRunningJobs(5 * time.Second)
	if elapsed := time.Since(began); elapsed > 2*time.Second {
		t.Fatalf("jobs took %v to stop", elapsed)
	}
	job := call(t, "job/status", map[string]any{"jobid": started["jobid"]})
	if job["finished"] != true || job["success"] == true {
		t.Fatalf("async job was not stopped: %v", job)
	}
}

func TestEncryptedMemoryStorageRoundTrip(t *testing.T) {
	var saved string
	storage := NewEncryptedMemoryStorage(func(encrypted string) { saved = encrypted })
	if err := storage.Unlock("browser password", ""); err != nil {
		t.Fatal(err)
	}
	storage.SetValue("vault", "type", "crypt")
	if err := storage.Save(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(saved, encryptedConfigMarker) || strings.Contains(saved, "[vault]") {
		t.Fatalf("saved config is not encrypted:\n%s", saved)
	}

	reopened := NewEncryptedMemoryStorage(nil)
	if err := reopened.Unlock("wrong password", saved); err != ErrWrongConfigPassword {
		t.Fatalf("expected a wrong password error, got %v", err)
	}
	if err := reopened.Unlock("browser password", saved); err != nil {
		t.Fatal(err)
	}
	if value, ok := reopened.GetValue("vault", "type"); !ok || value != "crypt" {
		t.Fatalf("unexpected value after unlock: %q %v", value, ok)
	}
	if err := SetConfigPassword("config password"); err != nil {
		t.Fatal(err)
	}
}

func TestPutAndReadFileThroughCrypt(t *testing.T) {
	if err := SetConfigPassword("config password"); err != nil {
		t.Fatal(err)
	}
	storageDir := t.TempDir()
	call(t, "config/create", map[string]any{
		"name": "bytesvault", "type": "crypt",
		"parameters": map[string]any{"remote": storageDir, "password": "vault password"},
		"opt":        map[string]any{"nonInteractive": true, "obscure": true},
	})
	content := bytes.Repeat([]byte("0123456789"), 100000)
	ctx := context.Background()
	if err := PutFile(ctx, "bytesvault:", "Docs/big.bin", content, "test-put"); err != nil {
		t.Fatal(err)
	}
	stats := call(t, "core/stats", map[string]any{"group": "test-put"})
	if stats["bytes"].(float64) < float64(len(content)) {
		t.Fatalf("unexpected stats: %v", stats)
	}
	whole, err := ReadFile(ctx, "bytesvault:", "Docs/big.bin", 0, -1)
	if err != nil || !bytes.Equal(whole, content) {
		t.Fatalf("whole read failed: %v", err)
	}
	chunk, err := ReadFile(ctx, "bytesvault:", "Docs/big.bin", 999990, 20)
	if err != nil || string(chunk) != "0123456789" {
		t.Fatalf("ranged read returned %q, %v", chunk, err)
	}
	past, err := ReadFile(ctx, "bytesvault:", "Docs/big.bin", int64(len(content)), 10)
	if err != nil || len(past) != 0 {
		t.Fatalf("read past the end returned %d bytes, %v", len(past), err)
	}
}
