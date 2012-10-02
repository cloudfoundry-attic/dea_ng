package main

/*
 Starts the HTTP-based directory server and listens for connections.
 Reads configuration from the co-located DEA's YAML configuration file.

 Usage:
   $> runner <DEA config file>
*/
import (
	"directoryserver"
	"fmt"
	"github.com/xushiwei/goyaml"
	"io/ioutil"
	"log"
	"net"
	"os"
	"strings"
)

// Default server to be used for finding the local IP address
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

/*
 Returns the local IP address.
*/
func getLocalIp(route string) (*string, error) {
	conn, err := net.Dial("udp", route+":1")
	if err != nil {
		return nil, err
	}

	// The method call: conn.LocalAddr().String() returns ip_address:port
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
		log.Panic("Failed reading config file.")
	}

	deaPort := config["file_api_port"].(int)
	dirServerPort := config["directory_server_v2_port"].(int)
	route := config["local_route"]
	streamingTimeout := config["streaming_timeout"].(int)

	if deaPort <= 0 || deaPort > 65535 {
		msgFormat := "DEA server port should be between 1 and 65535."
		msgFormat += " You passed: %d."
		log.Panic(fmt.Sprintf(msgFormat, deaPort))
	}

	if dirServerPort <= 0 || dirServerPort > 65535 {
		msgFormat := "Directory server port should be"
		msgFormat += " between 1 and 65535. You passed: %d."
		log.Panic(fmt.Sprintf(msgFormat, dirServerPort))
	}

	if streamingTimeout < 0 {
		msgFormat := "Streaming timeout should be"
		msgFormat += " between 0 and 4294967295. You passed: %d."
		log.Panic(fmt.Sprintf(msgFormat, streamingTimeout))
	}

	var localIp *string
	if route != nil {
		localIp, err = getLocalIp(route.(string))
	} else {
		localIp, err = getLocalIpWithDefaultRoute()
	}

	if err != nil {
		log.Panic(err)
	}

	if err := directoryserver.Start(*localIp, uint16(dirServerPort),
		uint16(deaPort), uint32(streamingTimeout)); err != nil {
		log.Panic(err)
	}
}
