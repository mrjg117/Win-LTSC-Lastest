#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
config.yml -> config.json

唯一控制面板只解析一次：Linux 侧用 python3 解析 YAML，产出扁平 JSON 给 Windows 侧脚本读
（pwsh 没有内置 YAML 解析器，只读 JSON，避免在 Windows 侧引第三方解析库）。

顺带做结构性校验：把「配置写错」挡在构建之前（fail fast），而不是跑到一半才炸。
每个键都必须有消费者 —— 这里校验的就是"消费者能不能正确理解它"。

用法：python3 tools/config-to-json.py [config.yml] [config.json]
退出码：0 通过；非 0 失败（GitHub Actions 会显示 ::error:: 注解）
"""
import io
import json
import re
import sys

# ---- 允许的顶层键（写了别的 = 死字段，直接报错） ----
TOP_KEYS = {"baseline", "remove", "branches", "gvlk", "components", "apps", "optimize", "storage"}

# ---- optimize 允许的项：漏一个就报错，防止"写了却没人执行" ----
OPT_INI = {"nosuggapp", "nosuggtip", "norestorage", "nogamebar", "oobebypass", "UpdtBootFiles"}
OPT_HIVE = {
    # 电源与性能
    "disable_hibernate", "disable_faststartup",
    # 隐私（Policies 路径）
    "disable_telemetry", "no_consumer_features", "no_spotlight", "no_advertising_id", "no_feedback",
    # 界面（默认用户 hive）
    "show_file_extensions", "show_hidden_files", "taskbar_align_left", "classic_context_menu", "numlock_on",
    # 安全与兼容
    "no_bitlocker_auto", "allow_all_trusted_apps",
}

APP_ID_RE = re.compile(r"^[0-9A-Z]{12}$")          # Store 产品 ID
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def fail(msg):
    print("::error::" + msg)
    sys.exit(1)


def norm_list(v, where, keep_int=False):
    """空/缺键归一化成 []；非列表即报错。"""
    if v is None:
        return []
    if not isinstance(v, list):
        fail(f"{where} 必须是列表（每行一个 - 项）")
    out = []
    for it in v:
        if isinstance(it, int) and not isinstance(it, bool):
            if not keep_int:
                fail(f"{where} 里的项必须是字符串，实际: {it!r}")
            out.append(it)
            continue
        if not isinstance(it, str) or not it.strip():
            fail(f"{where} 里的项必须是非空字符串，实际: {it!r}")
        out.append(it.strip())
    return out


def check_remove_name(name, where):
    """remove 的名字形态 —— 与 06 的分流规则必须完全一致。"""
    if "~~~~" in name:
        return "capability"
    if name.endswith("-Package"):
        return "package"
    if re.search(r"\s", name):
        fail(f"{where} 的名字含空格，无法分流: {name!r}")
    return "feature"


def check_app_value(v, where):
    """apps 的值形态 —— 与下载脚本的分流规则必须完全一致。"""
    if "://" in v:
        return "url"
    if APP_ID_RE.match(v):
        return "productid"
    fail(f"{where} 的值既不是 12 位 Store 产品 ID、也不是含 :// 的直链: {v!r}")


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "config.yml"
    dst = sys.argv[2] if len(sys.argv) > 2 else "config.json"

    try:
        import yaml
    except ImportError:
        print("::error::缺少 PyYAML（Linux runner 上：pip install pyyaml）")
        return 2

    with io.open(src, encoding="utf-8-sig") as f:
        cfg = yaml.safe_load(f)
    if not isinstance(cfg, dict):
        fail(f"{src} 解析结果不是映射")

    # ---- 顶层键 ----
    unknown = sorted(set(cfg) - TOP_KEYS)
    if unknown:
        fail(f"{src} 含未知顶层键（无消费者，禁止留着）：{', '.join(unknown)}")

    # ---- baseline ----
    bl = cfg.get("baseline") or {}
    if not isinstance(bl, dict):
        fail("baseline 必须是映射")
    chunk = int(bl.get("chunk_mib") or 0)
    if chunk <= 0:
        fail("baseline.chunk_mib 必须是正整数（MiB）")
    threads = int(bl.get("threads") or 0)
    if threads <= 0:
        fail("baseline.threads 必须是正整数")
    sources = bl.get("sources")
    if not isinstance(sources, list) or not sources:
        fail("baseline.sources 必须是非空列表（一行一条镜像，份数 = 条数）")
    seen = set()
    for i, s in enumerate(sources):
        where = f"baseline.sources[{i}]"
        if not isinstance(s, dict):
            fail(f"{where} 必须是映射")
        br = str(s.get("branch") or "").strip()
        url = str(s.get("url") or "").strip()
        sha = str(s.get("sha256") or "").strip()
        if not br:
            fail(f"{where} 缺 branch")
        if br in seen:
            fail(f"{where} branch 重复: {br}")
        seen.add(br)
        if not url.startswith(("http://", "https://")):
            fail(f"{where}.url 必须是完整 HTTP(S) 地址（不拼接、逐条写全）")
        if not SHA256_RE.match(sha):
            fail(f"{where}.sha256 必须是 64 位十六进制")
        if not url.rsplit("/", 1)[-1].lower().endswith(".iso"):
            fail(f"{where}.url 末段必须是 .iso 文件名（分片名/merge 键/成品名都从它派生）")

    # ---- branches ----
    branches = cfg.get("branches")
    if not isinstance(branches, dict) or not branches:
        fail("branches 必须是非空映射（每分支一节）")
    gvlk = cfg.get("gvlk") or {}
    for b, bv in branches.items():
        where = f"branches.{b}"
        if not isinstance(bv, dict):
            fail(f"{where} 必须是映射")
        if b not in seen:
            fail(f"{where} 在 baseline.sources 里没有对应条目（没有基线 ISO 就构不出来）")
        if not str(bv.get("label") or "").strip():
            fail(f"{where}.label 必填（产物标签的 Win 版本号由它推）")
        elif not re.search(r"win\s*\d+", str(bv["label"]), re.I):
            fail(f"{where}.label 里推不出 Win 版本号，产物标签会拼错: {bv['label']}")
        ed = str(bv.get("edition") or "").strip()
        if not ed:
            fail(f"{where}.edition 必填（构建时 Set-Edition 的目标 SKU）")
        if ed not in gvlk:
            fail(f"{where}.edition={ed} 不在 gvlk 表里（没密钥转不了 SKU）")
        if not str(bv.get("detect") or "").strip():
            # check-updates 用它在 Update Catalog 里认本分支的产品：
            # 只有搜到该产品的累积更新，才能比较"微软发了新的没"
            fail(f"{where}.detect 必填（Update Catalog 里本分支产品的搜索词）")
        fam = norm_list(bv.get("family"), f"{where}.family", keep_int=True)
        if not fam:
            fail(f"{where}.family 不能为空（UBR 断言靠它判断 build 是否合理）")
        for x in fam:
            if not str(x).isdigit():
                fail(f"{where}.family 里必须是 build 号数字，实际: {x!r}")
        norm_list(bv.get("remove"), f"{where}.remove")
        norm_list(bv.get("apps"), f"{where}.apps")
    for k in gvlk:
        if not re.match(r"^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$", str(gvlk[k]).strip()):
            fail(f"gvlk.{k} 不像 KMS 安装密钥: {gvlk[k]!r}")

    # ---- remove（全局 + 分支） ----
    glob_rm = norm_list(cfg.get("remove"), "remove")
    rm_forms = {}
    for n in glob_rm:
        rm_forms[n] = check_remove_name(n, "remove")
    for b, bv in branches.items():
        for n in norm_list((bv or {}).get("remove"), f"branches.{b}.remove"):
            rm_forms.setdefault(n, check_remove_name(n, f"branches.{b}.remove"))

    # ---- components ----
    comps = cfg.get("components")
    if comps is not None and not isinstance(comps, dict):
        fail("components 必须是映射（名字: 链接）")
    for k, v in (comps or {}).items():
        if v is None:
            fail(f"components.{k} 有名字没链接 —— 不集成就别写这一行（注释掉即可）")
        if "://" not in str(v):
            fail(f"components.{k} 的值必须是完整直链: {v!r}")

    # ---- apps（全局 + 分支） ----
    app_forms = {}
    for v in norm_list(cfg.get("apps"), "apps"):
        app_forms[v] = check_app_value(v, "apps")
    for b, bv in branches.items():
        for v in norm_list((bv or {}).get("apps"), f"branches.{b}.apps"):
            app_forms.setdefault(v, check_app_value(v, f"branches.{b}.apps"))

    # ---- optimize ----
    opt = norm_list(cfg.get("optimize"), "optimize")
    if len(set(opt)) != len(opt):
        dup = sorted({x for x in opt if opt.count(x) > 1})
        fail(f"optimize 有重复项: {', '.join(dup)}")
    ini_items, hive_items = [], []
    for name in opt:
        if name in OPT_INI:
            ini_items.append(name)
        elif name in OPT_HIVE:
            hive_items.append(name)
        else:
            fail(f"optimize 里的 {name!r} 没有实现（既不是上游 ini 开关，也不是自有离线注入项）")

    # ---- storage ----
    st = cfg.get("storage") or {}
    if not isinstance(st, dict):
        fail("storage 必须是映射（值 = 保留份数）")
    uploads = {}
    for k in ("release", "r2", "onedrive"):
        v = st.get(k)
        if v is None:
            continue
        if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
            fail(f"storage.{k} 必须是正整数（= 保留份数），实际: {v!r}")
        uploads[k] = v

    # ---- 归一化后落盘（pwsh 侧不用再处理 null） ----
    out = {
        "baseline": {"chunk_mib": chunk, "threads": threads, "sources": sources},
        "remove": glob_rm,
        "branches": {
            b: {
                "label": str(bv.get("label")).strip(),
                "edition": str(bv.get("edition")).strip(),
                "detect": str(bv.get("detect")).strip(),
                "family": [int(x) for x in norm_list(bv.get("family"), f"branches.{b}.family", keep_int=True)],
                "remove": norm_list(bv.get("remove"), f"branches.{b}.remove"),
                "apps": norm_list(bv.get("apps"), f"branches.{b}.apps"),
            }
            for b, bv in branches.items()
        },
        "gvlk": {k: str(v).strip() for k, v in gvlk.items()},
        "components": {k: str(v).strip() for k, v in (comps or {}).items()},
        "apps": norm_list(cfg.get("apps"), "apps"),
        "optimize": opt,
        # 组别在解析这一处判好，下游按名取用即可（各自再维护一份名单必然漂移）
        "optimize_ini": ini_items,      # 上游 W10UI.ini 开关 -> 99 写 ini（写了 = 置 1）
        "optimize_hive": hive_items,    # 自有离线注入项 -> 07 写目标 hive
        "storage": uploads,
    }
    with io.open(dst, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"OK  {src} -> {dst}")
    print(f"    镜像 {len(sources)} 条；分支 {len(branches)} 个；"
          f"remove {len(rm_forms)} 项；components {len(out['components'])} 个；"
          f"apps {len(app_forms)} 个；optimize {len(opt)} 项（ini {len(ini_items)} / hive {len(hive_items)}）；"
          f"上传 {list(uploads) or '无'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
