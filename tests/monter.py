#!/usr/bin/env python3
"""Prépare une copie d'essai d'un statusline.sh.

- Sur macOS : insère le shim GNU et le shebang bash 5, comme bin/platforms/macos.mjs.
- Option --racine : redirige les chemins système du mode serveur (/etc/claude-statusline.conf,
  /proc, /sys, /var) vers une fausse racine, pour essayer la ligne serveur sans toucher au
  script livré.

Usage : monter.py <dépôt> <source.sh> <destination.sh> [--racine <dossier>]
"""
import pathlib
import sys

repo, src_path, dst_path = (pathlib.Path(p) for p in sys.argv[1:4])
root = sys.argv[5] if len(sys.argv) > 5 and sys.argv[4] == "--racine" else None

import os
import platform

src = src_path.read_text()
out = src
if platform.system() == "Darwin":
    shim = (repo / "bin/shims/macos.sh").read_text()
    marker = "set -euo pipefail\n"
    assert src.count(marker) == 1, "ancre « set -euo pipefail » absente ou en double"
    i = src.index(marker) + len(marker)
    out = src[:i] + "\n" + shim + "\n" + src[i:]
    bash5 = next((b for b in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash") if os.path.exists(b)), "/bin/bash")
    out = f"#!{bash5}\n" + out.split("\n", 1)[1]

if root:
    for name, path in (
        ("P_CONF", "/etc/claude-statusline.conf"),
        ("P_PROC", "/proc"),
    ):
        line = f"{name}={path}\n"
        if out.count(line) != 1:  # la version de référence (base) n'a pas de mode serveur
            continue
        out = out.replace(line, f"{name}={root}{path}\n")

dst_path.write_text(out)
dst_path.chmod(0o755)
print(f"{dst_path.name} : {len(out.splitlines())} lignes")
