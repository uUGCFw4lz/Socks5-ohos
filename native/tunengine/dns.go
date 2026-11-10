package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"time"

	"github.com/miekg/dns"
)

func exchangeProxyDNS(ctx context.Context, address string, question *dns.Msg) (*dns.Msg, error) {
	remote, err := dialSOCKS(ctx, address, "8.8.8.8:53")
	if err != nil {
		return nil, fmt.Errorf("SOCKS CONNECT DNS: %w", err)
	}
	defer remote.Close()
	stop := context.AfterFunc(ctx, func() { remote.Close() })
	defer stop()
	client := &dns.Client{Net: "tcp", Timeout: 8 * time.Second}
	response, _, err := client.ExchangeWithConnContext(ctx, question, &dns.Conn{Conn: remote})
	return response, err
}

func startDNSTunnel(ctx context.Context, address string) (*dns.Server, string, error) {
	listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		return nil, "", err
	}
	ready := make(chan struct{})
	stopped := make(chan error, 1)
	server := &dns.Server{
		PacketConn:        listener,
		UDPSize:           4096,
		NotifyStartedFunc: func() { close(ready) },
		Handler: dns.HandlerFunc(func(writer dns.ResponseWriter, question *dns.Msg) {
			if len(question.Question) != 1 {
				failure := new(dns.Msg).SetRcode(question, dns.RcodeFormatError)
				writer.WriteMsg(failure)
				return
			}
			name := question.Question[0].Name
			if question.Question[0].Qtype == dns.TypeAAAA {
				response := new(dns.Msg).SetReply(question)
				response.RecursionAvailable = true
				log.Printf("[DNS IPv4 policy] name=%s AAAA=NODATA", name)
				if err := writer.WriteMsg(response); err != nil {
					log.Printf("[DNS reply FAIL] name=%s error=%v", name, err)
				}
				return
			}
			started := time.Now()
			log.Printf("[DNS TCP begin] name=%s type=%d via=%s target=8.8.8.8:53", name, question.Question[0].Qtype, address)
			requestContext, cancel := context.WithTimeout(ctx, 10*time.Second)
			defer cancel()
			response, err := exchangeProxyDNS(requestContext, address, question)
			if err != nil {
				log.Printf("[DNS TCP FAIL] name=%s elapsed=%s error=%v", name, time.Since(started), err)
				response = new(dns.Msg).SetRcode(question, dns.RcodeServerFailure)
			} else {
				log.Printf("[DNS TCP OK] name=%s rcode=%d answers=%d elapsed=%s", name, response.Rcode, len(response.Answer), time.Since(started))
				for _, answer := range response.Answer {
					if record, ok := answer.(*dns.A); ok {
						log.Printf("[DNS answer] name=%s A=%s", name, record.A)
					}
				}
			}
			limit := uint16(dns.MinMsgSize)
			if option := question.IsEdns0(); option != nil && option.UDPSize() > limit {
				limit = option.UDPSize()
			}
			if limit > 4096 {
				limit = 4096
			}
			response.Truncate(int(limit))
			if err := writer.WriteMsg(response); err != nil {
				log.Printf("[DNS reply FAIL] name=%s error=%v", name, err)
			}
		}),
	}
	go func() { stopped <- server.ActivateAndServe() }()
	select {
	case <-ready:
		log.Printf("[DNS tunnel ready] UDP %s -> SOCKS5 %s -> TCP 8.8.8.8:53 IPv4-only", listener.LocalAddr(), address)
		return server, listener.LocalAddr().String(), nil
	case err := <-stopped:
		listener.Close()
		return nil, "", fmt.Errorf("DNS listener failed: %v", err)
	}
}
