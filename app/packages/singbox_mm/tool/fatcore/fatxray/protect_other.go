//go:build !android

package fatxray

// Nothing to do: a Network Extension's own sockets already bypass the tunnel
// it provides, and there is no equivalent of VpnService.protect to call.
func setProtector(p Protector) {}
