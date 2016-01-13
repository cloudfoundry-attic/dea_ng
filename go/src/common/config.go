package common

import (
	"io/ioutil"
	goyaml "github.com/go-yaml/yaml"
)

type Config struct {
	Server DirServerConfig "directory_server"
}

type DirServerConfig struct {
	DeaPort          uint16    "file_api_port"
	DirServerPort    uint16    "v2_port"
	StreamingTimeout uint32    "streaming_timeout"
	Logging          LogConfig "logging"
}

type LogConfig struct {
	Level  string "level"
	File   string "file"
	Syslog string "syslog"
}

func ConfigFromFile(configPath string) (*Config, error) {
	configBytes, err := ioutil.ReadFile(configPath)
	if err != nil {
		return nil, err
	}

	config := Config{}
	if err := goyaml.Unmarshal(configBytes, &config); err != nil {
		return nil, err
	}

	return &config, nil
}
