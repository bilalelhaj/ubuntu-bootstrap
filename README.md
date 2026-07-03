# server-base-install

> Bootstrap a Debian/Ubuntu server for hosting Docker workloads behind a Caddy
> reverse proxy — UFW properly integrated with Docker, automatic container
> healing, optional SSH-key import from GitHub.

## What it sets up

| Component | Notes |
| :--- | :--- |
| Non-root sudo user | Default `chef`, random 16-byte password |
| UFW firewall | Default deny incoming; allow SSH, HTTP, HTTPS |
| Docker | Installed via official `get-docker.sh`, size-capped `local` logging |
| UFW ↔ Docker rules | Containers honor the host firewall (Docker bypasses UFW by default) |
| `/var/www` workspace | `www-data` ownership, GID-82 `docker-www-data` group for container parity |
| Caddy reverse proxy | [main-caddy-proxy](https://github.com/jonaaix/main-caddy-proxy), pinned to a known commit |
| docker-autoheal | Cron job that restarts unhealthy containers every minute |
| Convenience tools | `ctop`, `htop`, `btop`, `micro`, `z` directory-jump, shell aliases |
| SSH keys (optional) | Imported from a GitHub user via `ssh-import-id` |

## Tested on

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS

Should work on Debian 12 with the same `apt`-based primitives, but not yet verified.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/bilalelhaj/ubuntu-bootstrap/main/base-install.sh -o base-install.sh
chmod +x base-install.sh
./base-install.sh
```

The script prompts for:

- An email for Let's Encrypt certificate notifications
- *(Optional)* A GitHub username to import SSH public keys from
- *(Optional)* A hostname for the server — a short name (`business-prod`) or an FQDN (`business-prod.example.com`); leave blank to keep the current one. An FQDN is recommended if you plan to run mail or monitoring later, so `hostname -f` resolves correctly
- A `y/N` confirmation that displays the full plan before any change is made

## Configuration

Override defaults via environment variables:

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `TARGET_USER` | `chef` | System user to create |
| `CTOP_VERSION` | `0.7.7` | ctop release to install |
| `CADDY_PROXY_COMMIT` | pinned SHA | Commit of `main-caddy-proxy` to deploy |

```bash
TARGET_USER=bilal ./base-install.sh
```

## Re-running

The script is idempotent — safe to run again on the same server. Every step
either guards itself or is rewritten in place, so re-runs don't duplicate lines
or clobber state:

- The `.bashrc` z-jump + alias block is delimited by markers and regenerated on
  every run, so aliases stay in sync and never accumulate duplicates.
- The `chef` user, Docker install, and Caddy checkout are created only if
  missing; the generated password is shown only on first creation.
- To force a fresh pinned Caddy checkout, remove `/var/www/main-caddy-proxy`
  before re-running.

## What it does NOT do

- Does not modify `sshd_config` — the OS default stays in place
- Does not install fail2ban, monit, or external monitoring
- Does not configure backups or a swap file
- Does not register a domain or manage DNS

## Security notes

- The script runs `apt`, `ufw`, and `docker` as root — please read it before running on a real server.
- `set -euo pipefail` aborts on the first error; `sudo -v` is called up front so the run is non-interactive afterwards.
- `main-caddy-proxy` is pinned to a known commit. Update by reviewing https://github.com/jonaaix/main-caddy-proxy/commits/main and bumping `CADDY_PROXY_COMMIT`.
- A random 16-byte password is generated for the new user; SSH-key auth is recommended (use the GitHub-import prompt or add keys to `/home/$TARGET_USER/.ssh/authorized_keys`).

## Related projects

- [vaultwarden-docker-caddy](https://github.com/bilalelhaj/vaultwarden-docker-caddy) — production-ready Vaultwarden setup that runs nicely on top of this base install.

## License

[MIT](LICENSE) © Bilal El Haj
