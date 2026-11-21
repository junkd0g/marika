"""Install the checksum-pinned upstream agent into the Store bundle at build time."""
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile

VERSION = "0.171.0"
PACKAGES = {
    "arm64": ("aarch64", "58c88032ec446e72922d911d8f03773102da20c16a6059cf21f6744bce57f210"),
    "x86_64": ("x86_64", "dd130ea3217b4e6fe4454c99949e0b28e2e8a9ad8da8c3a75f0c7265fab7153b"),
}


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main(app):
    arch = subprocess.check_output(["lipo", "-archs", app / "Contents/MacOS/Marika"], text=True).strip()
    target, expected = PACKAGES[arch]
    archive = Path(".tools/codex-store") / (arch + ".tar.gz")
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists() or checksum(archive) != expected:
        url = f"https://github.com/openai/codex/releases/download/rust-v{VERSION}/codex-package-{target}-apple-darwin.tar.gz"
        temporary = archive.with_suffix(".download")
        subprocess.run(["curl", "-fLsS", "--retry", "2", url, "-o", temporary], check=True)
        if checksum(temporary) != expected:
            raise ValueError("Codex archive checksum mismatch")
        temporary.replace(archive)
    dest = app / "Contents/Helpers/Codex.app/Contents"
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="app.marika.codex",
        CFBundleExecutable="codex", CFBundleName="Codex", CFBundlePackageType="APPL", CFBundleVersion=VERSION,
        CFBundleShortVersionString=VERSION, LSBackgroundOnly=True)))
    with tarfile.open(archive) as contents:
        for name in ["bin/codex", "bin/codex-exec-server", "bin/codex-code-mode-host", "codex-path/rg"]:
            path = dest / "MacOS" / Path(name).name
            path.parent.mkdir(parents=True, exist_ok=True)
            with contents.extractfile(name) as source, path.open("wb") as output:
                shutil.copyfileobj(source, output)
            path.chmod(0o755)
    for name in ["CodexLicense.txt", "CodexNotice.txt"]:
        shutil.copyfile(Path("Resources") / name, app / "Contents/Resources" / name)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
