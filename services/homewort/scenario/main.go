// Command main is the chall-manager deployment scenario for the homewort
// challenge.
//
// chall-manager creates one Pulumi stack per instance and sets the stack config
// key homewort:identity to that instance's identity before running us. All the
// real work (slot bookkeeping, disk overlay, flag generation, QEMU) lives in the
// homewort-instance allocator on the CTF host, so this program is only a bridge:
// it drives the allocator through a local.Command whose lifecycle Pulumi already
// owns, then republishes the allocator's JSON under the two output names
// chall-manager harvests in pkg/iac/stack.go -- "connection_info" (string) and
// "flags" (array of strings).
//
// The chall-manager Go SDK is deliberately not imported: it statically pulls in
// pulumi-kubernetes, whose provider plugin is not available on this host.
package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/pulumi/pulumi-command/sdk/go/command/local"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

// defaultAllocator is how the scenario reaches the allocator on the CTF host.
// chall-manager runs unprivileged, hence sudo; -n keeps a misconfigured sudoers
// rule a hard failure instead of a hang on a password prompt.
const defaultAllocator = "/run/wrappers/bin/sudo -n /run/current-system/sw/bin/homewort-instance"

// allocation is the single JSON line `homewort-instance create` prints on stdout.
// Fields the scenario does not export are kept so that a truncated or foreign
// payload is still recognisable in the validation below.
type allocation struct {
	Identity       string `json:"identity"`
	Slot           int    `json:"slot"`
	Port           int    `json:"port"`
	Flag           string `json:"flag"`
	ConnectionInfo string `json:"connection_info"`
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "homewort")
		identity := cfg.Require("identity")

		allocator := cfg.Get("allocator")
		if allocator == "" {
			allocator = defaultAllocator
		}

		// local.Command runs its scripts through a shell, so the identity is
		// quoted even though the allocator itself rejects anything outside
		// [a-z0-9]{1,64}.
		id := shellQuote(identity)
		instance, err := local.NewCommand(ctx, "instance", &local.CommandArgs{
			Create: pulumi.String(fmt.Sprintf("%s create --identity %s", allocator, id)),
			Delete: pulumi.String(fmt.Sprintf("%s destroy --identity %s", allocator, id)),
		})
		if err != nil {
			return err
		}

		// Parse once; both exports are projections of the same allocation. An
		// unparseable or incomplete payload fails the whole deployment, which
		// CTFd surfaces to the player, rather than handing out an empty flag.
		alloc := instance.Stdout.ApplyT(func(stdout string) (allocation, error) {
			var a allocation
			if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &a); err != nil {
				return a, fmt.Errorf("allocator did not print the expected JSON (got %q): %w", stdout, err)
			}
			if a.ConnectionInfo == "" || a.Flag == "" {
				return a, fmt.Errorf("allocator returned an incomplete allocation: %q", stdout)
			}
			return a, nil
		})

		ctx.Export("connection_info", alloc.ApplyT(func(a any) string {
			return a.(allocation).ConnectionInfo
		}))
		ctx.Export("flags", alloc.ApplyT(func(a any) []string {
			return []string{a.(allocation).Flag}
		}))
		return nil
	})
}

// shellQuote wraps s in single quotes so a shell passes it through verbatim.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
