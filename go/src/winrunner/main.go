// +build windows

package main

import (
	"code.google.com/p/winsvc/svc"
	"fmt"
	"log"
	"os"
	"strings"
)

func usage(errmsg string) {
	fmt.Fprintf(os.Stderr,
		"%s\n\n"+
			"usage: %s <command>\n"+
			"       where <command> is one of\n"+
			"       install, remove, debug, start, stop, pause or continue.\n",
		errmsg, os.Args[0])
	os.Exit(2)
}

func usagewithconfigpath(errmsg string) {
	fmt.Fprintf(os.Stderr,
		"%s\n\n"+
			"usage: %s <command> <configpath>\n"+
			"       where <command> is one of\n"+
			"       install, remove, debug, start\n"+
			"       and <configpath> is the full path to the configuration file.\n",
		errmsg, os.Args[0])
	os.Exit(2)
}

func main() {
	const svcName = "IFDeaDirSvc"

	isIntSess, err := svc.IsAnInteractiveSession()
	if err != nil {
		log.Fatalf("failed to determine if we are running in an interactive session: %v", err)
	}
	if !isIntSess {
		runService(svcName, false)
		return
	}

	if len(os.Args) < 2 {
		usage("no command specified")
	}

	cmd := strings.ToLower(os.Args[1])
	switch cmd {
	case "debug":
		runService(svcName, true)
		return
	case "install":
		if len(os.Args) < 3 {
			usagewithconfigpath("no config path specified")
		}
		configPath := os.Args[2]
		err = installService(svcName, "Iron Foundry DEA Directory Service", configPath)
	case "remove":
		err = removeService(svcName)
	case "start":
	    if len(os.Args) < 3 {
			usagewithconfigpath("no config path specified")
		}
		err = startService(svcName)
	case "stop":
		err = controlService(svcName, svc.Stop, svc.Stopped)
	case "pause":
		err = controlService(svcName, svc.Pause, svc.Paused)
	case "continue":
		err = controlService(svcName, svc.Continue, svc.Running)
	default:
		usage(fmt.Sprintf("invalid command %s", cmd))
	}
	if err != nil {
		log.Fatalf("failed to %s %s: %v", cmd, svcName, err)
	}
	return
}
