package common

import (
	"fmt"
	"io/ioutil"
	"launchpad.net/goyaml"
)

type Config struct {
	DeaPort          uint16
	DirServerPort    uint16
	StreamingTimeout uint32
	Route            string
	Logging          LogConfig
}

type LogConfig struct {
	Level  string
	File   string
	Syslog string
}

type ConfigError struct {
	message string
}

func (e *ConfigError) Error() string {
	return e.message
}

func ConfigFromFile(configPath string) (*Config, error) {
	configBytes, err := ioutil.ReadFile(configPath)
	if err != nil {
		return nil, err
	}

	config := make(map[interface{}]interface{})
	if err := goyaml.Unmarshal(configBytes, &config); err != nil {
		return nil, err
	}

	dirServerConfig := config["directory_server"].(map[interface{}]interface{})
	return constructConfig(&dirServerConfig)
}

func constructConfig(c *map[interface{}]interface{}) (*Config, error) {
	var config Config

	deaPort := (*c)["file_api_port"].(int)
	if deaPort <= 0 || deaPort > 65535 {
		msgFormat := "DEA server port should be between 1 and 65535."
		msgFormat += " You passed: %d."

		return nil, &ConfigError{fmt.Sprintf(msgFormat, deaPort)}
	}
	config.DeaPort = uint16(deaPort)

	dirServerPort := (*c)["v2_port"].(int)
	if dirServerPort <= 0 || dirServerPort > 65535 {
		msgFormat := "Directory server port should be"
		msgFormat += " between 1 and 65535. You passed: %d."

		return nil, &ConfigError{fmt.Sprintf(msgFormat, dirServerPort)}
	}
	config.DirServerPort = uint16(dirServerPort)

	streamingTimeout := (*c)["streaming_timeout"].(int)
	if streamingTimeout < 0 {
		msgFormat := "Streaming timeout should be"
		msgFormat += " between 0 and 4294967295. You passed: %d."

		return nil, &ConfigError{fmt.Sprintf(msgFormat,
			streamingTimeout)}
	}
	config.StreamingTimeout = uint32(streamingTimeout)

	if (*c)["local_route"] != nil {
		config.Route = (*c)["local_route"].(string)
	}

	logging := (*c)["logging"].(map[interface{}]interface{})
	config.Logging = LogConfig{}
	if logging["level"] != nil {
		config.Logging.Level = logging["level"].(string)
	}
	if logging["syslog"] != nil {
		config.Logging.Syslog = logging["syslog"].(string)
	}
	if logging["file"] != nil {
		config.Logging.File = logging["file"].(string)
	}

	return &config, nil
}
