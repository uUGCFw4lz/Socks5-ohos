package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync/atomic"
	"time"

	"github.com/dosgo/go-tun2socks/socks"
	"github.com/miekg/dns"
	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/net/proxy"
)

type tracedDevice struct {
	io.ReadWriteCloser
	readPackets    atomic.Uint64
	readBytes      atomic.Uint64
	writePackets   atomic.Uint64
	writeBytes     atomic.Uint64
	droppedPackets atomic.Uint64
}

func (device *tracedDevice) Read(buffer []byte) (int, error) {
	for {
		count, err := device.ReadWriteCloser.Read(buffer)
		if count > 0 && ipv4Payload(buffer[:count]) == nil {
			if device.droppedPackets.Add(1) <= 3 {
				log.Printf("[TUN drop] non-IPv4 packet bytes=%d", count)
			}
			if err != nil {
				return 0, err
			}
			continue
		}
		if count > 0 {
			packets := device.readPackets.Add(1)
			device.readBytes.Add(uint64(count))
			if packets <= 16 || packets <= 1000 && importantPacket(buffer[:count]) {
				log.Printf("[TUN RX app->stack] packet=%d bytes=%d %s", packets, count, packetSummary(buffer[:count]))
			}
		}
		if err != nil {
			log.Printf("[TUN RX error] %v", err)
		}
		return count, err
	}
}

func (device *tracedDevice) Write(buffer []byte) (int, error) {
	count, err := device.ReadWriteCloser.Write(buffer)
	if count > 0 {
		packets := device.writePackets.Add(1)
		device.writeBytes.Add(uint64(count))
		if packets <= 16 || packets <= 1000 && importantPacket(buffer[:count]) {
			log.Printf("[TUN TX stack->app] packet=%d bytes=%d %s", packets, count, packetSummary(buffer[:count]))
		}
	}
	if err != nil {
		log.Printf("[TUN TX error] %v", err)
	}
	return count, err
}

func ipv4Payload(packet []byte) []byte {
	if len(packet) >= 5 && packet[0]>>4 != 4 && packet[2] == 0x08 && packet[3] == 0x00 {
		packet = packet[4:]
	}
	if len(packet) > 0 && packet[0]>>4 == 4 {
		return packet
	}
	return nil
}

func packetSummary(packet []byte) string {
	packet = ipv4Payload(packet)
	if len(packet) >= 20 {
		return fmt.Sprintf("IPv4 %s -> %s protocol=%d %s", net.IP(packet[12:16]), net.IP(packet[16:20]), packet[9], transportSummary(packet, int(packet[0]&15)*4, packet[9]))
	}
	return "invalid/truncated IP header"
}

func transportSummary(packet []byte, offset int, protocol byte) string {
	if offset < 20 || len(packet) < offset+8 {
		return ""
	}
	source := binary.BigEndian.Uint16(packet[offset : offset+2])
	target := binary.BigEndian.Uint16(packet[offset+2 : offset+4])
	if protocol == 6 && len(packet) >= offset+20 {
		return fmt.Sprintf("ports=%d->%d flags=0x%02x", source, target, packet[offset+13])
	}
	if protocol == 17 {
		if (source == 53 || target == 53) && len(packet) >= offset+20 {
			return fmt.Sprintf("ports=%d->%d DNS id=%d flags=0x%04x", source, target,
				binary.BigEndian.Uint16(packet[offset+8:offset+10]), binary.BigEndian.Uint16(packet[offset+10:offset+12]))
		}
		return fmt.Sprintf("ports=%d->%d", source, target)
	}
	return ""
}

func importantPacket(packet []byte) bool {
	packet = ipv4Payload(packet)
	if len(packet) < 20 {
		return false
	}
	offset, protocol := int(packet[0]&15)*4, packet[9]
	if offset < 20 || len(packet) < offset+20 {
		return false
	}
	if protocol == 6 {
		return packet[offset+13]&0x07 != 0
	}
	if protocol == 17 {
		source, target := binary.BigEndian.Uint16(packet[offset:offset+2]), binary.BigEndian.Uint16(packet[offset+2:offset+4])
		return source == 53 || target == 53 || target == 443
	}
	return false
}

func (device *tracedDevice) report(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			log.Printf("[TUN totals] app->stack packets=%d bytes=%d stack->app packets=%d bytes=%d droppedNonIPv4=%d",
				device.readPackets.Load(), device.readBytes.Load(), device.writePackets.Load(), device.writeBytes.Load(), device.droppedPackets.Load())
		}
	}
}

func dialSOCKS(ctx context.Context, address, target string) (net.Conn, error) {
	dialer, err := proxy.SOCKS5("tcp", address, nil, &net.Dialer{Timeout: 8 * time.Second})
	if err != nil {
		return nil, err
	}
	deadline, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	return dialer.(proxy.ContextDialer).DialContext(deadline, "tcp", target)
}

