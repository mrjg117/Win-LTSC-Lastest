#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从权威分发拉取官方 LTSC ISO，逐字节校验 SHA256，7z 分包（<=1.9GiB）后
上传到本仓库 baseline Release。

设计要点：
- 期望 SHA256 的单一真相源 = 仓库 config.yml 的 baseline.sha256.<分支>。
  拉取后强制比对，不符即中止（满足"权威分发必须校验微软公开值"）。
- 分卷命名 = 微软原版 ISO 名：<isoName>.7z.001 ...（build_iso.yml 按 *<isoName>.7z.* 匹配）。
- 单一来源 URL 在 baseline-sources.json。
- 磁盘约束：Actions runner 只有 ~14GB，两个 ISO 各 ~5GB，不能并发占盘。
  因此改为【逐分支】：下载→校验→分包→上传→立即删盘，再处理下一分支。
- 单分支失败不连累其它分支（记录失败，继续下一个；全部失败才退出非 0）。
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


def gh(*args):
    return subprocess.run(
        ["gh", *args, "--repo", REPO],
        capture_output=True, text=True,
        env=dict(os.environ, GH_TOKEN=TOKEN),
    )


def ensure_release():
    if gh("release", "view", "baseline").returncode != 0:
        gh("release", "create", "baseline", "--title", "baseline",
           "--notes", "官方 LTSC ISO 分卷（权威分发拉取，SHA256 见 baseline.manifest.json / SHA256SUMS）")


def write_manifest_and_sums(manifest):
    json.dump(manifest, open("baseline.manifest.json", "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    sums = []
    for _b, ed in manifest["editions"].items():
        for v, h in ed["volumeSha256"].items():
            sums.append(f"{h}  {v}")
    open("SHA256SUMS", "w", encoding="utf-8").write("\n".join(sums) + "\n")


# 载入已有 manifest（保留其它分支的条目）
manifest = {"generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "editions": {}}
try:
    gh("release", "download", "baseline", "--pattern", "baseline.manifest.json", "--dir", ".")
    old = json.load(open("baseline.manifest.json", encoding="utf-8-sig"))
    manifest["editions"] = dict(old.get("editions", {}))
    print("已载入已有 manifest（保留其它分支）")
except Exception as e:  # noqa: BLE001
    print("无已有 manifest（首次上传）:", e)

branches = ["19044", "26100"] if BRANCH_SEL == "all" else [BRANCH_SEL]
failed = []

for b in branches:
    if (not FORCE) and b in manifest["editions"]:
        print(f"{b} 已在 baseline 且非 force，跳过")
        continue

    exp = expected_sha(b)
    if not exp:
        print(f"ERROR: config.yml baseline.sha256.{b} 仍是占位符，请先填微软公开 SHA256")
        failed.append(b)
        continue

    info = src.get(b)
    if not info:
        print(f"ERROR: baseline-sources.json 缺少 {b}")
        failed.append(b)
        continue

    iso = info["isoName"]
    sources = [s for s in info.get("sources", []) if "REPLACE" not in s["url"]]
    if SRC_SEL != "auto":
        f = [s for s in sources if SRC_SEL in s["name"].lower()]
        sources = f if f else sources

    ok = False
    used = None
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
        failed.append(b)
        continue

    act = sha256_file("dl_" + iso)
    if act.lower() != exp.lower():
        print(f"ERROR: {b} SHA256 不符! 期望 {exp} 实际 {act}")
        failed.append(b)
        continue
    print(f"{b} SHA256 校验通过: {act}")

    subprocess.run(["7z", "a", "-v1900m", f"{iso}.7z", "dl_" + iso], check=True)
    vols = sorted(glob.glob(f"{iso}.7z.*"))
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
    write_manifest_and_sums(manifest)

    ensure_release()
    files = vols + ["baseline.manifest.json", "SHA256SUMS"]
    r = gh("release", "upload", "baseline", "--clobber", *files)
    if r.returncode != 0:
        print("UPLOAD FAIL:", r.stderr)
        # 回滚 manifest 中本分支，避免下次误判已存在
        manifest["editions"].pop(b, None)
        write_manifest_and_sums(manifest)
        failed.append(b)
    else:
        print(f"{b} 上传完成: {len(vols)} 块 -> baseline Release")

    # 立即删盘，释放空间给下一分支（runner 仅 ~14GB）
    try:
        os.remove("dl_" + iso)
    except OSError:
        pass
    for v in vols:
        try:
            os.remove(v)
        except OSError:
            pass

if not manifest["editions"]:
    print("ERROR: 没有任何分支成功")
    sys.exit(1)

print("DONE. 成功分支:", list(manifest["editions"].keys()), "失败:", failed)
if failed:
    sys.exit(1)
print("UPLOAD DONE")
