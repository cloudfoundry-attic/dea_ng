package main

import (
	"fmt"
	"io/ioutil"
	"launchpad.net/goyaml"
)

type Config struct {
	deaPort          uint16
	dirServerPort    uint16
	streamingTimeout uint32
	route            string
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

	return constructConfig(&config)
}

func constructConfig(c *map[interface{}]interface{}) (*Config, error) {
	var config Config

	deaPort := (*c)["file_api_port"].(int)
	if deaPort <= 0 || deaPort > 65535 {
		msgFormat := "DEA server port should be between 1 and 65535."
		msgFormat += " You passed: %d."

		return nil, &ConfigError{fmt.Sprintf(msgFormat, deaPort)}
	}
	config.deaPort = uint16(deaPort)

	dirServerPort := (*c)["directory_server_v2_port"].(int)
	if dirServerPort <= 0 || dirServerPort > 65535 {
		msgFormat := "Directory server port should be"
		msgFormat += " between 1 and 65535. You passed: %d."

		return nil, &ConfigError{fmt.Sprintf(msgFormat, dirServerPort)}
	}
	config.dirServerPort = uint16(dirServerPort)

	streamingTimeout := (*c)["streaming_timeout"].(int)
	if streamingTimeout < 0 {
		msgFormat := "Streaming timeout should be"
		msgFormat += " between 0 and 4294967295. You passed: %d."

		return nil, &ConfigError{fmt.Sprintf(msgFormat,
				streamingTimeout)}
	}
	config.streamingTimeout = uint32(streamingTimeout)

	if (*c)["local_route"] != nil {
		config.route = (*c)["local_route"].(string)
	} else {
		config.route = ""
	}

	return &config, nil
}
