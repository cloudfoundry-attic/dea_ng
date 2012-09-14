package main

import (
	"directoryserver"
	"io/ioutil"
	"launchpad.net/goyaml"
	"log"
	"net"
	"os"
	"strings"
)

// TODO(kowshik): What is the port number?
const rootServer = "198.41.0.4"

func parseConfig(configPath string) (map[interface{}]interface{}, error) {
	configBytes, err := ioutil.ReadFile(configPath)
	if err != nil {
		return nil, err
	}

	config := make(map[interface{}]interface{})
	if err := goyaml.Unmarshal(configBytes, &config); err != nil {
		return nil, err
	}

	return config, nil
}

func getLocalIp(route string) (*string, error) {
	conn, err := net.Dial("udp", route)
	if err != nil {
		return nil, err
	}

	// conn.LocalAddr().String() returns ip_address:port
	return &strings.Split(conn.LocalAddr().String(), ":")[0], nil
}

func getLocalIpWithDefaultRoute() (*string, error) {
	return getLocalIp(rootServer)
}

func main() {
	if len(os.Args) != 2 {
		msg := "Expected only the config file"
		msg += " to be passed as command-line argument."
		log.Panic(msg)
	}

	config, err := parseConfig(os.Args[1])
	if err != nil {
		log.Panic(err)
	}

	deaPort := config["dea_port"].(int)
	dirServerPort := config["directory_server_port"].(int)
	route := config["local_route"]

	var localIp *string
	if route != nil {
		localIp, err = getLocalIp(route.(string))
	} else {
		localIp, err = getLocalIpWithDefaultRoute()
	}

	if err != nil {
		log.Panic(err)
	}

	if err := directoryserver.Start(*localIp, deaPort,
		dirServerPort); err != nil {
		log.Panic(err)
	}
}
