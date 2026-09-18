#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从权威分发（archive.org / itellyou）拉取官方 LTSC ISO，逐字节校验 SHA256，
7z 分包（<=1.9GiB）后上传到本仓库 baseline Release。

设计要点：
- 期望 SHA256 的单一真相源 = 仓库 config.yml 的 baseline.sha256.<分支>。
  拉取后强制比对，不符即中止（满足"权威分发必须校验微软公开值"）。
- 分卷命名必须含分支号：baseline-<分支>.7z.001 ...（build_iso.yml 按 *$branch.7z.* 匹配）。
- 单一来源 URL 在 baseline-sources.json（含 REPLACE 占位符的源会被跳过）。
- 已存在于 baseline 且非 --force 的分支直接跳过（避免重复拉 5GB）。
- manifest 跨次合并：先下载已有 baseline.manifest.json 保留其它分支，再写回。
"""
import os
import re
import sys
import json
import hashlib
import glob
import time
import subprocess
import urllib.request

REPO = os.environ["GITHUB_REPOSITORY"]  # owner/repo，由 Actions 注入
BRANCH_SEL = os.environ.get("BRANCH_SEL", "all")
SRC_SEL = os.environ.get("SRC_SEL", "auto")
FORCE = os.environ.get("FORCE", "false") == "true"
TOKEN = os.environ.get("GH_TOKEN", "")

cfg = open("config.yml", encoding="utf-8-sig").read()
src = json.load(open("baseline-sources.json", encoding="utf-8-sig"))


def expected_sha(branch):
    m = re.search(r'"%s"\s*:\s*"([0-9a-fA-F]{64})"' % branch, cfg)
    return m.group(1) if m else None


def download(url, dest, retries=5):
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=600) as r, open(dest, "wb") as f:
                while True:
                    buf = r.read(1024 * 1024)
                    if not buf:
                        break
                    f.write(buf)
            return True
        except Exception as e:  # noqa: BLE001
            last = e
            print("  retry", i, e)
            time.sleep(5)
    raise last


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()


env = dict(os.environ, GH_TOKEN=TOKEN)

# 载入已有 manifest（保留其它分支的条目）
manifest = {"generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "editions": {}}
try:
    subprocess.run(
        ["gh", "release", "download", "baseline", "--repo", REPO,
         "--pattern", "baseline.manifest.json", "--dir", "."],
        check=True, env=env, capture_output=True,
    )
    old = json.load(open("baseline.manifest.json", encoding="utf-8-sig"))
    manifest["editions"] = dict(old.get("editions", {}))
    print("已载入已有 manifest（保留其它分支）")
except Exception as e:  # noqa: BLE001
    print("无已有 manifest（首次上传）:", e)

branches = ["19044", "26100"] if BRANCH_SEL == "all" else [BRANCH_SEL]

for b in branches:
    if (not FORCE) and b in manifest["editions"]:
        print(f"{b} 已在 baseline 且非 force，跳过")
        continue

    exp = expected_sha(b)
    if not exp:
        print(f"ERROR: config.yml baseline.sha256.{b} 仍是占位符，请先填微软公开 SHA256（权威分发必须校验）")
        sys.exit(1)

    info = src.get(b)
    if not info:
        print(f"ERROR: baseline-sources.json 缺少 {b}")
        sys.exit(1)

    iso = info["isoName"]
    sources = [s for s in info.get("sources", []) if "REPLACE" not in s["url"]]
    if SRC_SEL != "auto":
        f = [s for s in sources if SRC_SEL in s["name"].lower()]
        sources = f if f else sources

    ok = False
    for s in sources:
        print("尝试源:", s["name"], s["url"])
        try:
            download(s["url"], "dl_" + iso)
            ok = True
            used = s
            break
        except Exception as e:  # noqa: BLE001
            print("  失败:", e)
    if not ok:
        print(f"ERROR: {b} 所有源下载失败")
        sys.exit(1)

    act = sha256_file("dl_" + iso)
    if act.lower() != exp.lower():
        print(f"ERROR: {b} SHA256 不符! 期望 {exp} 实际 {act}")
        sys.exit(1)
    print(f"{b} SHA256 校验通过: {act}")

    subprocess.run(["7z", "a", "-v1900m", f"baseline-{b}.7z", "dl_" + iso], check=True)
    vols = sorted(glob.glob(f"baseline-{b}.7z.*"))
    vsha = {v: sha256_file(v) for v in vols}
    manifest["editions"][b] = {
        "isoName": iso,
        "isoSha256": act,
        "source": used["name"],
        "sourceUrl": used["url"],
        "volumes": vols,
        "volumeSha256": vsha,
        "volumeMiB": 1900,
    }
    print(f"{b} 分卷完成: {len(vols)} 块")

json.dump(manifest, open("baseline.manifest.json", "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)

sums = []
for _b, ed in manifest["editions"].items():
    for v, h in ed["volumeSha256"].items():
        sums.append(f"{h}  {v}")
open("SHA256SUMS", "w", encoding="utf-8").write("\n".join(sums) + "\n")

r = subprocess.run(["gh", "release", "view", "baseline", "--repo", REPO],
                   capture_output=True, env=env)
if r.returncode != 0:
    subprocess.run(
        ["gh", "release", "create", "baseline", "--repo", REPO, "--title", "baseline",
         "--notes", "官方 LTSC ISO 分卷（权威分发拉取，SHA256 见 baseline.manifest.json / SHA256SUMS）"],
        check=True, env=env,
    )

files = []
for _b in manifest["editions"]:
    files += sorted(glob.glob(f"baseline-{_b}.7z.*"))
files += ["baseline.manifest.json", "SHA256SUMS"]
subprocess.run(["gh", "release", "upload", "baseline", "--repo", REPO, "--clobber", *files],
               check=True, env=env)
print("UPLOAD DONE")
