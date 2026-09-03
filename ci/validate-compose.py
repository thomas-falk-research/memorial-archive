#!/usr/bin/env python3
"""Validate the docker-compose YAML that the app setup scripts generate.

There is no Docker (and so no `docker compose config`) in CI, so we reproduce what each setup
script writes — extract its compose heredoc and fill in representative variables exactly as the
unquoted `<<EOF` heredoc would — then parse it as YAML and assert the safety-critical structure:

  * it is valid YAML with a ``services:`` mapping (and, for full files, every service has an image);
  * any mount of the archive (ARCHIVE_ROOT) is READ-ONLY (``:ro``) — never writable;
  * apps that must not touch the archive at all don't mount it;
  * the family apps fronted by Caddy bind to loopback (127.0.0.1) only;
  * a service that joins the shared ``memorial`` network finds it declared ``external: true``.

An archive the masters can be written through, or a "private" app exposed on every interface, is a
silent-failure landmine — so a compose file that regresses any of these must fail the build.

Run: ``python3 ci/validate-compose.py``  (no arguments; exits non-zero on any failure).
"""
from __future__ import annotations

import os
import re
import string
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - surfaced loudly in CI
    sys.exit("validate-compose: PyYAML is required (apt install python3-yaml).")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Representative values for the BUILD-TIME variables the unquoted heredocs interpolate. The
# runtime secrets the scripts deliberately escape as `\$...` (so Docker expands them from .env at
# run time) are intentionally absent here, so they survive rendering as literal "${VAR}" strings —
# exactly as they appear in the file the script writes.
VARS = {
    "ARCHIVE_ROOT": "/srv/archive",
    "APP_DIR": "/srv/apps/app",
    "PCBACKUP_DIR": "/srv/pc-backups",
    "DOCKER_NET": "memorial",
    "IMAGE_TAG": "1.0.0",
    "uid": "1000",
    "gid": "1000",
    "tz": "Etc/UTC",
    "host_short": "archive",
    "COPYPARTY_IMAGE": "copyparty/ac",
    "COPYPARTY_PORT": "3939",
    "CZKAWKA_IMAGE": "jlesage/czkawka",
    "CZKAWKA_PORT": "5801",
    "DOCMOST_IMAGE": "docmost/docmost",
    "DOCMOST_PORT": "3000",
    "KOPIA_IMAGE": "kopia/kopia",
    "KOPIA_PORT": "51515",
    "STIRLING_IMAGE": "stirlingtools/stirling-pdf",
    "STIRLING_PORT": "8081",
    "PAPERLESS_PORT": "8000",
    "PG_IMAGE": "postgres:16-alpine",
    "REDIS_IMAGE": "redis:7-alpine",
    "OPENARCHIVER_IMAGE": "logiclabshq/open-archiver",
    "OPENARCHIVER_PORT": "3010",
    "OPENARCHIVER_BIND": "127.0.0.1",
    "OA_PG_IMAGE": "postgres:17-alpine",
    "OA_VALKEY_IMAGE": "valkey/valkey:8-alpine",
    "OA_MEILI_IMAGE": "getmeili/meilisearch:v1.38",
    "OA_TIKA_IMAGE": "apache/tika:3.2.2.0-full",
}

# (setup script, compose filename, expectations). archive: "ro" = must mount the archive read-only;
# None = must not mount it at all. loopback: every published port must bind 127.0.0.1 — or, where
# `tailnet=True`, this host's Tailscale address in 100.64.0.0/10. must_mount: bind-mount sources
# that have to be present.
APPS = [
    ("archive-copyparty-setup.sh", "docker-compose.yml",
     dict(archive="ro", loopback=True)),
    ("archive-czkawka-setup.sh", "docker-compose.yml",
     dict(archive="ro", loopback=True)),
    ("archive-immich-setup.sh", "docker-compose.override.yml",
     dict(archive="ro", loopback=None)),
    ("archive-paperless-setup.sh", "docker-compose.override.yml",
     dict(archive=None, loopback=None)),
    ("archive-stirling-setup.sh", "docker-compose.yml",
     dict(archive=None, loopback=True)),
    ("archive-docmost-setup.sh", "docker-compose.yml",
     dict(archive=None, loopback=True)),
    ("archive-kopia-setup.sh", "docker-compose.yml",
     dict(archive=None, loopback=None, must_mount=["/srv/pc-backups"])),
    # Open Archiver must NEVER mount the archive: mail is imported from COPIES placed in its own
    # import/ directory. That is the whole safety design, so the validator enforces it.
    # Open Archiver may also publish on the tailnet (`--tailscale`): reachable from the operator's
    # own devices over WireGuard, invisible to the LAN. 0.0.0.0 and LAN addresses stay refused.
    ("archive-openarchiver-setup.sh", "docker-compose.yml",
     dict(archive=None, loopback=True, tailnet=True)),
]

