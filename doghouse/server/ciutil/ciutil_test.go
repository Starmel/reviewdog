package ciutil

import (
	"fmt"
	"net/http/httptest"
	"testing"
)

func TestIsFromCI(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)

	const allowedIP = "67.225.139.254:8000"
	r.RemoteAddr = allowedIP
	if !IsFromCI(r) {
		t.Error("IsFromCI(%q) = false, want true", allowedIP)
	}

	const notAllowedIP = "93.184.216.34:8000"
	r.RemoteAddr = notAllowedIP
	if IsFromCI(r) {
		t.Error("IsFromCI(%q) = true, want false", notAllowedIP)
	}
}

func TestUpdateTravisCIIPAddrs(t *testing.T) {
	if err := UpdateTravisCIIPAddrs(nil); err != nil {
		t.Fatal(err)
	}
	if len(travisIPAddrs) == 0 {
		t.Fatal("travisIPAddrs is empty, want some ip addrs")
	}
	for addr := range travisIPAddrs {
		t.Log(addr)
	}
}

func TestIsFromTravisCI(t *testing.T) {
	if err := UpdateTravisCIIPAddrs(nil); err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "/", nil)
	for addr := range travisIPAddrs {
		r.RemoteAddr = fmt.Sprintf("%s:8000", addr)
		if !IsFromTravisCI(r) {
			t.Errorf("IsIsFromTravisCI(%q) = false, want true", r.RemoteAddr)
		}
	}

	const notAllowedIP = "93.184.216.34:8000"
	r.RemoteAddr = notAllowedIP
	if IsFromTravisCI(r) {
		t.Error("IsFromTravisCI(%q) = true, want false", notAllowedIP)
	}
}

func TestIsFromAppveyor(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)

	const allowedIP = "67.225.139.254:8000"
	r.RemoteAddr = allowedIP
	if !IsFromAppveyor(r) {
		t.Error("IsFromAppveyor(%q) = false, want true", allowedIP)
	}

	const notAllowedIP = "93.184.216.34:8000"
	r.RemoteAddr = notAllowedIP
	if IsFromAppveyor(r) {
		t.Error("IsFromAppveyor(%q) = true, want false", notAllowedIP)
	}
}
