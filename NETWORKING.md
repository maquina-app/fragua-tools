# Reaching External Services from Fragua Containers

How a containerized Rails app (cloned and developed by the fragua CLI) connects to
Redis, PostgreSQL, MySQL, or any other service that runs **outside** the container.

SQLite needs none of this — it's a file on a mounted volume, not a network service,
which is why SQLite-backed apps "just work." Everything below is about networked
services.

The clients are already present in the images (PostgreSQL `libpq`, `mysql2`,
Redis `hiredis`), so connectivity — not missing drivers — is the only concern.

---

## The one rule that causes most failures

Inside a container, `localhost` / `127.0.0.1` means **the container itself** — its
own loopback namespace. It never means "the host the container runs on."

So any cloned app whose config says `redis://localhost:6379` or
`postgres://localhost:5432` will fail in a container unless that service also runs
inside the same container.

Everything else here is just: **what address do I use instead, and is the path
open.**

---

## Two things to check every time

1. **Addressing** — does the app's config point at something other than `localhost`?
2. **Reachability** — is the listening service bound to an address reachable from
   outside its own loopback, and does its firewall allow the connection?

---

## Case 1 — Service on the same host (e.g. your Mac), container is local

Both sub-rules apply at once.

### Addressing — how the container names the host

| Runtime | Host address to use |
|---|---|
| Docker Desktop (macOS) | `host.docker.internal` (resolves automatically) |
| Apple `container` runtime | the **gateway IP** of the container's vmnet subnet (the `.1`, e.g. `192.168.64.1`) — find it inside with `ip route \| grep default` |
| Docker on Linux (bare metal) | add `--add-host host.docker.internal:host-gateway`, or use the bridge gateway (commonly `172.17.0.1`) |

### Reachability — the host service must accept the connection

- It must **bind to a routable interface, not just `127.0.0.1`.** A service bound
  to localhost-only will refuse the container even with correct addressing, because
  from the host's view the connection arrives from the VM/bridge IP, not loopback.
  - **PostgreSQL:** set `listen_addresses` (e.g. `'*'`) in `postgresql.conf`, plus a
    matching `pg_hba.conf` line for the container subnet.
  - **Redis:** `bind` must include a non-loopback address; if you open it, set
    `requirepass`.
- The host firewall must allow the container subnet.

## Case 2 — Service in another container

- **Same user-defined network:** address by **container/service name** (built-in
  DNS). e.g. `redis://redis:6379`. This is the normal, portable case. The internal
  port is used directly — published/`-p` ports are irrelevant container-to-container.
- **Different networks / different runtimes:** they can't see each other by name.
  Put them on a shared network, or fall back to host-IP routing (Case 1) via the
  host's published port.
- `localhost` never reaches a sibling container — only the container's own loopback.

## Case 3 — Service is remote (another server / managed DB)

The simplest case — it behaves like any normal outbound client.

- Use the real hostname/IP:
  `postgres://user:pw@db.example.com:5432/...`, `redis://cache.internal:6379`.
- No host-gateway tricks needed — the container makes an ordinary outbound TCP
  connection.
- Requirements are the usual ones:
  - the container has egress (default yes),
  - DNS resolves,
  - the remote service's firewall / security group allows the container's **egress
    IP** — which after NAT is typically the **host's** IP, not the container's
    internal IP (important for IP allowlists),
  - TLS if the service requires it.
- For cloud DBs (RDS, managed Redis) you usually only need to allowlist the host's
  public/VPC IP.

---

## Quick reference

| Service location | Address the app should use | Extra condition |
|---|---|---|
| Same host, Docker Desktop | `host.docker.internal` | host svc binds non-loopback |
| Same host, Apple `container` | subnet gateway IP (`ip route`) | host svc binds non-loopback |
| Same host, Docker on Linux | `host-gateway` / bridge IP | host svc binds non-loopback |
| Sibling container | service/container name | shared user-defined network |
| Remote server / managed | real hostname/IP | egress + remote firewall allows host's NAT IP |

---

## Mental model

Two checks, every time:

1. Does the app's config point at something other than `localhost`?
2. Is the listening service bound to an address reachable from outside its own
   loopback (and does its firewall allow it)?

SQLite sidesteps all of this because it's a file, not a socket.
