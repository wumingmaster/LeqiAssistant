#!/usr/bin/env python3
"""Build an APK from a temporary source copy, preserving the installed signer."""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCAL_CONFIG = ROOT / "local-config.json"



def run(args):
    subprocess.run([str(x) for x in args], check=True, cwd=ROOT)


def apply_local_config(source, config_path):
    settings = json.loads(config_path.read_text()) if config_path.is_file() else {}
    if not isinstance(settings, dict):
        raise ValueError("local config must be a JSON object")
    constants = []
    for key in ("home_url", "feeder_url", "updater_url"):
        value = settings.get(key, "")
        if not isinstance(value, str):
            raise ValueError(f"{key} must be a URL string")
        if value:
            url = urlsplit(value)
            schemes = ("https", "http") if key == "updater_url" else ("https",)
            if (url.scheme not in schemes or not url.hostname or url.username is not None
                    or url.query or url.fragment or any(c.isspace() for c in value)):
                raise ValueError(f"{key} must be a URL without credentials, query, or fragment")
        if key != "feeder_url":
            value = value.rstrip("/")
        constants.append(f"    static final String {key.upper()} = {json.dumps(value)};")
    endpoints = source / "java/party/xiaoyu/glasses/wakeprobe/CompanionEndpoints.java"
    endpoints.write_text(
        "package party.xiaoyu.glasses.wakeprobe;\n\n"
        "final class CompanionEndpoints {\n"
        + "\n".join(constants)
        + "\n    private CompanionEndpoints() {}\n}\n"
    )
    updater = urlsplit(settings.get("updater_url", ""))
    if updater.scheme == "http":
        config = source / "res/xml/network_security_config.xml"
        tree = ET.parse(config)
        domain_config = ET.SubElement(tree.getroot(), "domain-config", cleartextTrafficPermitted="true")
        ET.SubElement(domain_config, "domain", includeSubdomains="false").text = updater.hostname
        tree.write(config, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--code", type=int, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--sdk", type=pathlib.Path, required=True)
    parser.add_argument("--signer-dir", type=pathlib.Path, required=True,
                        help="Directory with the existing companion's key.p12 and password")
    parser.add_argument("--config", type=pathlib.Path,
                        help="Optional local endpoints JSON (defaults to GlassesCompanion/local-config.json)")
    args = parser.parse_args()
    if args.config is not None and not args.config.is_file():
        parser.error("--config must name an existing file")
    tools = args.sdk.resolve() / "build-tools" / "35.0.0"
    android = args.sdk.resolve() / "platforms" / "android-35" / "android.jar"
    signer = args.signer_dir.resolve()
    if args.code < 1 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", args.version):
        raise ValueError("invalid version")
    with tempfile.TemporaryDirectory(prefix="glasses-build-") as temp:
        work = pathlib.Path(temp)
        source = work / "main"
        shutil.copytree(ROOT / "app/src/main", source)
        apply_local_config(source, args.config or LOCAL_CONFIG)
        manifest = source / "AndroidManifest.xml"
        text = manifest.read_text()
        text, count = re.subn(r'android:versionCode="[0-9]+" android:versionName="[^"]+"',
                              f'android:versionCode="{args.code}" android:versionName="{args.version}"', text, count=1)
        if count != 1: raise ValueError("manifest version not found")
        manifest.write_text(text)
        activity = source / "java/party/xiaoyu/glasses/wakeprobe/MainActivity.java"
        text, count = re.subn(r'小米同学 · v[0-9.]+', '小米同学 · v' + args.version, activity.read_text(), count=1)
        if count != 1: raise ValueError("display version not found")
        activity.write_text(text)
        gen, classes, dex = (work / x for x in ("gen", "classes", "dex"))
        for directory in (gen, classes, dex): directory.mkdir()
        base, unsigned, aligned = (work / x for x in ("base.apk", "unsigned.apk", "aligned.apk"))
        run([tools / "aapt", "package", "-f", "-m", "-J", gen, "-M", manifest, "-S", source / "res", "-I", android, "-F", base])
        java = sorted((source / "java").rglob("*.java")) + sorted(gen.rglob("*.java"))
        run(["javac", "-source", "8", "-target", "8", "-encoding", "UTF-8", "-classpath", f"{android}:{ROOT / 'sdk/classes.jar'}", "-d", classes, *java])
        jar = work / "app.jar"
        run(["jar", "cf", jar, "-C", classes, "."])
        run([tools / "d8", "--min-api", "26", "--lib", android, "--output", dex, jar, ROOT / "sdk/classes.jar"])
        with zipfile.ZipFile(unsigned, "w") as out, zipfile.ZipFile(base) as resources:
            for item in resources.infolist(): out.writestr(item, resources.read(item.filename))
            out.write(dex / "classes.dex", "classes.dex", compress_type=zipfile.ZIP_DEFLATED)
            for lib in sorted((ROOT / "sdk/jni/arm64-v8a").glob("*.so")):
                out.write(lib, "lib/arm64-v8a/" + lib.name, compress_type=zipfile.ZIP_DEFLATED)
        run([tools / "zipalign", "-f", "4", unsigned, aligned])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        run([tools / "apksigner", "sign", "--ks", signer / "key.p12", "--ks-pass", "file:" + str(signer / "password"), "--out", args.output, aligned])
        run([tools / "apksigner", "verify", "--print-certs", args.output])
        run([tools / "aapt", "dump", "badging", args.output])


if __name__ == "__main__":
    main()
