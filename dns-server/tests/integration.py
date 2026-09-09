"""Optional real-binary check: python3 integration.py /path/to/AdGuardHome.

Starts only a temporary loopback instance on high ports; never installs a service.
Requires PyYAML and Internet access for AdGuard's initial filter downloads.
"""
import importlib.util
import json
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location("adguard", Path(__file__).parents[1] / "scripts" / "adguard.py")
adguard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adguard)


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def main(binary):
    web_port, dns_port = free_port(), free_port()
    # Avoid Windows-specific production ACL migration in a disposable test tree.
    permission_options = ["--no-permcheck"] if sys.platform == "win32" else []
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with tempfile.TemporaryDirectory(prefix="adguard-integration-") as directory:
        root = Path(directory)
        executable = root / Path(binary).name
        shutil.copy2(binary, executable)
        config = root / "AdGuardHome.yaml"
        address = f"127.0.0.1:{web_port}"
        with (root / "process.log").open("w") as log:
            process = subprocess.Popen(
                [str(executable), "-c", str(config), "-w", str(root), "--web-addr", address] + permission_options,
                stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            try:
                url = f"http://{address}/control/install/"
                for _ in range(60):
                    if process.poll() is not None:
                        raise RuntimeError((root / "process.log").read_text())
                    try:
                        with client.open(url + "get_addresses", timeout=2) as response:
                            json.load(response)
                        break
                    except (urllib.error.URLError, TimeoutError):
                        time.sleep(0.5)
                else:
                    raise RuntimeError("Setup API did not become ready")
                payload = {"web": {"ip": "127.0.0.1", "port": web_port},
                           "dns": {"ip": "127.0.0.1", "port": dns_port},
                           "username": "admin", "password": secrets.token_hex(20)}
                request = urllib.request.Request(
                    url + "configure", data=json.dumps(payload).encode(),
                    headers={"Content-Type": "application/json"}, method="POST",
                )
                try:
                    with client.open(request, timeout=120) as response:
                        response.read()
                except urllib.error.HTTPError as error:
                    raise RuntimeError(error.read().decode(errors="replace")) from error
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        before = adguard.read_config(root)
        adguard.configure(root, "192.168.50.2", '["https://dns.quad9.net/dns-query"]',
                          '["9.9.9.9", "149.112.112.112"]', "192.168.50.0/24")
        after = adguard.read_config(root)
        assert before["users"] == after["users"], "Admin credentials changed"
        assert before["filters"] == after["filters"], "Filter lists changed"
        subprocess.run([str(executable), "--check-config", "-c", str(config), "-w", str(root)] + permission_options, check=True)
        first = config.read_bytes()
        adguard.configure(root, "192.168.50.2", '["https://dns.quad9.net/dns-query"]',
                          '["9.9.9.9", "149.112.112.112"]', "192.168.50.0/24")
        assert first == config.read_bytes(), "Repeated setup changed the configuration"
        print("PASS: real first-install API, official YAML schema, CLI validation and idempotence.")


if __name__ == "__main__":
    main(sys.argv[1])
