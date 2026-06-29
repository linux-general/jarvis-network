#!/usr/bin/env python3
"""seed-models.py — mirror HuggingFace model repos into Vultr Object Storage.

Reads models/manifest.yaml, downloads each model with huggingface_hub, and
uploads to s3://jarvis-models/<prefix>/. Writes a per-model _manifest.json
recording file → sha256 so containers can verify their pulls.

Usage:
    # Mirror every model with status: current
    ./scripts/seed-models.py --all

    # Mirror one (or several) by id
    ./scripts/seed-models.py --only qwen3-32b-awq
    ./scripts/seed-models.py --only kokoro-82m --only pyannote-speaker-diarization-3.1

    # Verify bucket contents against manifest (no upload)
    ./scripts/seed-models.py --verify --only qwen3-32b-awq

    # Generate a 1h presigned URL for a single file in the bucket
    ./scripts/seed-models.py --signed-url llm/qwen3-32b-awq/config.json

    # Pull a model FROM the bucket to a local path (containers use this)
    ./scripts/seed-models.py --pull qwen3-32b-awq --dest /opt/models/qwen3-32b-awq

Environment:
    VULTR_OS_HOSTNAME, VULTR_OS_ACCESS_KEY, VULTR_OS_SECRET_KEY
        From scripts/provision-vultr-os.sh output. Or source the credentials
        file: `source ~/.config/jarvis/vultr-os-credentials.env`.
    HF_TOKEN
        Required for gated repos (pyannote/*, some Llama variants). Generate
        at https://huggingface.co/settings/tokens — read-only is fine.

Where to run this:
    The seed phase belongs on a Vultr ATL VM (gigabit to OS). The --pull and
    --signed-url phases are fine anywhere.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

# ── self-bootstrap deps in a venv if missing ─────────────────────────────────
def _bootstrap():
    try:
        import boto3, yaml, huggingface_hub, tqdm  # noqa: F401
        return
    except ImportError:
        pass
    venv = Path.home() / ".venvs" / "jarvis-os"
    py = venv / "bin" / "python3"
    if not py.exists():
        import venv as _venv
        print(f"→ Creating venv at {venv}", file=sys.stderr)
        _venv.EnvBuilder(with_pip=True).create(venv)
    import subprocess
    subprocess.check_call(
        [str(py), "-m", "pip", "install", "--quiet",
         "boto3", "pyyaml", "huggingface_hub[hf_transfer]", "tqdm"]
    )
    os.execv(str(py), [str(py), *sys.argv])

_bootstrap()

import boto3  # noqa: E402
import yaml   # noqa: E402
from botocore.exceptions import ClientError  # noqa: E402
from huggingface_hub import snapshot_download  # noqa: E402
from tqdm import tqdm  # noqa: E402

# Speed up HF downloads
os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "models" / "manifest.yaml"
BUCKET = "jarvis-models"


def load_manifest() -> dict:
    with open(MANIFEST_PATH) as f:
        return yaml.safe_load(f)


def s3_client():
    host = os.environ.get("VULTR_OS_HOSTNAME")
    key = os.environ.get("VULTR_OS_ACCESS_KEY")
    secret = os.environ.get("VULTR_OS_SECRET_KEY")
    if not (host and key and secret):
        sys.exit(
            "ERROR: VULTR_OS_HOSTNAME/ACCESS_KEY/SECRET_KEY not set. "
            "`source ~/.config/jarvis/vultr-os-credentials.env` first."
        )
    return boto3.client(
        "s3",
        endpoint_url=f"https://{host}",
        aws_access_key_id=key,
        aws_secret_access_key=secret,
        region_name="atl",
    )


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def select_models(manifest: dict, args) -> list[dict]:
    models = manifest["models"]
    if args.only:
        wanted = set(args.only)
        chosen = [m for m in models if m["id"] in wanted]
        missing = wanted - {m["id"] for m in chosen}
        if missing:
            sys.exit(f"Unknown model id(s): {sorted(missing)}")
        return chosen
    if args.all:
        return [m for m in models if m.get("status") == "current"]
    sys.exit("Specify --all or --only <id> [--only <id> …]")


# ── push (HF → bucket) ───────────────────────────────────────────────────────
def push_model(s3, model: dict, dry_run: bool):
    mid = model["id"]
    prefix = model["prefix"].rstrip("/")
    hf_repo = model["hf_repo"]
    print(f"\n→ {mid}  ({hf_repo} → s3://{BUCKET}/{prefix}/)")

    staging = Path("/tmp/jarvis-seed") / mid
    staging.mkdir(parents=True, exist_ok=True)
    token = os.environ.get("HF_TOKEN")
    snapshot_download(
        repo_id=hf_repo,
        local_dir=str(staging),
        local_dir_use_symlinks=False,
        token=token,
    )

    file_hashes: dict[str, str] = {}
    files = [p for p in staging.rglob("*") if p.is_file() and ".cache" not in p.parts]
    for f in tqdm(files, desc=f"  upload {mid}", unit="file"):
        rel = f.relative_to(staging).as_posix()
        key = f"{prefix}/{rel}"
        h = sha256_file(f)
        file_hashes[rel] = h
        if dry_run:
            continue
        s3.upload_file(str(f), BUCKET, key)

    # write per-model checksum manifest
    manifest_blob = json.dumps(
        {"id": mid, "hf_repo": hf_repo, "files": file_hashes},
        indent=2,
        sort_keys=True,
    ).encode()
    if not dry_run:
        s3.put_object(Bucket=BUCKET, Key=f"{prefix}/_manifest.json", Body=manifest_blob)
    print(f"  ✓ {len(file_hashes)} files, manifest written")


# ── verify ───────────────────────────────────────────────────────────────────
def verify_model(s3, model: dict):
    mid = model["id"]
    prefix = model["prefix"].rstrip("/")
    print(f"\n→ verify {mid}  (s3://{BUCKET}/{prefix}/)")
    try:
        body = s3.get_object(Bucket=BUCKET, Key=f"{prefix}/_manifest.json")["Body"].read()
    except ClientError:
        print(f"  ✗ no _manifest.json — model not seeded")
        return False
    meta = json.loads(body)
    ok = True
    for rel in meta["files"]:
        key = f"{prefix}/{rel}"
        try:
            s3.head_object(Bucket=BUCKET, Key=key)
        except ClientError:
            print(f"  ✗ missing: {key}")
            ok = False
    print(f"  ✓ all {len(meta['files'])} files present" if ok else f"  ✗ verify FAILED")
    return ok


# ── pull (bucket → local) ────────────────────────────────────────────────────
def pull_model(s3, model: dict, dest: Path):
    mid = model["id"]
    prefix = model["prefix"].rstrip("/")
    dest.mkdir(parents=True, exist_ok=True)
    body = s3.get_object(Bucket=BUCKET, Key=f"{prefix}/_manifest.json")["Body"].read()
    meta = json.loads(body)
    print(f"→ pull {mid} → {dest}")
    for rel, expected_sha in tqdm(meta["files"].items(), desc=f"  download {mid}"):
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        s3.download_file(BUCKET, f"{prefix}/{rel}", str(out))
        got = sha256_file(out)
        if got != expected_sha:
            sys.exit(f"  ✗ sha256 mismatch on {rel}: got {got} want {expected_sha}")
    print(f"  ✓ {len(meta['files'])} files, all sha256-verified")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true", help="mirror all status:current models")
    ap.add_argument("--only", action="append", default=[], help="mirror by id (repeatable)")
    ap.add_argument("--verify", action="store_true", help="check bucket vs manifest, no upload")
    ap.add_argument("--pull", metavar="ID", help="pull a model from bucket to --dest")
    ap.add_argument("--dest", type=Path, help="destination directory for --pull")
    ap.add_argument("--signed-url", metavar="KEY", help="emit a 1h presigned GET URL for an object")
    ap.add_argument("--dry-run", action="store_true", help="skip uploads, just compute hashes")
    args = ap.parse_args()

    s3 = s3_client()

    if args.signed_url:
        url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": BUCKET, "Key": args.signed_url},
            ExpiresIn=3600,
        )
        print(url)
        return

    manifest = load_manifest()

    if args.pull:
        models = [m for m in manifest["models"] if m["id"] == args.pull]
        if not models:
            sys.exit(f"Unknown model id: {args.pull}")
        if not args.dest:
            sys.exit("--pull requires --dest /path/to/dir")
        pull_model(s3, models[0], args.dest)
        return

    chosen = select_models(manifest, args)
    if args.verify:
        results = [verify_model(s3, m) for m in chosen]
        sys.exit(0 if all(results) else 1)

    for m in chosen:
        push_model(s3, m, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
