#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
config.yml -> config.json

唯一控制面板只解析一次：Linux 侧用 python3 解析 YAML，产出扁平 JSON 给 Windows 侧脚本读
（pwsh 没有内置 YAML 解析器，只读 JSON，避免在 Windows 侧引第三方解析库）。

顺带做结构性校验：把「配置写错」挡在构建之前（fail fast），而不是跑到一半才炸。
每个键都必须有消费者 —— 这里校验的就是"消费者能不能正确理解它"。

optimize 是唯一控制面板里唯一带结构的段（ini / registry / components 三个子键），
本脚本负责把它按执行器需要拍平成 JSON —— pwsh 侧不解析 YAML，只读拍平后的结果。

用法：python3 tools/config-to-json.py [config.yml] [config.json]
退出码：0 通过；非 0 失败（GitHub Actions 会显示 ::error:: 注解）
"""
import io
import json
import re
import sys

# ---- 允许的顶层键（写了别的 = 死字段，直接报错） ----
TOP_KEYS = {"baseline", "remove", "branches", "gvlk", "optimize", "apps", "storage"}

APP_ID_RE = re.compile(r"^[0-9A-Z]{12}$")          # Store 产品 ID
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
# components 可落地的形态 —— 与 07.Bake-Image 的落地分流必须完全一致
COMP_EXT = {".exe", ".msi", ".7z", ".zip"}

# ---- optimize 的三个子键（与执行器的分工必须完全一致） ----
OPT_KEYS = {"ini", "registry", "components", "_extensions"}
# ini 子键：值 = 一句话说明（纯注释，执行器统一置 1）
# registry 子键：值 = "hive|path|name|type|value" 字符串，或这类字符串的列表
# components 子键：值 = 安装器完整直链

HIVE_NAMES = {"SYSTEM", "SOFTWARE", "DEFAULT"}     # 与 07 的 $HIVES 必须一致
REG_TYPES = {"DWORD", "SZ", "EXPAND_SZ"}           # 写入时脚本自己拼 REG_ 前缀
REG_SEP = "|"
REG_FIELDS = 5                                     # hive|path|name|type|value


def fail(msg):
    print("::error::" + msg)
    sys.exit(1)


def parse_reg_value(val, where):
    """把一条 "hive|path|name|type|value" 拆成字典；写坏即报错。"""
    if not isinstance(val, str) or val.count(REG_SEP) < REG_FIELDS - 1:
        fail(f"{where} 必须是 {REG_FIELDS} 段竖线分隔的字符串：hive|path|name|type|value，实际: {val!r}")
    # value 段本身可能含竖线（值里写 | 是合法的），故只切前 4 个分隔符
    parts = val.split(REG_SEP, REG_FIELDS - 1)
    hive, path, name, rtype, value = parts
    hive = hive.strip()
    if hive not in HIVE_NAMES:
        fail(f"{where} 的 hive 只能是 {'/'.join(sorted(HIVE_NAMES))}，实际: {hive!r}")
    if not path.strip():
        fail(f"{where} 的 path 不能为空")
    rtype = rtype.strip()
    if rtype not in REG_TYPES:
        fail(f"{where} 的 type 只能是 {'/'.join(sorted(REG_TYPES))}，实际: {rtype!r}")
    if rtype == "DWORD" and not value.strip().lstrip("-").isdigit():
        fail(f"{where} 的 type 是 DWORD，value 必须是整数，实际: {value!r}")
    # 拆解结果直接落成 JSON 对象 —— 执行器（07）只读对象，不再重复解析字符串（单一解析点）
    return {"hive": hive, "path": path, "name": name, "type": rtype, "value": value}


def norm_opt_list(v, where):
    """optimize 子键的值 → 字符串列表（标量也接受，统一成列表）。"""
    if v is None:
        return []
    if isinstance(v, str):
        return [v]
    if not isinstance(v, list):
        fail(f"{where} 必须是字符串或字符串列表")
    out = []
    for it in v:
        if not isinstance(it, str) or not it.strip():
            fail(f"{where} 里的项必须是非空字符串，实际: {it!r}")
        out.append(it)
    return out


def check_components(comp, where):
    """components 子键：名字 -> 安装器直链（与 07 的分流规则必须一致）。"""
    if comp is None:
        return {}
    if not isinstance(comp, dict):
        fail(f"{where} 必须是映射（名字: 链接）")
    out = {}
    for k, v in comp.items():
        w = f"{where}.{k}"
        if v is None:
            fail(f"{w} 有名字没链接 —— 不集成就别写这一行（注释掉即可）")
        if "://" not in str(v):
            fail(f"{w} 的值必须是完整直链: {v!r}")
        tail = str(v).rsplit("/", 1)[-1].split("?", 1)[0]
        ext = ("." + tail.rsplit(".", 1)[-1]).lower() if "." in tail else ""
        if ext not in COMP_EXT:
            fail(f"{w} 的扩展名无法分流（引擎支持 {'/'.join(sorted(COMP_EXT))}）: {v!r}")
        out[k] = str(v).strip()
    return out


def parse_optimize(opt):
    """optimize 段 → 执行器直接可用的拍平结构。"""
    if opt is None:
        opt = {}
    if not isinstance(opt, dict):
        fail("optimize 必须是映射（子键: ini / registry / components）")
    unknown = set(opt) - OPT_KEYS
    if unknown:
        fail(f"optimize 含未知子键（无消费者，禁止留着）：{', '.join(sorted(unknown))}")

    # ---- ini ----
    ini_raw = opt.get("ini")
    if ini_raw is not None and not isinstance(ini_raw, dict):
        fail("optimize.ini 必须是映射（开关名: 一句话说明）")
    ini = []
    for k, v in (ini_raw or {}).items():
        if not re.match(r"^[A-Za-z0-9_]+$", k):
            fail(f"optimize.ini 的键名 {k!r} 不合法（只允许字母/数字/下划线）")
        if not isinstance(v, str):
            fail(f"optimize.ini.{k} 的值必须是字符串（一句话说明；取值由上游 ini 语义决定，统一置 1）")
        ini.append(k)

    # ---- registry ----
    reg_raw = opt.get("registry")
    if reg_raw is not None and not isinstance(reg_raw, dict):
        fail("optimize.registry 必须是映射（开关名: 竖线格式写入串）")
    ext = norm_opt_list(opt.get("_extensions"), "optimize._extensions")
    registry = []
    for k, v in (reg_raw or {}).items():
        if not re.match(r"^[A-Za-z0-9_]+$", k):
            fail(f"optimize.registry 的键名 {k!r} 不合法（只允许字母/数字/下划线）")
        lines = norm_opt_list(v, f"optimize.registry.{k}")
        if not lines:
            fail(f"optimize.registry.{k} 是空的 —— 该开关没有可执行的写入")
        puts = []
        for i, line in enumerate(lines):
            where = f"optimize.registry.{k}[{i}]" if len(lines) > 1 else f"optimize.registry.{k}"
            put = parse_reg_value(line, where)
            # 展开型：含 {ext} 的行要对 _extensions 各写一次 —— 清单为空就等于没写，必须拦
            if "{ext}" in line and not ext:
                fail(f"{where} 用了 {{ext}} 展开，但 optimize._extensions 是空的（没有取值清单）")
            puts.append(put)
        registry.append({"name": k, "puts": puts})
    if ext and not any("{ext}" in ln for k, v in (reg_raw or {}).items()
                       for ln in norm_opt_list(v, f"optimize.registry.{k}")):
        fail("optimize._extensions 写了却没有寄存器项用到 {ext} —— 要么补上展开行，要么删掉这份清单")

    # ---- components ----
    comps = check_components(opt.get("components"), "optimize.components")

    if not ini and not registry and not comps:
        fail("optimize 段是空的（ini / registry / components 都没写）—— 不做就把整段注释掉")
    return {"ini": ini, "registry": registry, "extensions": ext, "components": comps}


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

    # ---- apps（全局 + 分支） ----
    app_forms = {}
    for v in norm_list(cfg.get("apps"), "apps"):
        app_forms[v] = check_app_value(v, "apps")
    for b, bv in branches.items():
        for v in norm_list((bv or {}).get("apps"), f"branches.{b}.apps"):
            app_forms.setdefault(v, check_app_value(v, f"branches.{b}.apps"))

    # ---- optimize ----
    #   唯一带结构的段：ini / registry / components 三个子键，各由不同执行器消费。
    #   本脚本负责按执行器需要把它拍平（pwsh 侧不解析 YAML，只读拍平结果）。
    opt = parse_optimize(cfg.get("optimize"))

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
        "apps": norm_list(cfg.get("apps"), "apps"),
        "optimize": opt,
        "storage": uploads,
    }
    with io.open(dst, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"OK  {src} -> {dst}")
    print(f"    镜像 {len(sources)} 条；分支 {len(branches)} 个；"
          f"remove {len(rm_forms)} 项；apps {len(app_forms)} 个；"
          f"优化 ini {len(opt['ini'])} 项 / registry {len(opt['registry'])} 项"
          f"（展开清单 {len(opt['extensions'])} 个）/ components {len(opt['components'])} 个；"
          f"上传 {list(uploads) or '无'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
