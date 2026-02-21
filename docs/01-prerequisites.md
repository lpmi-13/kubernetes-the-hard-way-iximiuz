# Prerequisites

## Labctl

You'll need to have [labctl](ttps://github.com/iximiuz/labctl) installed, so go ahead and do that first.

Once you have it installed, set up an account at [labs.iximiuz.com](https://labs.iximiuz.com). You only need a GitHub username. It's possible that you _might_ get flagged as a potential bot, but if you do, just send a message in the Discord server and you can get unblocked.

The current walkthrough was done with `labctl` version `0.1.58`.

## Go toolchain

The Tailscale provisioning flow in this repo uses `go run tailscale.com/cmd/get-authkey@latest` locally to mint one-off auth keys from OAuth credentials.
Install a current Go release before running the commands in `docs/02-compute-resources.md`.

## Tailscale account

Because we accomplish all the cool networking bits via tailscale magic, you'll need a Tailscale account and a tailnet OAuth client with:

- `auth_keys` permissions (for provisioning one-off auth keys)
- `devices:core` permissions (for cleanup of stale devices in `clean-up.sh`)

Go ahead and sign up [here](https://tailscale.com/) if you don't already have an account.
