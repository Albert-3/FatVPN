// Package fatxray exposes the Xray core to the mobile side of the app.
//
// sing-box carries every node in the subscription except those on Xray's XHTTP
// transport, which it has no implementation for. Those are terminated here
// instead and offered to sing-box as a plain local SOCKS server, so the tunnel,
// its routing and its split tunnelling stay sing-box's job either way.
//
// Bound by gomobile together with sing-box's libbox — see the module comment
// for why the two cannot be separate libraries.
package fatxray

import (
	"github.com/xtls/libxray/xray"
)

// Start brings the core up with configJSON, which must already describe the
// local SOCKS inbound sing-box will dial.
//
// Returns an error if a core is already running: the caller is expected to
// Stop first, and silently replacing a live core would strand its connections.
func Start(configJSON string) error {
	return xray.RunXrayFromJSON(configJSON)
}

// Stop shuts the core down. Stopping an already-stopped core is not an error,
// which keeps teardown paths free of state checks.
func Stop() error {
	return xray.StopXray()
}

// IsRunning reports whether a core is up.
func IsRunning() bool {
	return xray.GetXrayState()
}

// Version is the Xray core version, for the support bundle.
func Version() string {
	return xray.XrayVersion()
}

// Protector hands a freshly created socket to the platform so it can be kept
// out of the tunnel this core is feeding.
//
// Without it the core's own connection to the node enters the tun device,
// sing-box routes it back to the core's SOCKS port, and the session deadlocks
// on itself.
type Protector interface {
	Protect(fd int) bool
}

// SetProtector installs p for every socket the core opens from now on. Call it
// before Start; sockets created earlier are not revisited.
//
// A no-op on platforms whose tunnel already excludes its own sockets — iOS
// gives a Network Extension that for free.
func SetProtector(p Protector) {
	setProtector(p)
}
