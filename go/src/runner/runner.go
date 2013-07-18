package main

/*
 Starts the HTTP-based directory server and listens for connections.
 Reads configuration from the co-located DEA's YAML configuration file.

 Usage:
   $> runner <DEA config file>
*/
import (
	"common"
	"directoryserver"
	"flag"
	steno "github.com/cloudfoundry/gosteno"
	"net"
	"strings"
)

// Default server to be used for finding the local IP address
const rootServer = "198.41.0.4"

/*
 Returns the local IP address.
*/
func getLocalIp() (*string, error) {
	conn, err := net.Dial("udp", rootServer+":1")
	if err != nil {
		return nil, err
	}

	// The method call: conn.LocalAddr().String() returns ip_address:port
	return &strings.Split(conn.LocalAddr().String(), ":")[0], nil
}

func main() {
	var configPath string
	flag.StringVar(&configPath,
		"conf",
		"", "Path of the YAML configuration of the co-located DEA.")
	flag.Parse()

	config, err := common.ConfigFromFile(configPath)
	if err != nil {
		panic(err.Error())
	}

	common.SetupSteno(&config.Server.Logging)
	log := steno.NewLogger("runner")

	var localIp *string
    localIp, err = getLocalIp()

	if err != nil {
		log.Fatal(err.Error())
	}

	if err := directoryserver.Start(*localIp, config); err != nil {
		log.Fatal(err.Error())
	}
}
