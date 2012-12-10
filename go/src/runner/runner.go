package main

/*
 Starts the HTTP-based directory server and listens for connections.
 Reads configuration from the co-located DEA's YAML configuration file.

 Usage:
   $> runner <DEA config file>
*/
import (
	"directoryserver"
	"log"
	"net"
	"os"
	"strings"
)

// Default server to be used for finding the local IP address
const rootServer = "198.41.0.4"

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

	config, err := ConfigFromFile(os.Args[1])
	if err != nil {
		log.Panic(err.Error())
	}

	var localIp *string
	if config.route != "" {
		localIp, err = getLocalIp(config.route)
	} else {
		localIp, err = getLocalIpWithDefaultRoute()
	}

	if err != nil {
		log.Panic(err)
	}

	if err := directoryserver.Start(*localIp, config.dirServerPort,
		config.deaPort, config.streamingTimeout); err != nil {
		log.Panic(err)
	}
}
