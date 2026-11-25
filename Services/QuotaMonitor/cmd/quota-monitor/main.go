package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	monitor "icu.nahida/cpaquota/monitor"
)

type starter func(context.Context, monitor.Config) error

func run(ctx context.Context, args []string, stderr io.Writer, start starter) int {
	flags := flag.NewFlagSet("quota-monitor", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	path := flags.String("config", "", "configuration file")
	if err := flags.Parse(args); err != nil {
		if err == flag.ErrHelp {
			fmt.Fprintln(stderr, "Usage: quota-monitor -config /path/to/config.json")
			return 0
		}
		fmt.Fprintln(stderr, "quota-monitor: invalid command arguments")
		return 2
	}
	if *path == "" || flags.NArg() != 0 || start == nil {
		fmt.Fprintln(stderr, "quota-monitor: a configuration file is required")
		return 2
	}
	absolute, err := filepath.Abs(*path)
	if err != nil {
		fmt.Fprintln(stderr, "quota-monitor: configuration unavailable")
		return 1
	}
	file, err := os.Open(absolute)
	if err != nil {
		fmt.Fprintln(stderr, "quota-monitor: configuration unavailable")
		return 1
	}
	config, decodeErr := monitor.DecodeConfig(file)
	closeErr := file.Close()
	if decodeErr != nil || closeErr != nil {
		fmt.Fprintln(stderr, "quota-monitor: invalid secure configuration")
		return 1
	}
	resolve := func(path string) string {
		if path == "" || filepath.IsAbs(path) {
			return path
		}
		return filepath.Join(filepath.Dir(absolute), path)
	}
	config.StatePath = resolve(config.StatePath)
	config.TLSCertFile = resolve(config.TLSCertFile)
	config.TLSKeyFile = resolve(config.TLSKeyFile)
	if err := start(ctx, config); err != nil {
		fmt.Fprintln(stderr, "quota-monitor: monitoring service unavailable")
		return 1
	}
	return 0
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := run(ctx, os.Args[1:], os.Stderr, monitor.Run)
	cancel()
	os.Exit(code)
}
