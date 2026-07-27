//go:build android

package fatxray

import (
	"github.com/xtls/libxray/controller"
)

func setProtector(p Protector) {
	if p == nil {
		return
	}
	controller.RegisterDialerController(func(fd uintptr) {
		p.Protect(int(fd))
	})
}
