package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/dosgo/go-tun2socks/tun2socks"
	"github.com/miekg/dns"
)

func TestInvalidStart(t *testing.T) {
	if result := TunStart(-1, nil, 0, nil, nil, 0); result == 0 {
		t.Fatal("invalid fd accepted")
	}
	TunStop()
	TunStop()
}

func TestEndpointValidation(t *testing.T) {
	for _, host := range []string{"192.168.3.13", "proxy.example.com"} {
		if err := validateEndpoint(host, 1080); err != nil {
			t.Fatalf("valid host rejected: %s %v", host, err)
		}
	}
	for _, host := range []string{"192\u00b7168.3.13", "192\uff0e168.3.13", "192.168.3.13 ", "proxy/host", "-bad.example", "a..b", "bad:host", "::1", "2001:db8::1", "::ffff:192.168.3.13"} {
		if err := validateEndpoint(host, 1080); err == nil {
			t.Fatalf("invalid host accepted: %q", host)
		}
	}
	for _, port := range []int{0, -1, 65536} {
		if err := validateEndpoint("192.168.3.13", port); err == nil {
			t.Fatalf("invalid port accepted: %d", port)
		}
	}
}

func TestPacketSummary(t *testing.T) {
	packet := make([]byte, 20)
	packet[0] = 0x45
	packet[9] = 17
	copy(packet[12:16], net.IPv4(10, 0, 0, 2).To4())
	copy(packet[16:20], net.IPv4(8, 8, 8, 8).To4())
	for _, data := range [][]byte{packet, append([]byte{0, 0, 8, 0}, packet...)} {
		if !strings.Contains(packetSummary(data), "10.0.0.2 -> 8.8.8.8 protocol=17") {
			t.Fatal(packetSummary(data))
		}
	}
	for size := 0; size < 20; size++ {
		packetSummary(packet[:size])
	}
}

func TestTracedDevicePreservesPackets(t *testing.T) {
	reader, writer := net.Pipe()
	defer reader.Close()
	defer writer.Close()
	reader.SetDeadline(time.Now().Add(time.Second))
	traced := &tracedDevice{ReadWriteCloser: reader}
	payload := []byte{0x45, 1, 2, 3}
	go func() {
		writer.Write(payload)
		io.Copy(writer, writer)
	}()
	buffer := make([]byte, 32)
	count, err := traced.Read(buffer)
	if err != nil || !bytes.Equal(payload, buffer[:count]) || traced.readPackets.Load() != 1 {
		t.Fatalf("read changed: %v", err)
	}
	if _, err := traced.Write(payload); err != nil || traced.writeBytes.Load() != 4 {
		t.Fatalf("write changed: %v", err)
	}
}

func TestTracedDeviceDropsNonIPv4(t *testing.T) {
	device := &packetDevice{incoming: make(chan []byte, 4), outgoing: make(chan []byte, 1), done: make(chan struct{})}
	defer device.Close()
	traced := &tracedDevice{ReadWriteCloser: device}
	ipv6 := make([]byte, 40)
	ipv6[0] = 0x60
	ipv4 := make([]byte, 20)
	ipv4[0] = 0x45
	withPI := append([]byte{0, 0, 8, 0}, ipv4...)
	device.incoming <- ipv6
	device.incoming <- append([]byte{0, 0, 0x86, 0xdd}, ipv6...)
	device.incoming <- ipv4
	device.incoming <- withPI
	for _, expected := range [][]byte{ipv4, withPI} {
		buffer := make([]byte, 100)
		count, err := traced.Read(buffer)
		if err != nil || !bytes.Equal(buffer[:count], expected) {
			t.Fatalf("IPv4 packet changed or non-IPv4 forwarded: %v %v", buffer[:count], err)
		}
	}
	if traced.readPackets.Load() != 2 || traced.droppedPackets.Load() != 2 {
		t.Fatalf("unexpected counts: read=%d dropped=%d", traced.readPackets.Load(), traced.droppedPackets.Load())
	}
}

func TestSOCKSProbeConnectAndReject(t *testing.T) {
	for _, replyCode := range []byte{0, 5} {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		go func() {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(time.Second))
			greeting := make([]byte, 3)
			io.ReadFull(conn, greeting)
			conn.Write([]byte{5, 0})
			request := make([]byte, 4)
			io.ReadFull(conn, request)
			if !bytes.Equal(request, []byte{5, 1, 0, 3}) {
				return
			}
			length := make([]byte, 1)
			io.ReadFull(conn, length)
			target := make([]byte, int(length[0])+2)
			io.ReadFull(conn, target)
			if string(target[:len(target)-2]) != "www.google.com" {
				return
			}
			conn.Write([]byte{5, replyCode, 0, 1, 127, 0, 0, 1, 0, 80})
		}()
		conn, err := dialSOCKS(context.Background(), listener.Addr().String(), "www.google.com:443")
		listener.Close()
		if (err != nil) != (replyCode != 0) {
			t.Fatalf("reply=%d error=%v", replyCode, err)
		}
		if conn != nil {
			conn.Close()
		}
	}
}

