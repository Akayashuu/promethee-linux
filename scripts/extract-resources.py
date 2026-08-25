#!/usr/bin/env python3
"""Extract Promethee's resources/ tree from a Squirrel .nupkg.

    extract-resources.py <package.nupkg> <dest>

A .nupkg is a zip. Everything the Linux build needs (app.asar, the natives
beside it, the assets) lives under lib/net45/resources/; the rest is Windows
binaries. Only that subtree is written, with the prefix stripped, so <dest>
ends up shaped exactly like an installed resources/ directory.
"""

import shutil
import sys
import zipfile
from pathlib import Path

PREFIX = "lib/net45/resources/"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    package, dest = Path(sys.argv[1]), Path(sys.argv[2]).resolve()

    with zipfile.ZipFile(package) as archive:
        members = [
            info
            for info in archive.infolist()
            if info.filename.startswith(PREFIX) and not info.is_dir()
        ]
        if not members:
            print(f"no {PREFIX} in {package.name}: upstream layout changed", file=sys.stderr)
            return 1

        for info in members:
            target = (dest / info.filename[len(PREFIX):]).resolve()
            # Archive members name their own destination, so confirm each one
            # stays inside dest before anything is written.
            if not target.is_relative_to(dest):
                print(f"refusing path outside dest: {info.filename}", file=sys.stderr)
                return 1

            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)

    print(f"extracted {len(members)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
