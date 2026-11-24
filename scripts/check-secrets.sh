#!/usr/bin/env bash
# Scans staged changes, pushed commits, or tracked files for secrets and local-only config.
#
# Usage: scripts/check-secrets.sh [--all | --staged | --push]
#   --all     Audit all tracked files and verify forbidden local files are untracked (default).
#   --staged  Inspect staged filenames and staged blob contents (pre-commit hook).
#   --push    Read git pre-push ref lines from stdin and inspect commits being pushed (pre-push hook).

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to run scripts/check-secrets.sh" >&2
  exit 1
fi

IFS= read -r -d '' PY_SCRIPT <<'PYEOF' || true
import os
import re
import subprocess
import sys
from typing import Optional

FORBIDDEN_EXTENSIONS = (
    ".p8",
    ".p12",
    ".pem",
    ".key",
    ".cer",
    ".mobileprovision",
    ".jks",
    ".keystore",
    ".xcuserstate",
)

ALLOWED_ENV_TEMPLATES = {
    ".env.example",
    ".env.sample",
    ".env.template",
}

PLACEHOLDER_VALUES = {
    "XXXXXXXXXX",
    "YOUR_TEAM_ID",
    "CHANGEME",
    "REPLACE_ME",
    "EXAMPLE",
    "TRUE",
    "FALSE",
    "NONE",
    "NULL",
}

SELF_SCRIPT_PATH = "scripts/check-secrets.sh"

