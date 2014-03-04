// +build windows

package main

import (
	"code.google.com/p/winsvc/debug"
	"code.google.com/p/winsvc/eventlog"
	"code.google.com/p/winsvc/svc"
	"common"
	"directoryserver"
	"strings"
	"net"
	"fmt"
	"os"
)

var elog debug.Log

type windowsService struct {
	configPath string
}

const rootServer = "198.41.0.4"

func getLocalIp() (*string, error) {
	conn, err := net.Dial("udp", rootServer+":1")
	if err != nil {
		return nil, err
	}

	// The method call: conn.LocalAddr().String() returns ip_address:port
	return &strings.Split(conn.LocalAddr().String(), ":")[0], nil
}

func runServer(configPath string) {
	config, err := common.ConfigFromFile(configPath)
	if err != nil {
		elog.Error(1, fmt.Sprintf("config file failed: %v", err))
	}

	common.SetupSteno(&config.Server.Logging)

	var localIp *string
	localIp, err = getLocalIp()

	if err != nil {
		elog.Error(1, fmt.Sprintf("getting local ip failed: %v", err))
	}

	if err := directoryserver.Start(*localIp, config); err != nil {
		elog.Error(1, fmt.Sprintf("directory server failed: %v", err))
	}
}

func (ws *windowsService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (ssec bool, errno uint32) {
	const cmdsAccepted = svc.AcceptStop | svc.AcceptShutdown | svc.AcceptPauseAndContinue
	changes <- svc.Status{State: svc.StartPending}

	if len(ws.configPath) == 0 {
		if len(args) > 0 {
			ws.configPath = args[0]
		}

		if len(os.Args) > 1 {
			ws.configPath = os.Args[1]
		}
	}

	elog.Info(1, "Running directory server with config file " + ws.configPath)

	go runServer(ws.configPath)

	changes <- svc.Status{State: svc.Running, Accepts: cmdsAccepted}

loop:
	for {
		select {
		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				changes <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				break loop
			case svc.Pause:
				changes <- svc.Status{State: svc.Paused, Accepts: cmdsAccepted}
			case svc.Continue:
				changes <- svc.Status{State: svc.Running, Accepts: cmdsAccepted}
			default:
				elog.Error(1, fmt.Sprintf("unexpected control request #%d", c))
			}
		}
	}
	changes <- svc.Status{State: svc.StopPending}
	return
}

func runService(name string, configPath string, isDebug bool) {
	var err error
	if isDebug {
		elog = debug.New(name)
	} else {
		elog, err = eventlog.Open(name)
		if err != nil {
			return
		}
	}
	defer elog.Close()

	elog.Info(1, fmt.Sprintf("starting %s service", name))
	run := svc.Run
	if isDebug {
		run = debug.Run
	}

	ws := windowsService{}
	ws.configPath = configPath
	err = run(name, &ws)
	if err != nil {
		elog.Error(1, fmt.Sprintf("%s service failed: %v", name, err))
		return
	}
	elog.Info(1, fmt.Sprintf("%s service stopped", name))
}