func TestDNSTunnelUsesSOCKSTCP(t *testing.T) {
	proxyListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer proxyListener.Close()
	serverResult := make(chan error, 1)
	go func() {
		conn, err := proxyListener.Accept()
		if err != nil {
			serverResult <- err
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		greeting := make([]byte, 3)
		if _, err := io.ReadFull(conn, greeting); err != nil {
			serverResult <- err
			return
		}
		conn.Write([]byte{5, 0})
		request := make([]byte, 10)
		if _, err := io.ReadFull(conn, request); err != nil {
			serverResult <- err
			return
		}
		if !bytes.Equal(request, []byte{5, 1, 0, 1, 8, 8, 8, 8, 0, 53}) {
			serverResult <- fmt.Errorf("unexpected SOCKS DNS target %v", request)
			return
		}
		conn.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 80})
		dnsConn := &dns.Conn{Conn: conn}
		question, err := dnsConn.ReadMsg()
		if err != nil {
			serverResult <- err
			return
		}
		response := new(dns.Msg).SetReply(question)
		answer, err := dns.NewRR("www.google.com. 60 IN A 142.250.1.1")
		if err != nil {
			serverResult <- err
			return
		}
		response.Answer = []dns.RR{answer}
		serverResult <- dnsConn.WriteMsg(response)
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server, address, err := startDNSTunnel(ctx, proxyListener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer server.Shutdown()
	client := &dns.Client{Net: "udp", Timeout: 3 * time.Second}
	question := new(dns.Msg).SetQuestion("www.google.com.", dns.TypeA)
	response, _, err := client.Exchange(question, address)
	if err != nil {
		t.Fatal(err)
	}
	if err := <-serverResult; err != nil {
		t.Fatal(err)
	}
	if response.Rcode != dns.RcodeSuccess || len(response.Answer) != 1 || response.Id != question.Id {
		t.Fatalf("invalid DNS response: %v", response)
	}
}

type packetDevice struct {
	incoming chan []byte
	outgoing chan []byte
	done     chan struct{}
}

func (device *packetDevice) Read(buffer []byte) (int, error) {
	select {
	case packet := <-device.incoming:
		return copy(buffer, packet), nil
	case <-device.done:
		return 0, os.ErrClosed
	}
}

func (device *packetDevice) Write(packet []byte) (int, error) {
	select {
	case device.outgoing <- append([]byte(nil), packet...):
		return len(packet), nil
	case <-device.done:
		return 0, os.ErrClosed
	}
}

func (device *packetDevice) Close() error { close(device.done); return nil }

func TestTUNDNSRepeatedQueries(t *testing.T) {
	listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ready := make(chan struct{})
	server := &dns.Server{PacketConn: listener, NotifyStartedFunc: func() { close(ready) },
		Handler: dns.HandlerFunc(func(writer dns.ResponseWriter, question *dns.Msg) {
			writer.WriteMsg(new(dns.Msg).SetReply(question))
		})}
	go server.ActivateAndServe()
	<-ready
	defer server.Shutdown()
	device := &packetDevice{incoming: make(chan []byte, 2), outgoing: make(chan []byte, 8), done: make(chan struct{})}
	defer device.Close()
	if err := tun2socks.StartFromIO(device, 1400, "127.0.0.1:1", listener.LocalAddr().String()); err != nil {
		t.Fatal(err)
	}
	for _, identifier := range []uint16{1001, 1002} {
		question := new(dns.Msg).SetQuestion("www.google.com.", dns.TypeA)
		question.Id = identifier
		payload, err := question.Pack()
		if err != nil {
			t.Fatal(err)
		}
		packet := make([]byte, 28+len(payload))
		packet[0], packet[8], packet[9] = 0x45, 64, 17
		binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
		copy(packet[12:16], []byte{10, 0, 0, 2})
		copy(packet[16:20], []byte{8, 8, 8, 8})
		var sum uint32
		for offset := 0; offset < 20; offset += 2 {
			sum += uint32(binary.BigEndian.Uint16(packet[offset : offset+2]))
		}
		for sum > 65535 {
			sum = sum&65535 + sum>>16
		}
		binary.BigEndian.PutUint16(packet[10:12], ^uint16(sum))
		binary.BigEndian.PutUint16(packet[20:22], 53000)
		binary.BigEndian.PutUint16(packet[22:24], 53)
		binary.BigEndian.PutUint16(packet[24:26], uint16(8+len(payload)))
		copy(packet[28:], payload)
		device.incoming <- packet
		select {
		case response := <-device.outgoing:
			if len(response) < 40 {
				t.Fatalf("short response: %v", response)
			}
			var answer dns.Msg
			if err := answer.Unpack(response[28:]); err != nil {
				t.Fatal(err)
			}
			if answer.Id != identifier {
				t.Fatalf("wrong DNS ID: %d", answer.Id)
			}
		case <-time.After(time.Second):
			t.Fatalf("no TUN DNS reply for query %d on reused UDP flow", identifier)
		}
	}
}
