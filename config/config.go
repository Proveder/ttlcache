package config

import (
	"encoding/json"
	"time"

	"github.com/proveder/envconfig"
)

type Cache struct {
	Enabled       bool          `envconfig:"CACHE_ENABLED"`
	CleanPeriod   time.Duration `envconfig:"CACHE_CLEAN_PERIOD"`
	ClientsTTL    time.Duration `envconfig:"CACHE_CLIENTS_TTL"`
	StaticDataTTL time.Duration `envconfig:"STATIC_DATA_TTL"`
}

// Get the application and returns the configuration structure
func Get() (*Cache, error) {
	cfg := &Cache{
		Enabled:       true,
		CleanPeriod:   time.Hour,
		ClientsTTL:    time.Minute,
		StaticDataTTL: time.Hour,
	}

	return cfg, envconfig.Process("", cfg)
}

// String is implemented to prevent sensitive fields being logged.
// The config is returned as JSON with sensitive fields omitted.
func (c *Cache) String() string {
	json, _ := json.Marshal(c)
	return string(json)
}

func (c *Cache) Validate() error {
	return nil
}
