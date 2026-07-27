package fatxray

// sing-box's libbox is bound *alongside* this package rather than imported by
// it, so without this nothing in the module would reference sing-box — and
// `go mod tidy` demotes it to an indirect dependency, where the version this
// app ships its tunnel core from is one `tidy` away from silently moving.
// The blank import keeps that version pinned in the main require block.
import _ "github.com/sagernet/sing-box/experimental/libbox"