func diagnose(ctx context.Context, address string) {
	log.Printf("[PROBE begin] proxy=%s (independent of TUN; not proof of app traffic forwarding)", address)
	var dialer net.Dialer
	dialer.Timeout = 8 * time.Second
	control, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		log.Printf("[PROBE TCP FAIL] proxy=%s error=%v", address, err)
		return
	}
	log.Printf("[PROBE TCP OK] local=%s remote=%s", control.LocalAddr(), control.RemoteAddr())
	control.Close()

	remote, err := dialSOCKS(ctx, address, "www.google.com:443")
	if err != nil {
		log.Printf("[PROBE SOCKS CONNECT FAIL] target=www.google.com:443 error=%v", err)
	} else {
		log.Printf("[PROBE SOCKS CONNECT OK] target=www.google.com:443 local=%s remote=%s (TCP tunnel only)", remote.LocalAddr(), remote.RemoteAddr())
		remote.Close()
	}
	if ctx.Err() != nil {
		return
	}
	question := new(dns.Msg).SetQuestion("www.google.com.", dns.TypeA)
	response, dnsErr := exchangeProxyDNS(ctx, address, question)
	if dnsErr != nil {
		log.Printf("[PROBE TCP DNS FAIL] %v", dnsErr)
	} else {
		log.Printf("[PROBE TCP DNS response] name=www.google.com rcode=%d answers=%d", response.Rcode, len(response.Answer))
		for _, answer := range response.Answer {
			if record, ok := answer.(*dns.A); ok {
				probeHTTPS(ctx, address, net.JoinHostPort(record.A.String(), "443"))
				break
			}
		}
	}
	probeHTTPS(ctx, address, "www.google.com:443")
	if err := probeDNS(ctx, address); err != nil {
		log.Printf("[PROBE UDP DNS FAIL diagnostic-only] app DNS now uses TCP: %v", err)
	}
	log.Print("[PROBE end]")
}

func probeHTTPS(ctx context.Context, address, target string) {
	log.Printf("[PROBE HTTPS begin] target=%s SNI=www.google.com", target)
	remote, err := dialSOCKS(ctx, address, target)
	if err != nil {
		log.Printf("[PROBE HTTPS CONNECT FAIL] target=%s error=%v", target, err)
		return
	}
	defer remote.Close()
	stop := context.AfterFunc(ctx, func() { remote.Close() })
	defer stop()
	remote.SetDeadline(time.Now().Add(8 * time.Second))
	secure := tls.Client(remote, &tls.Config{ServerName: "www.google.com", MinVersion: tls.VersionTLS12})
	if err := secure.HandshakeContext(ctx); err != nil {
		log.Printf("[PROBE HTTPS TLS FAIL] target=%s error=%v", target, err)
		return
	}
	log.Printf("[PROBE HTTPS TLS OK] target=%s version=%x", target, secure.ConnectionState().Version)
	if _, err := io.WriteString(secure, "HEAD / HTTP/1.1\r\nHost: www.google.com\r\nConnection: close\r\n\r\n"); err != nil {
		log.Printf("[PROBE HTTPS request FAIL] target=%s error=%v", target, err)
		return
	}
	buffer := make([]byte, 128)
	count, err := secure.Read(buffer)
	if count > 0 {
		line := bytes.SplitN(buffer[:count], []byte("\r\n"), 2)[0]
		log.Printf("[PROBE HTTPS response] target=%s status=%q", target, line)
	} else {
		log.Printf("[PROBE HTTPS response FAIL] target=%s error=%v", target, err)
	}
}

func probeDNS(ctx context.Context, address string) error {
	control, err := (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, "tcp", address)
	if err != nil {
		return fmt.Errorf("control TCP: %w", err)
	}
	defer control.Close()
	stopControl := context.AfterFunc(ctx, func() { control.Close() })
	defer stopControl()
	control.SetDeadline(time.Now().Add(8 * time.Second))
	relay, err := socks.SocksUdpCmd(control, "0.0.0.0:0")
	if err != nil || relay == nil {
		return fmt.Errorf("UDP ASSOCIATE failed: relay=%v error=%v", relay, err)
	}
	log.Printf("[PROBE UDP ASSOCIATE OK] relay=%s", relay)
	udp, err := (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, "udp", relay.String())
	if err != nil {
		return fmt.Errorf("relay socket: %w", err)
	}
	defer udp.Close()
	stopUDP := context.AfterFunc(ctx, func() { udp.Close() })
	defer stopUDP()
	udp.SetDeadline(time.Now().Add(8 * time.Second))
	question := dnsmessage.Message{
		Header:    dnsmessage.Header{ID: 0x5305, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("www.google.com."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}},
	}
	query, err := question.Pack()
	if err != nil {
		return err
	}
	if _, err := udp.Write(socks.EncodeUDPPacket("8.8.8.8:53", query)); err != nil {
		return fmt.Errorf("DNS send: %w", err)
	}
	log.Printf("[PROBE DNS sent] local=%s relay=%s target=8.8.8.8:53 name=www.google.com", udp.LocalAddr(), relay)
	buffer := make([]byte, 4096)
	count, err := udp.Read(buffer)
	if err != nil {
		return fmt.Errorf("DNS receive via relay=%s: %w", relay, err)
	}
	if count < 10 || !bytes.Equal(buffer[:3], []byte{0, 0, 0}) || buffer[3] != 1 {
		return errors.New("unexpected SOCKS5 UDP reply header (upstream decoder only supports IPv4)")
	}
	var response dnsmessage.Message
	if err := response.Unpack(buffer[10:count]); err != nil {
		return fmt.Errorf("DNS decode: %w", err)
	}
	if response.ID != question.ID || !response.Response || response.RCode != dnsmessage.RCodeSuccess {
		return fmt.Errorf("DNS invalid response id=%d rcode=%s", response.ID, response.RCode)
	}
	log.Printf("[PROBE DNS OK] name=www.google.com answers=%d bytes=%d", len(response.Answers), count)
	return nil
}
