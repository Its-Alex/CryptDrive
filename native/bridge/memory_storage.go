package bridge

import (
	"bytes"
	"errors"
	"strings"
	"sync"

	"github.com/rclone/rclone/fs/config"
	"github.com/unknwon/goconfig"
)

// EncryptedMemoryStorage is a config.Storage held in memory that hands out
// the config encrypted with the config password each time rclone saves it.
type EncryptedMemoryStorage struct {
	mu     sync.Mutex
	gc     *goconfig.ConfigFile
	onSave func(encryptedConf string)
}

var _ config.Storage = (*EncryptedMemoryStorage)(nil)

func NewEncryptedMemoryStorage(onSave func(encryptedConf string)) *EncryptedMemoryStorage {
	return &EncryptedMemoryStorage{gc: emptyConfig(), onSave: onSave}
}

func emptyConfig() *goconfig.ConfigFile {
	gc, _ := goconfig.LoadFromReader(strings.NewReader(""))
	return gc
}

// Unlock sets the config password and loads encryptedConf, as previously
// handed to onSave; an empty encryptedConf starts a new config.
func (s *EncryptedMemoryStorage) Unlock(password, encryptedConf string) error {
	if err := config.SetConfigPassword(password); err != nil {
		return err
	}
	gc := emptyConfig()
	if encryptedConf != "" {
		plain, err := config.Decrypt(bytes.NewReader([]byte(encryptedConf)))
		if err != nil {
			config.ClearConfigPassword()
			return ErrWrongConfigPassword
		}
		if gc, err = goconfig.LoadFromReader(plain); err != nil {
			return err
		}
	}
	s.mu.Lock()
	s.gc = gc
	s.mu.Unlock()
	return nil
}

func (s *EncryptedMemoryStorage) GetSectionList() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.gc.GetSectionList()
}

func (s *EncryptedMemoryStorage) HasSection(section string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.gc.GetSection(section)
	return err == nil
}

func (s *EncryptedMemoryStorage) DeleteSection(section string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gc.DeleteSection(section)
}

func (s *EncryptedMemoryStorage) GetKeyList(section string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.gc.GetKeyList(section)
}

func (s *EncryptedMemoryStorage) GetValue(section string, key string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	value, err := s.gc.GetValue(section, key)
	return value, err == nil
}

func (s *EncryptedMemoryStorage) SetValue(section string, key string, value string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gc.SetValue(section, key, value)
}

func (s *EncryptedMemoryStorage) DeleteKey(section string, key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.gc.DeleteKey(section, key)
}

func (s *EncryptedMemoryStorage) Load() error { return nil }

func (s *EncryptedMemoryStorage) Save() error {
	if !config.IsEncrypted() {
		return errors.New("refusing to save the config without a config password")
	}
	plain, err := s.Serialize()
	if err != nil {
		return err
	}
	var encrypted bytes.Buffer
	if err := config.Encrypt(strings.NewReader(plain), &encrypted); err != nil {
		return err
	}
	if s.onSave != nil {
		s.onSave(encrypted.String())
	}
	return nil
}

func (s *EncryptedMemoryStorage) Serialize() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var buf bytes.Buffer
	if err := goconfig.SaveConfigData(s.gc, &buf); err != nil {
		return "", err
	}
	return buf.String(), nil
}
