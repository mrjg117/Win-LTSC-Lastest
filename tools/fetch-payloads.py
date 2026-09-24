#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按 config.json 抓取「声明式载荷」到工作目录，供 delta 脚本消费。

两类载荷：
  optimize.components —— 每个「名字: 链接」抓一个文件到 assets/redist/<名字><扩展名>
                 例：vc14_x64 → assets/redist/vc14_x64.exe
                 .zip 若内含唯一 .exe/.msi 则就地解出内层安装器（外层丢弃）
                 落盘名 = <名字><扩展名>，07 正是靠 "名字.*" 通配取回它，两边必须一致
                 本脚本只负责下载；「安装还是解包」由 07.Bake-Image 按扩展名分流。
                 .zip 分发包装载（MPC-BE 官方 installer.zip 就是这种）：外层 zip 只是打包，
                 里面才是真安装器 —— 这里就地解开、只留内层 .exe/.msi，
                 免得把「一个 zip」当成安装包去写静默命令行。
  apps       —— 清单里写一行装一个，落成 assets/apps/<键>/ 目录，并写 apps-manifest.json
                 · 12 位 Store 产品 ID → 经 rg-adguard 换出微软官方 CDN 直链（含依赖框架）
                 · 含 :// 的完整直链   → 直接下载
                 license：同名目录下已有的 license.xml 原样保留（没有则走 /SkipLicense）

为什么用 rg-adguard：微软官方只给「产品 ID → WuCategoryId」，拿不到包下载地址；
包地址在 WU 交付服务里要过 [MS-WUSP] 的加密 Cookie + 时效签名，而 license 更是拿不到
（Store for Business 已于 2024-08 退役）。rg-adguard 是社区事实标准，它自己就是从
Microsoft Store 服务器取链接后转出（返回里带 "received from the Microsoft Store server"
与 Expire 时效），产物仍是微软官方 CDN 直链。

用法：
  python3 tools/fetch-payloads.py --config config.json --dest <工作目录> --branch 26100
