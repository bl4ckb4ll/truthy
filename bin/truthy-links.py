#!/usr/bin/env python3
"""Extract a stable, sorted list of candidate links from one frozen HTML body."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urldefrag, urljoin, urlparse


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() not in {"a", "area", "link"}:
            return
        for key, value in attrs:
            if key.lower() == "href" and value:
                self.links.append(value)
                return


def clean_tsv(s: str) -> str:
    return s.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("body", type=Path)
    p.add_argument("base_url")
    p.add_argument("--same-origin", action="store_true")
    p.add_argument("--max", type=int, default=0, help="0 means no output limit")
    p.add_argument("--run", type=Path, help="Truthy run directory to append trace edges")
    p.add_argument("--artifact-hash", help="hash corresponding to BODY when --run is used")
    args = p.parse_args()

    if (args.run is None) != (args.artifact_hash is None):
        p.error("--run and --artifact-hash must be supplied together")

    artifact_hash = None
    if args.artifact_hash is not None:
        artifact_hash = args.artifact_hash.lower()
        if not re.fullmatch(r"[0-9a-f]{64}", artifact_hash):
            p.error("--artifact-hash must be a 64-digit SHA-256 digest")

    body = args.body.read_bytes()
    if artifact_hash is not None and hashlib.sha256(body).hexdigest() != artifact_hash:
        p.error("input BODY does not match --artifact-hash")

    parser = LinkParser()
    html = body.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "\n")
    parser.feed(html)

    base = urlparse(args.base_url)
    out: set[str] = set()
    for raw in parser.links:
        absolute, _fragment = urldefrag(urljoin(args.base_url, raw.strip()))
        parsed = urlparse(absolute)
        if parsed.scheme not in {"http", "https"}:
            continue
        if args.same_origin and (parsed.scheme, parsed.netloc) != (base.scheme, base.netloc):
            continue
        out.add(absolute)

    links = sorted(out)
    if args.max > 0:
        links = links[: args.max]

    if artifact_hash is not None:
        import fcntl

        edges = args.run / "edges.tsv"
        trace = args.run / "trace.tsv"
        if not edges.is_file() or not trace.is_file():
            p.error(f"not a Truthy run: {args.run}")
        canonical = args.run / "artifacts" / "sha256" / artifact_hash / "body"
        lock_fd = os.open(args.run / ".capture.lock", os.O_CREAT | os.O_WRONLY, 0o600)
        with os.fdopen(lock_fd, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if (
                canonical.is_symlink()
                or canonical.parent.is_symlink()
                or not canonical.is_file()
            ):
                p.error(f"stored artifact body is missing or invalid: {canonical}")
            digest = hashlib.sha256()
            try:
                with canonical.open("rb") as source:
                    for chunk in iter(lambda: source.read(64 * 1024), b""):
                        digest.update(chunk)
            except OSError as error:
                p.error(f"cannot read stored artifact body: {error}")
            if digest.hexdigest() != artifact_hash:
                p.error(f"stored artifact body does not match SHA-256: {canonical}")

            with edges.open("a", encoding="utf-8") as edge_file, trace.open("a", encoding="utf-8") as trace_file:
                for link in links:
                    edge_file.write(
                        f"artifact\t{artifact_hash}\tlinks-to\turl\t{clean_tsv(link)}\t\n"
                    )
                utc = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                trace_file.write(
                    f"{utc}\tlinks\t{artifact_hash}\t"
                    f"count={len(links)} base={clean_tsv(args.base_url)}\n"
                )

    for link in links:
        print(link)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