ARCHIVE = VARS["ARCHIVE_ROOT"]

# The bind rule is a SAFETY rule that was widened to admit the tailnet, so it runs its own table on
# every invocation. A widened rule that quietly accepts more than intended is worse than the narrow
# one it replaced — 100.200.x.x is ordinary public address space and sits one careless prefix-match
# away from 100.64.x.x.
BIND_CASES = [
    ("127.0.0.1:3010:3000",     False, True),
    ("127.0.0.1:3010:3000",     True,  True),
    ("100.64.0.1:3010:3000",    True,  True),
    ("100.127.255.9:3010:3000", True,  True),
    ("100.64.0.1:3010:3000",    False, False),   # tailnet address, app not opted in
    ("100.63.0.1:3010:3000",    True,  False),   # just below the range
    ("100.128.0.1:3010:3000",   True,  False),   # just above the range
    ("100.200.1.1:3010:3000",   True,  False),   # public space that starts with 100.
    ("0.0.0.0:3010:3000",       True,  False),
    ("192.168.1.42:3010:3000",  True,  False),
    ("3010:3000",               True,  False),   # bare port = every interface
]


def self_test_bind_rule() -> list:
    out = []
    for spec, tailnet_ok, want in BIND_CASES:
        got = bind_allowed(spec, tailnet_ok)
        if got != want:
            out.append(f"bind rule self-test: bind_allowed({spec!r}, tailnet={tailnet_ok}) "
                       f"returned {got}, expected {want}")
    return out



def bind_allowed(port_spec: str, tailnet_ok: bool) -> bool:
    """Is this `ports:` entry published on an interface this app is allowed to use?

    Loopback always. A Tailscale CGNAT address (100.64.0.0/10) only where the app opts in — and
    matching that range properly matters: a bare "100." prefix would also accept 100.200.x.x, which
    is ordinary public address space, so the widened rule would quietly permit a public bind.
    """
    if port_spec.startswith("127.0.0.1:"):
        return True
    if not tailnet_ok:
        return False
    m = re.match(r"^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}:", port_spec)
    if not m:
        return False
    return m.group(1) == "100" and 64 <= int(m.group(2)) <= 127




def extract_heredoc(script: str, fname: str) -> str:
    """Return the body of `sudo tee "$APP_DIR/<fname>" >/dev/null <<EOF ... EOF` from `script`."""
    text = open(os.path.join(REPO, script), encoding="utf-8").read()
    pat = re.compile(
        r'^sudo tee "\$[A-Z_]*DIR/' + re.escape(fname) + r'" >/dev/null <<EOF$\n(.*?)^EOF$',
        re.MULTILINE | re.DOTALL,
    )
    m = pat.search(text)
    if not m:
        raise AssertionError(f"{script}: could not find the heredoc for {fname}")
    return m.group(1)


def render(body: str) -> str:
    """Reproduce what bash writes for an unquoted `<<EOF` heredoc, safely (no code execution)."""
    if "$(" in body or "`" in body:
        raise AssertionError("command substitution in a compose heredoc — refusing to render")
    # Unquoted heredocs let bash unescape \$ \` \\ ; apply just those, in one pass.
    out, i = [], 0
    while i < len(body):
        if body[i] == "\\" and i + 1 < len(body) and body[i + 1] in "$`\\":
            out.append(body[i + 1])
            i += 2
        else:
            out.append(body[i])
            i += 1
    # safe_substitute fills BUILD-TIME vars and leaves any unmapped ${VAR} untouched.
    return string.Template("".join(out)).safe_substitute(VARS)


