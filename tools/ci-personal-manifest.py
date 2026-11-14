import glob
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess


def find_apksigner() -> str | None:
    candidates = []
    for env_key in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        root = os.environ.get(env_key)
        if root:
            candidates.extend(glob.glob(f"{root}/build-tools/*/apksigner"))
    candidates.sort()
    return candidates[-1] if candidates else None


def extract_cert_sha256(apk_path: pathlib.Path) -> str:
    apksigner = find_apksigner()
    if apksigner:
        out = subprocess.check_output(
            [apksigner, "verify", "--print-certs", str(apk_path)],
            text=True,
        )
        m = re.search(r"SHA-256 digest:\s*([0-9a-fA-F]{64})", out)
        if m:
            return m.group(1).lower()
    out = subprocess.check_output(
        ["keytool", "-printcert", "-jarfile", str(apk_path)],
        text=True,
    )
    m2 = re.search(r"SHA256:\s*([0-9A-Fa-f:]{95})", out)
    if m2:
        return m2.group(1).replace(":", "").lower()
    raise SystemExit(f"Could not extract SHA-256 certificate digest from:\n{out}")


def main() -> None:
    run_number = int(os.environ["RUN_NUMBER"])
    version_name = f"3.2.4.{run_number}"
    version_code = 100 + run_number

    apk_src = pathlib.Path("dsh-mobile-app/build/app/outputs/flutter-apk/app-release.apk")
    if not apk_src.is_file():
        raise SystemExit(f"Missing APK at {apk_src}")

    out_dir = pathlib.Path("release-personal")
    out_dir.mkdir(parents=True, exist_ok=True)
    apk_name = f"DSH-Remote-quickchat-v{version_name}.apk"
    apk_dst = out_dir / apk_name
    shutil.copy2(apk_src, apk_dst)

    cert_sha = extract_cert_sha256(apk_dst)
    apk_bytes = apk_dst.read_bytes()
    apk_sha = hashlib.sha256(apk_bytes).hexdigest()

    manifest = {
        "packageName": "com.dsh.remote",
        "versionName": version_name,
        "versionCode": version_code,
        "size": len(apk_bytes),
        "sha256": apk_sha,
        "certificateSha256": cert_sha,
        "apkUrl": f"https://dsh.kystation.cn/download/{apk_name}",
        "notes": "打开即聊默认输入框 + 固定签名应用内自更新",
    }
    manifest_path = out_dir / "app-update.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(manifest_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