PATTERNS: list[tuple[str, re.Pattern[str], bool]] = [
    ("Private key PEM header", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"), False),
    ("GitHub personal access token", re.compile(r"(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{20,}"), False),
    ("GitHub fine-grained token", re.compile(r"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}"), False),
    ("AWS Access Key ID", re.compile(r"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])"), False),
    ("Slack token", re.compile(r"(?<![A-Za-z0-9_])xox[baprs]-[A-Za-z0-9-]{10,}"), False),
    (
        "Hardcoded Apple Team ID assignment",
        re.compile(r"\b(?:DEVELOPMENT_TEAM|APPLE_TEAM_ID)\s*[:=]\s*['\"]?([A-Z0-9]{10})['\"]?(?![A-Za-z0-9])"),
        True,
    ),
    (
        "Hardcoded APPLE_API_KEY_ID assignment",
        re.compile(r"\bAPPLE_API_KEY_ID\s*[:=]\s*['\"]?([A-Z0-9]{6,})['\"]?(?![A-Za-z0-9])"),
        True,
    ),
    (
        "Hardcoded APPLE_API_ISSUER_ID assignment",
        re.compile(r"\bAPPLE_API_ISSUER_ID\s*[:=]\s*['\"]?([0-9a-fA-F-]{36})['\"]?"),
        False,
    ),
    (
        "Hardcoded APPLE_APP_SPECIFIC_PASSWORD assignment",
        re.compile(r"\bAPPLE_APP_SPECIFIC_PASSWORD\s*[:=]\s*['\"]?([a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4})['\"]?"),
        False,
    ),
    (
        "Hardcoded local macOS home path (/Users/...)",
        re.compile(r"/Users/[A-Za-z0-9._-]+/"),
        False,
    ),
]


def usage(stream=sys.stdout) -> None:
    print(
        "Usage: scripts/check-secrets.sh [--all | --staged | --push]\n"
        "  --all     Audit all tracked files and verify forbidden local files are untracked (default).\n"
        "  --staged  Inspect staged filenames and staged blob contents (pre-commit hook).\n"
        "  --push    Read git pre-push ref lines from stdin and inspect commits being pushed (pre-push hook).",
        file=stream,
    )


def run_git(args: list[str], cwd: Optional[str] = None, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def get_repo_root() -> str:
    res = run_git(["rev-parse", "--show-toplevel"], check=False)
    if res.returncode != 0:
        err = res.stderr.decode("utf-8", errors="replace").strip()
        print(f"error: not inside a git repository ({err})", file=sys.stderr)
        sys.exit(1)
    return res.stdout.decode("utf-8", errors="replace").strip()


def normalize_path(path: str) -> str:
    norm = path.replace("\\", "/")
    while norm.startswith("./"):
        norm = norm[2:]
    return norm


def is_zero_sha(sha: str) -> bool:
    return bool(sha) and set(sha) == {"0"}


def is_placeholder_value(val: str) -> bool:
    if len(val) < 4:
        return True
    upper = val.upper()
    if upper in PLACEHOLDER_VALUES:
        return True
    if re.fullmatch(r"X{4,}", upper):
        return True
    if re.fullmatch(r"0{4,}", val):
        return True
    if val.startswith("<") and val.endswith(">"):
        return True
    return False


def check_forbidden_filename(rel_path: str) -> Optional[str]:
    norm = normalize_path(rel_path)
    parts = [p for p in norm.split("/") if p]
    if not parts:
        return None
    parts_lower = [p.lower() for p in parts]
    base_lower = parts_lower[-1]
    rel_lower = norm.lower()

    if "xcuserdata" in parts_lower:
        return "Xcode user state directory (xcuserdata/)"

    if base_lower == ".env" or base_lower.startswith(".env."):
        if base_lower not in ALLOWED_ENV_TEMPLATES:
            return "local environment file (.env)"

    if rel_lower == "config/localsigning.xcconfig" or base_lower == "localsigning.xcconfig":
        return "local Xcode signing config (Config/LocalSigning.xcconfig)"

    for ext in FORBIDDEN_EXTENSIONS:
        if base_lower.endswith(ext):
            return f"forbidden credential/local file extension (*{ext})"

    return None


def parse_local_config_file(full_path: str, rel_label: str, is_xcconfig: bool) -> list[tuple[str, str, str]]:
    entries: list[tuple[str, str, str]] = []
    if not os.path.isfile(full_path):
        return entries

    try:
        with open(full_path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return entries

    for raw_line in lines:
        line = raw_line.rstrip("\r\n").strip()
        if not line:
            continue
        if line.startswith("#") or (is_xcconfig and line.startswith("//")):
            continue
        if not is_xcconfig and re.match(r"^export\s+", line):
            line = re.sub(r"^export\s+", "", line, count=1).strip()
        if "=" not in line:
            continue

        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if not key or not val:
            continue

        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        else:
            if is_xcconfig and "//" in val:
                val = val.split("//", 1)[0].strip()
            elif not is_xcconfig:
                val = re.split(r"\s+#", val, maxsplit=1)[0].strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                val = val[1:-1]

        val = val.strip()
        if is_placeholder_value(val):
            continue
        entries.append((rel_label, key, val))

        if val.startswith("~/"):
            expanded = os.path.expanduser(val)
            if expanded != val and not is_placeholder_value(expanded):
                entries.append((rel_label, key, expanded))

    return entries


def load_local_secrets(repo_root: str) -> list[tuple[str, str, str]]:
    secrets: list[tuple[str, str, str]] = []
    secrets.extend(parse_local_config_file(os.path.join(repo_root, ".env"), ".env", is_xcconfig=False))
    secrets.extend(
        parse_local_config_file(
            os.path.join(repo_root, "Config", "LocalSigning.xcconfig"),
            "Config/LocalSigning.xcconfig",
            is_xcconfig=True,
        )
    )
    return secrets


def decode_text_bytes(data: bytes) -> Optional[str]:
    if not data:
        return ""
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        return data.decode("utf-16", errors="replace")
    if b"\x00" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace")


def scan_content(
    rel_path: str,
    data: bytes,
    local_secrets: list[tuple[str, str, str]],
    context: str,
    findings: list[str],
) -> None:
    text = decode_text_bytes(data)
    if text is None:
        return

    norm = normalize_path(rel_path)
    lines = text.splitlines()

    reported_secret_keys: set[tuple[str, str]] = set()
    for source_label, key, secret_val in local_secrets:
        if (source_label, key) in reported_secret_keys:
            continue
        if secret_val in text:
            line_no = 1
            for idx, line in enumerate(lines, start=1):
                if secret_val in line:
                    line_no = idx
                    break
            reported_secret_keys.add((source_label, key))
            findings.append(
                f"[BLOCKED] {context}{norm}:{line_no}: contains exact value of {key} from local {source_label}"
            )

    if norm == SELF_SCRIPT_PATH:
        return

    for idx, line in enumerate(lines, start=1):
        for rule_name, pattern, check_placeholder in PATTERNS:
            matched = False
            for match in pattern.finditer(line):
                if check_placeholder and match.lastindex:
                    if is_placeholder_value(match.group(1)):
                        continue
                matched = True
                break
            if matched:
                findings.append(
                    f"[BLOCKED] {context}{norm}:{idx}: matches forbidden secret/local-config pattern ({rule_name})"
                )


def is_staged_gitlink(repo_root: str, rel_path: str) -> bool:
    res = run_git(["ls-files", "--stage", "-z", "--", rel_path], cwd=repo_root, check=False)
    if res.returncode != 0 or not res.stdout:
        return False
    first = res.stdout.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
    return first.startswith("160000 ")


def scan_staged(repo_root: str, local_secrets: list[tuple[str, str, str]]) -> tuple[list[str], int]:
    findings: list[str] = []
    res = run_git(["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], cwd=repo_root)
    raw_paths = [p.decode("utf-8", errors="surrogateescape") for p in res.stdout.split(b"\x00") if p]

    for rel_path in raw_paths:
        norm = normalize_path(rel_path)
        forbidden_reason = check_forbidden_filename(norm)
        if forbidden_reason:
            findings.append(f"[BLOCKED] {norm}: {forbidden_reason}")

        if is_staged_gitlink(repo_root, rel_path):
            continue

        blob_res = run_git(["show", f":{rel_path}"], cwd=repo_root, check=False)
        if blob_res.returncode != 0:
            findings.append(f"[BLOCKED] {norm}: unable to read staged blob for secret scanning")
            continue

        scan_content(norm, blob_res.stdout, local_secrets, context="", findings=findings)

    return findings, len(raw_paths)


def commit_exists(repo_root: str, sha: str) -> bool:
    res = run_git(["cat-file", "-e", f"{sha}^{{commit}}"], cwd=repo_root, check=False)
    return res.returncode == 0


def scan_push(repo_root: str, local_secrets: list[tuple[str, str, str]]) -> tuple[list[str], int]:
    findings: list[str] = []
    commits: list[str] = []
    seen_commits: set[str] = set()

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        _local_ref, local_sha, _remote_ref, remote_sha = parts[:4]
        if is_zero_sha(local_sha):
            continue

        if is_zero_sha(remote_sha) or not commit_exists(repo_root, remote_sha):
            rev_args = ["rev-list", local_sha, "--not", "--remotes"]
        else:
            rev_args = ["rev-list", f"{remote_sha}..{local_sha}"]

        rev_res = run_git(rev_args, cwd=repo_root)
        for sha in rev_res.stdout.decode("utf-8", errors="replace").splitlines():
            sha = sha.strip()
            if sha and sha not in seen_commits:
                seen_commits.add(sha)
                commits.append(sha)

    seen_blobs: set[tuple[str, str]] = set()
    for commit_sha in commits:
        short_sha = commit_sha[:10]
        context = f"commit {short_sha} "
        diff_res = run_git(
            [
                "diff-tree",
                "--no-commit-id",
                "-r",
                "--root",
                "-m",
                "--no-renames",
                "--raw",
                "--diff-filter=ACMRT",
                "-z",
                commit_sha,
            ],
            cwd=repo_root,
        )
        tokens = diff_res.stdout.split(b"\x00")
        checked_paths_in_commit: set[str] = set()
        idx = 0
        while idx + 1 < len(tokens):
            meta_bytes = tokens[idx]
            path_bytes = tokens[idx + 1]
            idx += 2
            if not meta_bytes or not path_bytes:
                continue
            meta = meta_bytes.decode("utf-8", errors="replace")
            if not meta.startswith(":"):
                continue
            meta_fields = meta[1:].split()
            if len(meta_fields) < 5:
                continue
            _old_mode, new_mode, _old_sha, new_sha, _status = meta_fields[:5]
            rel_path = normalize_path(path_bytes.decode("utf-8", errors="surrogateescape"))

            if rel_path not in checked_paths_in_commit:
                checked_paths_in_commit.add(rel_path)
                forbidden_reason = check_forbidden_filename(rel_path)
                if forbidden_reason:
                    findings.append(f"[BLOCKED] {context}{rel_path}: {forbidden_reason}")

            if new_mode == "160000" or is_zero_sha(new_sha):
                continue

            blob_key = (new_sha, rel_path)
            if blob_key in seen_blobs:
                continue
            seen_blobs.add(blob_key)

            blob_res = run_git(["cat-file", "blob", new_sha], cwd=repo_root, check=False)
            if blob_res.returncode != 0:
                findings.append(f"[BLOCKED] {context}{rel_path}: unable to read commit blob for secret scanning")
                continue

            scan_content(rel_path, blob_res.stdout, local_secrets, context=context, findings=findings)

    return findings, len(commits)


def scan_all(repo_root: str, local_secrets: list[tuple[str, str, str]]) -> tuple[list[str], int]:
    findings: list[str] = []
    res = run_git(["ls-files", "-z"], cwd=repo_root)
    raw_paths = [p.decode("utf-8", errors="surrogateescape") for p in res.stdout.split(b"\x00") if p]

    for rel_path in raw_paths:
        norm = normalize_path(rel_path)
        forbidden_reason = check_forbidden_filename(norm)
        if forbidden_reason:
            findings.append(f"[BLOCKED] {norm}: {forbidden_reason}")

        full_path = os.path.join(repo_root, rel_path)
        if os.path.islink(full_path):
            try:
                data = os.readlink(full_path).encode("utf-8", errors="surrogateescape")
            except OSError:
                continue
        elif os.path.isfile(full_path):
            try:
                with open(full_path, "rb") as handle:
                    data = handle.read()
            except OSError:
                findings.append(f"[BLOCKED] {norm}: unable to read tracked file for secret scanning")
                continue
        elif os.path.isdir(full_path):
            continue
        else:
            blob_res = run_git(["show", f":{rel_path}"], cwd=repo_root, check=False)
            if blob_res.returncode != 0:
                continue
            data = blob_res.stdout

        scan_content(norm, data, local_secrets, context="", findings=findings)

    return findings, len(raw_paths)


def main(argv: list[str]) -> int:
    mode = "--all"
    if len(argv) == 1:
        if argv[0] in ("-h", "--help"):
            usage(sys.stdout)
            return 0
        if argv[0] in ("--all", "--staged", "--push"):
            mode = argv[0]
        else:
            print(f"error: unknown argument '{argv[0]}'", file=sys.stderr)
            usage(sys.stderr)
            return 2
    elif len(argv) > 1:
        print("error: expected at most one mode flag (--all, --staged, or --push)", file=sys.stderr)
        usage(sys.stderr)
        return 2

    repo_root = get_repo_root()
    local_secrets = load_local_secrets(repo_root)

    if mode == "--staged":
        findings, count = scan_staged(repo_root, local_secrets)
        label = f"{count} staged file(s)"
    elif mode == "--push":
        findings, count = scan_push(repo_root, local_secrets)
        label = f"{count} commit(s) to push"
    else:
        findings, count = scan_all(repo_root, local_secrets)
        label = f"{count} tracked file(s)"

    if findings:
        print(f"Secret & local-config check FAILED ({len(findings)} issue(s) across {label}):", file=sys.stderr)
        for item in findings:
            print(f"  {item}", file=sys.stderr)
        print(
            "Commit/push blocked. Remove sensitive files or values (use untracked .env or Config/LocalSigning.xcconfig).",
            file=sys.stderr,
        )
        return 1

    print(f"Secret & local-config check passed ({label}).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF

exec python3 -c "$PY_SCRIPT" "$@"
