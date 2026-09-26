// Command main is the chall-manager deployment scenario for the xin challenge.
//
// chall-manager sets the stack config key xin:identity before running us. The
// xin-instance allocator on the CTF host does the real work. This program runs
// it through a local.Command and republishes its connection_info. xin's flag
// is static and registered in CTFd, so no "flags" output is exported.
//
// The chall-manager Go SDK is not imported: it pulls in pulumi-kubernetes,
// whose provider plugin is not available on this host.
package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/pulumi/pulumi-command/sdk/go/command/local"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

// defaultAllocator runs under sudo because chall-manager is unprivileged. -n
// turns a broken sudoers rule into a failure instead of a password prompt.
const defaultAllocator = "/run/wrappers/bin/sudo -n /run/current-system/sw/bin/xin-instance"

// allocation is the single JSON line `xin-instance create` prints on stdout.
type allocation struct {
	Identity       string `json:"identity"`
	Slot           int    `json:"slot"`
	Port           int    `json:"port"`
	ConnectionInfo string `json:"connection_info"`
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "xin")
		identity := cfg.Require("identity")

		allocator := cfg.Get("allocator")
		if allocator == "" {
			allocator = defaultAllocator
		}

		id := shellQuote(identity)
		instance, err := local.NewCommand(ctx, "instance", &local.CommandArgs{
			Create: pulumi.String(fmt.Sprintf("%s create --identity %s", allocator, id)),
			Delete: pulumi.String(fmt.Sprintf("%s destroy --identity %s", allocator, id)),
		})
		if err != nil {
			return err
		}

		connectionInfo := instance.Stdout.ApplyT(func(stdout string) (string, error) {
			var a allocation
			if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &a); err != nil {
				return "", fmt.Errorf("allocator did not print the expected JSON (got %q): %w", stdout, err)
			}
			if a.ConnectionInfo == "" {
				return "", fmt.Errorf("allocator returned an incomplete allocation: %q", stdout)
			}
			return a.ConnectionInfo, nil
		})

		ctx.Export("connection_info", connectionInfo)
		return nil
	})
}

// shellQuote wraps s in single quotes so a shell passes it through verbatim.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
