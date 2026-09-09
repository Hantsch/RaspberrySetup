#!/usr/bin/env python3
"""Local, root-only AdGuard bootstrap, YAML editing, health and ZIP backup helpers."""
import datetime
import getpass
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request
import warnings
import zipfile

import yaml


def read_config(root):
    with (root / "AdGuardHome.yaml").open(encoding="utf-8") as stream:
        config = yaml.safe_load(stream)
    if not isinstance(config, dict) or not config.get("users"):
        raise ValueError("Configuration has no admin account; refusing an unauthenticated installation.")
    for key in ("http", "dns", "filtering"):
        if not isinstance(config.get(key), dict):
            raise ValueError(f"Missing {key} section; unsupported/incomplete configuration.")
    return config


def write_config(root, config):
    candidate = root / "AdGuardHome.yaml.new"
    with candidate.open("w", encoding="utf-8", newline="\n") as stream:
        os.chmod(candidate, 0o600)
        yaml.safe_dump(config, stream, sort_keys=False)
    os.replace(candidate, root / "AdGuardHome.yaml")


def initialize(root, ipv4):
    if (root / "AdGuardHome.yaml").exists():
        raise ValueError("Refusing to repeat first-run initialization over an existing configuration.")
    warnings.simplefilter("error", getpass.GetPassWarning)
    print("Create AdGuard Home login: admin", flush=True)
    password = getpass.getpass("New admin password (12-72 UTF-8 bytes): ")
    if not 12 <= len(password.encode("utf-8")) <= 72:
        raise ValueError("Use a password between 12 and 72 UTF-8 bytes.")
    if password != getpass.getpass("Confirm password: "):
        raise ValueError("Passwords do not match.")
    # Bypass proxy environment variables for the local first-install API.
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = "http://127.0.0.1:3000/control/install/"
    with (root / "bootstrap.log").open("w", encoding="utf-8") as log:
        os.chmod(root / "bootstrap.log", 0o600)
        process = subprocess.Popen(
            [str(root / "AdGuardHome"), "-c", str(root / "AdGuardHome.yaml"),
             "-w", str(root), "--web-addr", "127.0.0.1:3000"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        )
        try:
            for _ in range(60):
                if process.poll() is not None:
                    raise RuntimeError("Bootstrap exited; inspect /opt/AdGuardHome/bootstrap.log.")
                try:
                    with client.open(base + "get_addresses", timeout=2) as response:
                        json.load(response)
                    break
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(0.5)
            else:
                raise RuntimeError("First-install API did not become ready.")
            payload = {
                "web": {"ip": "127.0.0.1", "port": 3000},
                "dns": {"ip": ipv4, "port": 53},
                "username": "admin", "password": password,
            }
            request = urllib.request.Request(
                base + "configure", data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"}, method="POST",
            )
            with client.open(request, timeout=120) as response:
                response.read()
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    config = read_config(root)
    # Preserve the official defaults; ensure the initial setup has an enabled list.
    if not any(item.get("enabled") for item in config.get("filters", [])):
        config["filters"] = [{
            "enabled": True, "id": 1, "name": "AdGuard DNS filter",
            "url": "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt",
        }]
    config["filtering"]["protection_enabled"] = True
    config["filtering"]["filtering_enabled"] = True
    config["filtering"]["filters_update_interval"] = 24
    write_config(root, config)


def configure(root, ipv4, upstreams, bootstrap, subnet):
    config = read_config(root)
    config["http"]["address"] = "127.0.0.1:3000"
    config["dns"].update({
        "bind_hosts": ["127.0.0.1", ipv4], "port": 53,
        "upstream_dns": json.loads(upstreams), "upstream_dns_file": "",
        "bootstrap_dns": json.loads(bootstrap), "fallback_dns": [],
        "allowed_clients": ["127.0.0.1", subnet],
    })
    # TP-Link provides DHCP; DHCP cannot accidentally be activated by a rerun.
    config.setdefault("dhcp", {})["enabled"] = False
    write_config(root, config)


def health(root):
    config = read_config(root)
    filtering = config["filtering"]
    if not filtering.get("protection_enabled") or not filtering.get("filtering_enabled"):
        raise ValueError("DNS filtering/protection is disabled in the saved configuration.")
    until = filtering.get("protection_disabled_until")
    if until and not str(until).startswith("0001-"):
        expiry = datetime.datetime.fromisoformat(str(until).replace("Z", "+00:00"))
        if expiry.replace(tzinfo=expiry.tzinfo or datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc):
            raise ValueError("Protection is temporarily disabled.")
    enabled = [item for item in config.get("filters", []) if item.get("enabled")]
    cached = [root / "data" / "filters" / f"{int(item['id'])}.txt" for item in enabled]
    if not any(path.is_file() and path.stat().st_size > 0 for path in cached):
        raise ValueError("No enabled filter has a downloaded cache yet; check Filters in the web UI and rerun Status.")
    print(f"OK: saved filtering settings enabled; {len(enabled)} enabled source(s), filter cache present.")


def backup(root, destination):
    # Caller stops the service for a consistent configuration/data snapshot.
    read_config(root)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root)
            # Avoid nesting the automatic updater's historical backups.
            if relative.parts[0] == "backup":
                continue
            if path.is_symlink():
                raise ValueError(f"External/symlink data needs a manual backup: {relative}")
            archive.write(path, str(Path("AdGuardHome") / relative))
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise ValueError("Backup ZIP integrity check failed.")
        for member in ("AdGuardHome/AdGuardHome", "AdGuardHome/AdGuardHome.yaml"):
            if archive.getinfo(member).file_size == 0:
                raise ValueError(f"Empty required backup member: {member}")


if __name__ == "__main__":
    try:
        operation, directory, *arguments = sys.argv[1:]
        functions = {"initialize": initialize, "configure": configure, "health": health, "backup": backup}
        functions[operation](Path(directory), *arguments)
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
