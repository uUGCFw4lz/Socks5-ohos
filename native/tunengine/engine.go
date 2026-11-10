package main

import "C"

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/dosgo/go-tun2socks/tun2socks"
	"github.com/miekg/dns"
)

var engineMu sync.Mutex
var device *os.File
var logFile *os.File
var cancelDiagnostics context.CancelFunc
var dnsServer *dns.Server

func validateEndpoint(host string, port int) error {
	if host == "" || port < 1 || port > 65535 {
		return fmt.Errorf("invalid SOCKS5 host or port")
	}
	for _, character := range host {
		if character > 127 || character <= 32 {
			return fmt.Errorf("invalid SOCKS5 host %q: character U+%04X; use ASCII dots in IP addresses", host, character)
		}
	}
	if address := net.ParseIP(host); address != nil && address.To4() != nil && !strings.Contains(host, ":") {
		return nil
	}
	if strings.Contains(host, ":") || len(host) > 253 {
		return fmt.Errorf("invalid SOCKS5 host %q", host)
	}
	for _, label := range strings.Split(strings.TrimSuffix(host, "."), ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return fmt.Errorf("invalid SOCKS5 hostname %q", host)
		}
		for _, character := range label {
			if !(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
				character >= '0' && character <= '9' || character == '-') {
				return fmt.Errorf("invalid SOCKS5 hostname %q", host)
			}
		}
	}
	return nil
}

func writeError(buffer *C.char, size C.int, err error) C.int {
	if buffer != nil && size > 0 {
		output := unsafe.Slice((*byte)(unsafe.Pointer(buffer)), int(size))
		count := copy(output[:len(output)-1], err.Error())
		output[count] = 0
	}
	return 1
}

//export TunStart
func TunStart(fd C.int, host *C.char, port C.int, path *C.char, errorBuffer *C.char, errorSize C.int) C.int {
	engineMu.Lock()
	defer engineMu.Unlock()
	if device != nil {
		return writeError(errorBuffer, errorSize, fmt.Errorf("tun2socks is already running"))
	}
	if fd < 0 {
		return writeError(errorBuffer, errorSize, fmt.Errorf("invalid TUN or SOCKS5 endpoint"))
	}
	if err := validateEndpoint(C.GoString(host), int(port)); err != nil {
		return writeError(errorBuffer, errorSize, err)
	}
	file, err := os.OpenFile(C.GoString(path), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return writeError(errorBuffer, errorSize, err)
	}
	log.SetOutput(file)
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds | log.LUTC)
	log.Printf("[GO start] build=ipv4-only-5 pid=%d fd=%d proxy=%s:%d", os.Getpid(), fd, C.GoString(host), port)
	if logFile != nil {
		logFile.Close()
	}
	logFile = file
	duplicate, err := syscall.Dup(int(fd))
	if err != nil {
		return writeError(errorBuffer, errorSize, err)
	}
	syscall.CloseOnExec(duplicate)
	if err := syscall.SetNonblock(duplicate, true); err != nil {
		syscall.Close(duplicate)
		return writeError(errorBuffer, errorSize, err)
	}
	device = os.NewFile(uintptr(duplicate), "vpn-tun")
	address := net.JoinHostPort(C.GoString(host), strconv.Itoa(int(port)))
	traced := &tracedDevice{ReadWriteCloser: device}
	ctx, cancel := context.WithCancel(context.Background())
	server, dnsAddress, err := startDNSTunnel(ctx, address)
	if err != nil {
		cancel()
		device.Close()
		device = nil
		return writeError(errorBuffer, errorSize, err)
	}
	log.Printf("[GO TUN ready] originalFd=%d duplicateFd=%d mtu=1400 dns=%s", fd, duplicate, dnsAddress)
	if err := tun2socks.StartFromIO(traced, 1400, address, dnsAddress); err != nil {
		cancel()
		server.Shutdown()
		device.Close()
		device = nil
		return writeError(errorBuffer, errorSize, err)
	}
	dnsServer = server
	cancelDiagnostics = cancel
	go traced.report(ctx)
	go diagnose(ctx, address)
	log.Printf("[GO stack started] proxy=%s (reachability not yet verified)", address)
	return 0
}

//export TunStop
func TunStop() {
	engineMu.Lock()
	defer engineMu.Unlock()
	if cancelDiagnostics != nil {
		cancelDiagnostics()
		cancelDiagnostics = nil
	}
	if dnsServer != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		if err := dnsServer.ShutdownContext(ctx); err != nil {
			log.Printf("[DNS stop] %v", err)
		}
		cancel()
		dnsServer = nil
	}
	if device != nil {
		device.Close()
		device = nil
		log.Print("tun2socks stopped")
	}
}

func main() {}
