#!/usr/bin/env python3
"""Regenerates SkillsBuddy/Resources/Agents.json from the `skills` CLI's docs/agents.md.

Usage:
    npm pack skills && tar xzf skills-*.tgz
    python3 scripts/generate-agent-registry.py package/docs/agents.md

Each row of the supported-agents table maps one or more display names to the
same number of `--agent` keys and a shared global skills folder.
"""

import json
import pathlib
import re
import sys

OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "SkillsBuddy" / "Resources" / "Agents.json"

# The site whose icon is the agent's logo. The CLI doesn't record one, so this
# is kept by hand; an agent without an entry shows its initials.
HOMEPAGES = {
    "antigravity": "antigravity.google",
    "antigravity-cli": "antigravity.google",
    "augment": "augmentcode.com",
    "claude-code": "claude.ai",
    "codex": "openai.com",
    "cursor": "cursor.com",
    "devin": "devin.ai",
    "gemini-cli": "gemini.google.com",
    "hermes-agent": "nousresearch.com",
    "junie": "jetbrains.com",
    "kilo": "kilocode.ai",
    "kimi-code-cli": "kimi.com",
    "kiro-cli": "kiro.dev",
    "opencode": "opencode.ai",
    "warp": "warp.dev",
    "zed": "zed.dev",
    "zencoder": "zencoder.ai",
}


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: generate-agent-registry.py <path to agents.md>")
    text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    table = text.split("<!-- supported-agents:start -->", 1)[1].split("<!-- supported-agents:end -->", 1)[0]

    agents = []
    for line in table.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 4 or cells[0] in ("Agent", "") or set(cells[0]) <= {"-"}:
            continue
        names = [name.strip() for name in cells[0].split(",")]
        keys = re.findall(r"`([^`]+)`", cells[1])
        global_paths = re.findall(r"`([^`]+)`", cells[3])
        if len(names) != len(keys):
            print(f"skipping row with {len(names)} names and {len(keys)} keys: {line}", file=sys.stderr)
            continue
        global_path = global_paths[0] if global_paths else None
        for name, key in zip(names, keys):
            agents.append({"key": key, "displayName": name, "globalSkillsPath": global_path, "homepage": HOMEPAGES.get(key)})

    unknown = set(HOMEPAGES) - {agent["key"] for agent in agents}
    if unknown:
        print(f"homepages for keys the CLI no longer lists: {sorted(unknown)}", file=sys.stderr)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(sorted(agents, key=lambda agent: agent["displayName"].lower()), indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(agents)} agents to {OUTPUT}")


if __name__ == "__main__":
    main()