退出码：0 成功；非 0 失败（缺包即失败，不静默跳过）
"""
import argparse
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
# Windows runner 的 l10n 是 en-US，Python 3.12 的 stdout 会回退到 cp1252 —— 一 print 中文就抛
# UnicodeEncodeError 把整个 step 打挂（CI 实测：日志里 `下载组件 …` 那一行直接炸）。
# 显式把标准流切到 UTF-8，脚本在任何宿主（cp1252 / cp936 / POSIX）上都能安全输出中文。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:                       # noqa: BLE001 - 被重定向成非 TextIOWrapper 时忽略
        pass

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
RG_API = "https://store.rg-adguard.net/api/GetFiles"
PKG_EXT = (".msixbundle", ".appxbundle", ".msix", ".appx")
# Store 应用运行时依赖的已知发布者前缀（这些是「依赖框架」，不是应用本体）
DEP_PREFIXES = (
    "microsoft.vclibs.",
    "microsoft.net.native.",
    "microsoft.ui.xaml.",
    "microsoft.winappruntime",
    "microsoft.windowsappruntime",
)
SKIP_EXT = (".blockmap", ".blockmap.xml")
APP_ID_RE = re.compile(r"^[0-9A-Z]{12}$")
TIMEOUT = 60


def log(msg):
    print(f"[fetch-payloads] {msg}", flush=True)


def fail(msg):
    print("::error::fetch-payloads: " + msg, flush=True)
    sys.exit(1)


def http(url, data=None, timeout=TIMEOUT, retries=3):
    """GET/POST，带 UA（rg-adguard 缺 UA 会 403）。"""
    last = None
    for i in range(1, retries + 1):
        try:
            body = urllib.parse.urlencode(data).encode() if data else None
            req = urllib.request.Request(url, data=body, headers={
                "User-Agent": UA,
                "Accept": "*/*",
                "Referer": "https://store.rg-adguard.net/",
                "Content-Type": "application/x-www-form-urlencoded",
            })
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:                      # noqa: BLE001 - 网络错误种类多，统一重试
            last = e
            log(f"WARN 第 {i}/{retries} 次请求失败 {url}: {e}")
    fail(f"请求失败（重试 {retries} 次）: {url} -- {last}")


def download(url, path, expect_size=None, retries=4):
    """流式下载 + 落盘（原子重命名）。网络层带重试，最终仍失败则 fail() 并打印真实 URL。

    原实现直接 urllib.request.urlopen 不带重试、无 try/except：任一瞬时网络抖动
    （403/503/超时/连接重置）都会抛未捕获异常、整步崩掉、且 annotation 只剩光秃秃的
    exit code 1（无 ::error:: 详情）。这里用指数退避重试，末次仍失败才 fail()，
    并把真实出错的 URL 与末次错误打出来，让 CI annotation 直接可读、可定位。
    """
    tmp = path + ".part"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            total = 0
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r, io.open(tmp, "wb") as f:
                while True:
                    buf = r.read(1 << 20)
                    if not buf:
                        break
                    f.write(buf)
                    total += len(buf)
            if total <= 0:
                # 服务器返回空体：按可重试的瞬时错误处理，删掉 .part 后重试
                raise IOError(f"下载到 0 字节: {url}")
            os.replace(tmp, path)
            if expect_size and abs(total - expect_size) > 1024:
                log(f"WARN 大小与清单不符（{total} vs {expect_size}）: {os.path.basename(path)}")
            log(f"OK {os.path.basename(path)}  {total/1048576:.1f} MB")
            return total
        except Exception as e:                       # noqa: BLE001 - 网络/IO 错误种类繁多，统一重试
            last = e
            # 失败则清掉半成品，避免残留 .part 干扰下次（落盘名不带 .part，不会被 SKIP 误判，
            # 但清掉更干净，重跑直接重新下载）
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except OSError:
                pass
            log(f"WARN 第 {attempt}/{retries} 次下载失败 {url}: {e}")
            if attempt < retries:
                time.sleep(min(2 ** attempt, 30))     # 指数退避，封顶 30s
    fail(f"下载失败（重试 {retries} 次）: {url} -- 末次错误: {last}")


# ---------------- components ----------------

# 安装器扩展名：07.Bake-Image 会为这些生成静默安装命令行。
INSTALLER_EXT = (".exe", ".msi")


def unwrap_installer(path):
    """若 path 是「装安装器的 zip」，就地解出唯一的安装器并返回其路径；否则原样返回。

    MPC-BE 官方只发 MPC-BE.1.9.1.x64-installer.zip，里面就一个 MPC-BE.1.9.1.x64.exe。
    外层 zip 如果不是这种形态（没有安装器 / 有多个），就原样保留并返回 None ——
    07 那边会按扩展名报错，绝不猜。
    """
    try:
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if not n.endswith("/")]
            installers = [n for n in names if n.lower().endswith(INSTALLER_EXT)]
            if len(installers) != 1:
                log(f"  ZIP 里安装器数量不是 1（{len(installers)}），按原样保留")
                return None
            inner = installers[0]
            out = os.path.join(os.path.dirname(path),
                               os.path.basename(inner))
            log(f"  解包 ZIP -> {os.path.basename(out)}（内层安装器）")
            with z.open(inner) as src, open(out, "wb") as dst:
                while True:
                    buf = src.read(1 << 20)
                    if not buf:
                        break
                    dst.write(buf)
        # [必须放在 with 之外] Windows 上 ZipFile 未关闭时文件仍被占用，
        # 在里面 os.remove 会 PermissionError: [WinError 32]
        os.remove(path)
        return out
    except zipfile.BadZipFile:
        return None


def fetch_components(cfg, dest):
    comps = ((cfg.get("optimize") or {}).get("components")) or {}
    if not comps:
        log("optimize.components 为空，跳过")
        return []
    outdir = os.path.join(dest, "assets", "redist")
    saved = []
    for name, url in comps.items():
        ext = os.path.splitext(urllib.parse.urlparse(url).path)[1] or ".bin"
        path = os.path.join(outdir, name + ext)
        if os.path.isfile(path) and os.path.getsize(path) > 0:
            log(f"SKIP 已存在: {name}{ext}")
        else:
            log(f"下载组件 {name} <- {url}")
            download(url, path)
        if path.lower().endswith(".zip"):
            inner = unwrap_installer(path)
            if inner:
                path = inner
        saved.append(path)
    return saved


# ---------------- apps ----------------

def rg_list(product_id):
    """Store 产品 ID -> [(文件名, URL, 大小字节)]，只保留包本体（丢 BlockMap/arm）。"""
    raw = http(RG_API, data={"type": "ProductId", "url": product_id,
                             "ring": "Retail", "lang": "en-US"})
    html = raw.decode("utf-8", "replace")
    m = re.search(r"CategoryID:\s*</b>\s*<i>([^<]+)</i>", html)
    if m:
        log(f"  CategoryID = {m.group(1)}")
    if "successfully received" not in html:
        fail(f"rg-adguard 未返回成功标记（产品 ID {product_id}），首段: {html[:200]!r}")
    rows = re.findall(r'<td><a href="([^"]+)"[^>]*>([^<]+)</a></td>'
                      r'<td[^>]*>([^<]*)</td><td[^>]*>([^<]*)</td><td[^>]*>([^<]*)</td>', html)
    items = []
    for url, fname, _expire, _sha1, size in rows:
        fname = fname.strip()
        low = fname.lower()
        if low.endswith(SKIP_EXT):
            continue
        if not low.endswith(PKG_EXT):
            # 注意：加密包 .eappxbundle / .emsixbundle 天然落在这里被丢掉 ——
            # 它们无法用于 DISM 离线预置（媒体播放器那种产品 ID 会同时给出加密与明文两份）。
            continue
        if "_arm_" in low or "_arm64_" in low or low.endswith("_arm64"):
            # Arm 包在 x64 目标上 DISM 会直接忽略（官方：If the Arm dependency package is also
            # specified or included, DISM will ignore it）—— 所以只丢 Arm，**不能丢 x86**。
            continue
        # [不要丢 x86] 官方文档：x64 目标映像上，架构相关的依赖必须把 **x86 与 x64 都给**
        #   （"on an x64 target image, include a path to both the x86 and x64 dependency packages"）。
        #   故 x86 包必须保留 —— 它只会作为**依赖**被选中：主包由 classify() 之后的
        #   is_x64_or_neutral 排序决定，x64/neutral 永远优先，x86 主包排在末尾不会被取。
        #   （历史上这里直接 continue 丢弃 x86，与官方要求冲突，会让 /Add-ProvisionedAppxPackage
        #     缺 x86 依赖。）
        nbytes = 0
        msz = re.match(r"([\d.]+)\s*(KB|MB|GB)", size.strip(), re.I)
        if msz:
            nbytes = int(float(msz.group(1)) * {"KB": 1024, "MB": 1048576, "GB": 1073741824}[msz.group(2).upper()])
        items.append((fname, url.rstrip(), nbytes))
    if not items:
        fail(f"rg-adguard 返回里没有可用的包（产品 ID {product_id}）")
    return items


def is_x64_or_neutral(fname):
    """主包候选的架构优先级：bundle 常带 _neutral_，拆开的单包带 _x64_。"""
    low = fname.lower()
    return "_x64_" in low or "_neutral_" in low


def pkg_version(fname):
    """从包名里取 4 段版本号（如 ..._22608.1401.3.0_neutral_...）；取不到返回 ()。

    [为什么不用体积排序] 同一产品 ID 会同时给出历史版本，而"最新版"并不总是最大那个：
    实测 Media Player 按体积会选到 2019 年的 48.5 MB 包，而现行版 11.2607.16.0 只有 38.4 MB。
    """
    m = re.search(r"_(\d+(?:\.\d+){0,3})_", fname)
    if not m:
        return ()
    return tuple(int(x) for x in m.group(1).split("."))


def classify(items):
    """拆成 (主包, 依赖列表)。依赖 = 已知运行时前缀；主包 = 其余。"""
    mains, deps = [], []
    for fname, url, size in items:
        if fname.lower().startswith(DEP_PREFIXES):
            deps.append((fname, url, size))
        else:
            mains.append((fname, url, size))
    if not mains:
        fail("只解出依赖框架、没有主包")
    return mains, deps


def fetch_apps(cfg, dest, branch, list_only=False):
    if list_only:
        # 调试开关：只解析、不落盘
        global download

        def download(url, path, expect_size=None):      # noqa: F811
            log(f"  [list-only] 将下载 {os.path.basename(path)}  <- {url[:96]}")
            return 0

    global_apps = list(cfg.get("apps") or [])
    br_apps = list(((cfg.get("branches") or {}).get(branch) or {}).get("apps") or [])
    apps = list(dict.fromkeys(global_apps + br_apps))           # 合并去重，保持顺序
    outroot = os.path.join(dest, "assets", "apps")
    if not apps:
        log(f"分支 {branch} 的 apps 清单为空，跳过")
        os.makedirs(outroot, exist_ok=True)
        with io.open(os.path.join(outroot, "apps-manifest.json"), "w",
                     encoding="utf-8", newline="\n") as f:
            json.dump({"branch": branch, "apps": []}, f, ensure_ascii=False, indent=2)
        return []

    records = []
    for value in apps:
        if "://" in value:
            fname = os.path.basename(urllib.parse.urlparse(value).path) or "package.msixbundle"
            key = os.path.splitext(fname)[0]
            rec = {"key": key, "kind": "url", "source": value, "main": [], "deps": []}
        elif APP_ID_RE.match(value):
            key, rec = value, {"key": value, "kind": "productid", "source": value,
                               "main": [], "deps": []}
        else:
            fail(f"无法识别的 apps 值: {value!r}")

        adir = os.path.join(outroot, key)
        os.makedirs(adir, exist_ok=True)

        if rec["kind"] == "url":
            fname = os.path.basename(urllib.parse.urlparse(value).path) or "package.msixbundle"
            path = os.path.join(adir, fname)
            if not (os.path.isfile(path) and os.path.getsize(path) > 0):
                log(f"下载应用 {key} <- {value}")
                download(value, path)
            else:
                log(f"SKIP 已存在: {key}/{fname}")
            rec["main"].append(os.path.relpath(path, dest).replace("\\", "/"))
            # 旁加载 MSIX（GitHub 发布的 .msix/.msixbundle 等）常附带同名 .xml license，
            # 离线预置时用来绕过 Store 签名信任。有就配对，没有也不致命（退回 /SkipLicense）。
            if fname.lower().endswith((".msix", ".msixbundle", ".appx", ".appxbundle")):
                stem = os.path.splitext(value)[0]
                lic_url = stem + ".xml"
                lic_path = os.path.join(adir, "license.xml")
                if not (os.path.isfile(lic_path) and os.path.getsize(lic_path) > 0):
                    try:
                        log(f"下载 license {key} <- {lic_url}")
                        download(lic_url, lic_path)
                    except Exception as e:          # noqa: BLE001 - license 缺失不阻断主包
                        log(f"WARN 未取得 license.xml（将用 /SkipLicense）: {e}")
                else:
                    log(f"SKIP 已存在: {key}/license.xml")
        else:
            log(f"解析 Store 产品 ID {value}")
            mains, deps = classify(rg_list(value))
            # 多主包（同一应用的多个版本/架构）：先要 x64/neutral，再取版本号最大的那个。
            # 刻意不按体积排（见 pkg_version 的说明）。
            mains.sort(key=lambda x: (is_x64_or_neutral(x[0]), pkg_version(x[0])), reverse=True)
            pick = mains[0]
            log(f"  选中主包 {pick[0]}（候选 {len(mains)} 个，按 x64/neutral + 版本号降序取首）")
            for fname, url, size in [pick] + deps:
                path = os.path.join(adir, fname)
                if os.path.isfile(path) and os.path.getsize(path) > 0:
                    log(f"SKIP 已存在: {key}/{fname}")
                else:
                    download(url, path, expect_size=size)
            rec["main"].append(os.path.relpath(os.path.join(adir, pick[0]), dest).replace("\\", "/"))
            for fname, _u, _s in deps:
                rec["deps"].append(os.path.relpath(os.path.join(adir, fname), dest).replace("\\", "/"))

        lic = os.path.join(adir, "license.xml")
        rec["license"] = os.path.relpath(lic, dest).replace("\\", "/") if os.path.isfile(lic) else None
        if rec["license"] is None:
            log(f"  {key} 无 license.xml -> 将用 /SkipLicense")
        records.append(rec)

    with io.open(os.path.join(outroot, "apps-manifest.json"), "w",
                 encoding="utf-8", newline="\n") as f:
        json.dump({"branch": branch, "apps": records}, f, ensure_ascii=False, indent=2)
    log(f"已写 assets/apps/apps-manifest.json（{len(records)} 个应用）")
    return records


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config.json")
    ap.add_argument("--dest", default=".")
    ap.add_argument("--branch", required=True)
    ap.add_argument("--only", choices=["components", "apps"], help="只抓一类（调试用）")
    ap.add_argument("--list-only", action="store_true", help="只解析包清单，不下载（调试用）")
    a = ap.parse_args()

    with io.open(a.config, encoding="utf-8") as f:
        cfg = json.load(f)

    if a.only != "apps":
        fetch_components(cfg, a.dest)
    if a.only != "components":
        fetch_apps(cfg, a.dest, a.branch, list_only=a.list_only)
    log("全部载荷就绪")
    return 0


if __name__ == "__main__":
    sys.exit(main())
