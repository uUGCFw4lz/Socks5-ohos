package main

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func TestAAAAResponsePolicyRoundTrip(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	listener.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server, local, err := startDNSTunnel(ctx, address)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Shutdown()
	question := new(dns.Msg).SetQuestion("www.google.com.", dns.TypeAAAA)
	client := &dns.Client{Net: "udp", Timeout: time.Second}
	response, _, err := client.Exchange(question, local)
	if err != nil {
		t.Fatal(err)
	}
	if response.Rcode != dns.RcodeSuccess || len(response.Answer) != 0 || response.Id != question.Id ||
		!response.Response || len(response.Question) != 1 || response.Question[0] != question.Question[0] {
		t.Fatalf("invalid AAAA NODATA response: %v", response)
	}
}
