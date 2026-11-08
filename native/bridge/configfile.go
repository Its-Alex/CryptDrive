package bridge

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/rclone/rclone/fs/config"
	"github.com/rclone/rclone/fs/rc"
	"github.com/unknwon/goconfig"
	"golang.org/x/crypto/nacl/secretbox"
	"golang.org/x/text/unicode/norm"
)

const encryptedConfigMarker = "RCLONE_ENCRYPT_V0:"

func init() {
	rc.Add(rc.Call{
		Path:  "cryptdrive/exportconfig",
		Fn:    rcExportConfig,
		Title: "Return the current config as a plain, standard rclone.conf.",
		Help: `Returns:

- conf - the decrypted rclone.conf text, readable by the rclone CLI
`,
	})
	rc.Add(rc.Call{
		Path:  "cryptdrive/importconfig",
		Fn:    rcImportConfig,
		Title: "Import the remotes of a standard rclone.conf.",
		Help: `Parameters:

- conf - rclone.conf text, plain or encrypted with a config password
- password - (optional) config password when conf is encrypted

Values are copied verbatim (already obscured), sections with the same
name are replaced, and the result is saved to the app's encrypted config.

Returns:

- remotes - names of the imported remotes
`,
	})
}

func rcExportConfig(ctx context.Context, in rc.Params) (rc.Params, error) {
	serialized, err := config.LoadedData().Serialize()
	if err != nil {
		return nil, err
	}
	return rc.Params{"conf": serialized}, nil
}

func rcImportConfig(ctx context.Context, in rc.Params) (rc.Params, error) {
	confText, err := in.GetString("conf")
	if err != nil {
		return nil, err
	}
	password, err := in.GetString("password")
	if rc.NotErrParamNotFound(err) {
		return nil, err
	}
	sections, err := ParseConfig(confText, password)
	if err != nil {
		return nil, err
	}
	storage := config.LoadedData()
	remoteNames := make([]string, 0, len(sections))
	for _, section := range sections {
		storage.DeleteSection(section.Name)
		for _, entry := range section.Entries {
			storage.SetValue(section.Name, entry[0], entry[1])
		}
		remoteNames = append(remoteNames, section.Name)
	}
	if err := storage.Save(); err != nil {
		return nil, err
	}
	return rc.Params{"remotes": remoteNames}, nil
}

// ConfigSection is one remote of an rclone.conf, keys in file order.
type ConfigSection struct {
	Name    string
	Entries [][2]string
}

// ParseConfig reads rclone.conf text, decrypting it when it carries rclone's
// RCLONE_ENCRYPT_V0 config encryption.
func ParseConfig(confText, password string) ([]ConfigSection, error) {
	plainText, err := decryptConfigText(confText, password)
	if err != nil {
		return nil, err
	}
	parsed, err := goconfig.LoadFromReader(strings.NewReader(plainText))
	if err != nil {
		return nil, fmt.Errorf("invalid rclone.conf: %w", err)
	}
	var sections []ConfigSection
	for _, sectionName := range parsed.GetSectionList() {
		if sectionName == goconfig.DEFAULT_SECTION {
			continue
		}
		section := ConfigSection{Name: sectionName}
		for _, key := range parsed.GetKeyList(sectionName) {
			value, _ := parsed.GetValue(sectionName, key)
			section.Entries = append(section.Entries, [2]string{key, value})
		}
		sections = append(sections, section)
	}
	if len(sections) == 0 {
		return nil, errors.New("no remotes found in rclone.conf")
	}
	return sections, nil
}

// decryptConfigText mirrors rclone's fs/config/crypt.go format; rclone only
// exposes it through a process-global key, which holds the app's own config key.
func decryptConfigText(confText, password string) (string, error) {
	scanner := bufio.NewScanner(strings.NewReader(confText))
	var encodedLines []string
	encrypted := false
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !encrypted {
			if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
				continue
			}
			if line != encryptedConfigMarker {
				if strings.HasPrefix(line, "RCLONE_ENCRYPT_V") {
					return "", errors.New("unsupported rclone config encryption version")
				}
				return confText, nil
			}
			encrypted = true
			continue
		}
		encodedLines = append(encodedLines, line)
	}
	if !encrypted {
		return confText, nil
	}
	if password == "" {
		return "", ErrConfigPasswordRequired
	}
	box, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, strings.NewReader(strings.Join(encodedLines, ""))))
	if err != nil {
		return "", fmt.Errorf("failed to decode encrypted config: %w", err)
	}
	if len(box) < 24+secretbox.Overhead {
		return "", errors.New("encrypted config is too short")
	}
	keyHash := sha256.Sum256([]byte("[" + norm.NFKC.String(password) + "][rclone-config]"))
	var nonce [24]byte
	copy(nonce[:], box[:24])
	plain, ok := secretbox.Open(nil, box[24:], &nonce, &keyHash)
	if !ok {
		return "", ErrWrongConfigPassword
	}
	return string(plain), nil
}

var (
	ErrConfigPasswordRequired = errors.New("this rclone.conf is encrypted: a config password is required")
	ErrWrongConfigPassword    = errors.New("wrong config password for this rclone.conf")
)