def volumes_of(service: dict) -> list[str]:
    vols = service.get("volumes", []) or []
    out = []
    for v in vols:
        if isinstance(v, str):
            out.append(v)
        elif isinstance(v, dict):  # long-form mount
            src = v.get("source", "")
            ro = "ro" if v.get("read_only") else "rw"
            out.append(f"{src}:{v.get('target', '')}:{ro}")
    return out


def ports_of(service: dict) -> list[str]:
    return [str(p) for p in (service.get("ports", []) or [])]


def check_app(script: str, fname: str, exp: dict, fails: list[str]) -> None:
    where = f"{script}:{fname}"
    body = extract_heredoc(script, fname)
    doc = yaml.safe_load(render(body))

    if not isinstance(doc, dict) or not isinstance(doc.get("services"), dict):
        fails.append(f"{where}: no top-level services: mapping")
        return
    services = doc["services"]
    is_override = "override" in fname

    archive_mounts = []
    for name, svc in services.items():
        svc = svc or {}
        if not is_override and "image" not in svc:
            fails.append(f"{where}: service '{name}' has no image:")
        for vol in volumes_of(svc):
            parts = vol.split(":")
            if parts and parts[0] == ARCHIVE:
                archive_mounts.append((name, vol))
        if exp.get("loopback"):
            for p in ports_of(svc):
                if not bind_allowed(p, exp.get("tailnet", False)):
                    allowed = "loopback 127.0.0.1:"
                    if exp.get("tailnet"):
                        allowed += " or a Tailscale address in 100.64.0.0/10"
                    fails.append(f"{where}: service '{name}' publishes {p!r} on a disallowed "
                                 f"interface (expected {allowed})")

    # The safety centerpiece: the archive is never writable through a container.
    if exp.get("archive") == "ro":
        if not archive_mounts:
            fails.append(f"{where}: expected the archive mounted read-only, found no archive mount")
        for name, vol in archive_mounts:
            if vol.split(":")[-1] != "ro":
                fails.append(f"{where}: service '{name}' mounts the archive WRITABLE ({vol!r}) "
                             f"— must end with :ro")
    elif exp.get("archive") is None:
        for name, vol in archive_mounts:
            fails.append(f"{where}: service '{name}' mounts the archive ({vol!r}) but this app "
                         f"must not touch it")

    for needed in exp.get("must_mount", []):
        if not any(vol.split(":")[0].startswith(needed) for svc in services.values()
                   for vol in volumes_of(svc or {})):
            fails.append(f"{where}: expected a bind mount under {needed!r}, none found")

    # Shared-network invariant: if a service joins 'memorial', it must be declared external.
    joins_shared = any(VARS["DOCKER_NET"] in (svc or {}).get("networks", []) or []
                       for svc in services.values())
    if joins_shared:
        top = doc.get("networks", {}) or {}
        net = top.get(VARS["DOCKER_NET"])
        if not (isinstance(net, dict) and net.get("external")):
            fails.append(f"{where}: joins the '{VARS['DOCKER_NET']}' network but it is not declared "
                         f"external at the top level")


def main() -> int:
    fails: list[str] = []

    print("\n== bind rule self-test (loopback always; tailnet only where opted in)")
    bind_fails = self_test_bind_rule()
    if bind_fails:
        fails.extend(bind_fails)
        print(f"  ✗ {len(bind_fails)} of {len(BIND_CASES)} cases wrong")
    else:
        print(f"  ✓ all {len(BIND_CASES)} cases correct "
              f"(0.0.0.0, LAN, and 100.200.x.x all still refused)")

    print("\n== compose render + YAML validation")
    for script, fname, exp in APPS:
        n = len(fails)
        try:
            check_app(script, fname, exp, fails)
        except (AssertionError, yaml.YAMLError) as e:
            fails.append(f"{script}:{fname}: {e}")
        if len(fails) == n:
            print(f"  ✓ {script} ({fname})")
        else:
            print(f"  ✗ {script} ({fname})")
    if fails:
        print("\n  Compose validation FAILED:")
        for f in fails:
            print(f"    - {f}")
        return 1
    print(f"  all {len(APPS)} app compose files valid and safe")
    return 0


if __name__ == "__main__":
    sys.exit(main())
