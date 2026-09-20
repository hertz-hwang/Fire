#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rime 拼音字词库 → Fire 拼音词库 → `.hdict` 私有容器。

输入（默认 tmp/pinyin_dict/，rime `词\t音节 音节…\t词频` 格式，头部 `--- … ...` 元数据）：
  8105.dict.yaml     《通用规范汉字表》8105 字 + 25 亿语料字频
  base.dict.yaml     基础词库
  ext.dict.yaml      扩充词库
  tencent.dict.yaml  腾讯词库（长尾，词频基本为 0）
  41448.dict.yaml    大字表（生僻字，词频多为 0）

中间产物是 Fire 统一码表格式的行流：`词\t连写全拼[\t词频]`
  - 编码取**连写全拼**（`开发 → kaifa`），与 schemas 下其余码表、TableBuilder 建
    sqlite、五笔拼音混输的 `query glob` 前缀查询同一口径；双拼不另立词库——引擎
    把双拼键解码成音节后再查这同一份索引（见 `ShuangpinScheme` / `PinyinLexicon`）。
  - 第三列词频可选；缺省时 Fire 按文件序当 rank。

最终打包成 `.hdict`：Fire 私有词库容器（定长头 + 单个压缩块）。容器格式（小端，
解析端 `Fire/Table/HDict.swift` 与此处逐字段对齐）：

  偏移  长度  字段
  0     4    magic  "HDCT"
  4     2    version      容器版本 = 1
  6     2    kind         1=拼音（全拼码） 2=双拼（预留）
  8     2    codec        0=不压缩 1=raw deflate
  10    2    flags        bit0=数据行带词频列  bit1=数据行已规范化（无多余空白、
                              编码只用 a-z、且 (词,码) 已去重）
  12    4    entry_count  词条数
  16    8    payload_size 解压后字节数
  24    8    stored_size  文件内负载字节数
  32    4    payload_crc32
  36    4    header_crc32（计算时本字段与之后的保留区按 0 计）
  40    24   保留（全 0）
  64    …    payload

raw deflate（`wbits=-15`）与 Apple `Compression` 框架的 `COMPRESSION_ZLIB` 是同一种
流，Swift 侧 `compression_decode_buffer` 直接解，不引第三方依赖。

注音合法性以引擎自己的音节表为准：**音节表从 `Fire/Pinyin/PinyinSyllables.swift`
读出**，词库里出现引擎切不开的音节（`cei`/`yai`/`lvan`…）整条丢弃，
免得建索引时静默漏词条。`lue/nue` 按 `PinyinSyllables.canonical` 归一到 `lve/nve`。

用法：
  python3 scripts/build_pinyin_hdict.py                        # 默认档 → schemas/py.hdict
  python3 scripts/build_pinyin_hdict.py --tier full --plain /tmp/py_full.txt
  python3 scripts/build_pinyin_hdict.py --tier core --out /tmp/py_core.hdict
  python3 scripts/build_pinyin_hdict.py --sources base.dict.yaml:5 --out /tmp/only_base.hdict
  python3 scripts/build_pinyin_hdict.py --verify Fire/Resources/schemas/py.hdict
"""
import argparse
import os
import re
import struct
import sys
import zlib
from collections import Counter

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DICT_DIR = os.path.join(REPO, "tmp", "pinyin_dict")
SYLLABLES_SWIFT = os.path.join(REPO, "Fire", "Pinyin", "PinyinSyllables.swift")
DEFAULT_OUT = os.path.join(REPO, "Fire", "Resources", "schemas", "py.hdict")

MAGIC = b"HDCT"
CONTAINER_VERSION = 1
KIND_PINYIN = 1
KIND_SHUANGPIN = 2          # 预留：双拼键位码词库（当前引擎用不到，见模块文档）
CODEC_NONE = 0
CODEC_DEFLATE = 1
FLAG_WEIGHT = 1
FLAG_CANONICAL = 2
HEADER = struct.Struct("<4sHHHHIQQII")
HEADER_SIZE = 64

# 与 Swift 侧上限对齐：PinyinLexicon.maxWordSyllables、load() 的 code.count <= 32
MAX_SYLLABLES = 8
MAX_CODE_LENGTH = 32

# 每档 = [(词库, 准入词频)]。**顺序即多源合并的优先级**，字表放最后：
# 同一个字在词库与字表里都有注音时，出处记到字表那条（rime 侧同规则）。
TIERS = {
    # 精简：基础词 + 常用字
    "core": [
        ("base.dict.yaml", 10),
        ("8105.dict.yaml", 0),
    ],
    # 默认：+ 扩充词库
    "standard": [
        ("base.dict.yaml", 5),
        ("ext.dict.yaml", 5),
        ("8105.dict.yaml", 0),
    ],
    # 全量：+ 腾讯长尾 + 大字表
    "full": [
        ("base.dict.yaml", 1),
        ("ext.dict.yaml", 1),
        ("tencent.dict.yaml", 0),
        ("8105.dict.yaml", 0),
        ("41448.dict.yaml", 0),
    ],
}

CANONICAL = {"lue": "lve", "nue": "nve"}


# --------------------------------------------------------------------------- #
# 音节表
# --------------------------------------------------------------------------- #

def load_syllables(path=SYLLABLES_SWIFT):
    """从引擎源码取合法音节表，并套用 canonical 归一（lue→lve、nue→nve）。

    词库与切分器必须共用这一份事实来源：抄一份 Python 副本，早晚和引擎漂开。
    """
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    match = re.search(r"static let all: \[String\] = \[(.*?)\n\s*\];", source, re.S)
    if not match:
        raise SystemExit("读不到 PinyinSyllables.all：{} 结构变了？".format(path))
    table = set(re.findall(r'"([a-z]+)"', match.group(1)))
    return {CANONICAL.get(item, item) for item in table}


# --------------------------------------------------------------------------- #
# 读 rime 词库
# --------------------------------------------------------------------------- #

def iter_rime(path):
    """产出 (词, [音节], 词频)。跳过 # 注释与 `--- … ...` 元数据段。"""
    started = False
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n").rstrip("\r")
            if not started:
                if line.strip() == "...":
                    started = True
                continue
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            text = parts[0].strip()
            syllables = parts[1].split()
            try:
                weight = int(parts[2]) if len(parts) > 2 else 0
            except ValueError:
                weight = 0
            if text and syllables:
                yield text, syllables, weight


def convert_entry(text, syllables, valid, dropped):
    """(词, 音节) → (词, 连写码)；不合格返回 None 并记一笔原因。"""
    if any(ch.isspace() for ch in text):
        dropped["词内空白"] += 1
        return None
    code = []
    for syllable in syllables:
        item = CANONICAL.get(syllable.lower(), syllable.lower())
        if item not in valid:
            dropped["音节表切不开:" + item] += 1
            return None
        code.append(item)
    if len(code) > MAX_SYLLABLES:
        dropped["音节数超上限"] += 1
        return None
    joined = "".join(code)
    if len(joined) > MAX_CODE_LENGTH:
        dropped["码长超上限"] += 1
        return None
    return text, joined


# --------------------------------------------------------------------------- #
# 合并与排序
# --------------------------------------------------------------------------- #

def merge(sources, valid, stats):
    """多源合并 → 排序后的 [(词, 连写码, 词频)]。

    去重键是 (词, 码)：同一个词的不同读音必须各留一条（长 chang / zhang），
    同词同码跨源重复则只留一条，词频取各源最大值、出处取优先级最高的源。

    文件序在 Fire 里就是 rank（同码重码的常用次序），所以这个排序就是打分标定：
      * 词频降序 —— 常词在前，腾讯那批 0 频长尾自然沉底；
      * 同频时短词优先 —— 0 频段内部没有常用度信息，短词更常见；
      * 再按码、词字面 —— 结果可复现，同样的输入永远同样的字节。
    """
    merged = {}
    for priority, (name, min_weight) in enumerate(sources):
        path = os.path.join(DICT_DIR, name)
        if not os.path.isfile(path):
            raise SystemExit("缺少词库：{}".format(path))
        added = 0
        seen = 0
        for text, syllables, weight in iter_rime(path):
            if weight < min_weight:
                stats["低于准入词频"] += 1
                continue
            converted = convert_entry(text, syllables, valid, stats)
            if converted is None:
                continue
            entry, code = converted
            key = (entry, code)
            seen += 1
            old = merged.get(key)
            if old is None:
                merged[key] = [code, weight, priority]
                added += 1
            else:
                if weight > old[1]:
                    old[1] = weight
                if priority < old[2]:
                    old[2] = priority
        stats["source:" + name] = added
    rows = [(entry, value[0], value[1]) for (entry, _), value in merged.items()]
    rows.sort(key=lambda row: (-row[2], len(row[0]), row[1], row[0]))
    stats["去重合并"] = sum(stats["source:" + name] for name, _ in sources) - len(rows)
    return rows


# --------------------------------------------------------------------------- #
# 负载与容器
# --------------------------------------------------------------------------- #

def build_payload(rows, with_weight=True):
    """行流：`词\t码[\t词频]`，UTF-8，\\n 分隔，结尾留一个换行。"""
    lines = []
    for text, code, weight in rows:
        lines.append("{}\t{}\t{}".format(text, code, weight) if with_weight
                     else "{}\t{}".format(text, code))
    return ("\n".join(lines) + "\n").encode("utf-8")


def build_container(payload, entry_count, kind=KIND_PINYIN, codec=CODEC_DEFLATE,
                    with_weight=True, canonical=True):
    """定长头 + 负载。压缩后反而更大时退回不压缩（头部 codec 如实记）。

    `canonical` 声明「行已规范化 + (词,码) 已去重」——本脚本产出的行流本就满足
    （词面 strip 过且不含空白、编码只用 a-z、去重按 (词,码) 建 dict）。读侧据此
    跳过逐行 trim 与去重集，载入百万级词库时这段开销不小。手写表别打这个标记。
    """
    if codec == CODEC_DEFLATE:
        # wbits=-15：raw deflate，不带 zlib 头尾（Apple COMPRESSION_ZLIB 认的就是这一种）
        packer = zlib.compressobj(9, zlib.DEFLATED, -15)
        stored = packer.compress(payload) + packer.flush()
        if len(stored) >= len(payload):
            codec, stored = CODEC_NONE, payload
    else:
        stored = payload
    flags = (FLAG_WEIGHT if with_weight else 0) | (FLAG_CANONICAL if canonical else 0)
    header = HEADER.pack(MAGIC, CONTAINER_VERSION, kind, codec,
                         flags,
                         entry_count, len(payload), len(stored),
                         zlib.crc32(stored) & 0xFFFFFFFF, 0)
    header += bytes(HEADER_SIZE - len(header))
    header = header[:36] + struct.pack(
        "<I", zlib.crc32(header) & 0xFFFFFFFF) + header[40:]
    return header + stored, codec


def verify_container(path):
    """逐项校验容器（magic / 版本 / 头 CRC / 负载 CRC / 长度 / 词条数），返回报告。"""
    with open(path, "rb") as handle:
        blob = handle.read()
    report = {"path": path, "size": len(blob), "problems": []}
    if len(blob) < HEADER_SIZE:
        report["problems"].append("文件小于 {} 字节头，不是 .hdict".format(HEADER_SIZE))
        return report
    header = blob[:HEADER_SIZE]
    magic, version, kind, codec, flags, count, size, stored_size, crc, crc_head = \
        HEADER.unpack_from(header)
    report.update(version=version, kind=kind, codec=codec, flags=flags,
                  entries=count, payload_size=size, stored_size=stored_size)
    problems = report["problems"]
    if magic != MAGIC:
        problems.append("magic {!r} 不是 {!r}".format(magic, MAGIC))
    if version != CONTAINER_VERSION:
        problems.append("容器版本 {} 不支持（本脚本写 {}）".format(
            version, CONTAINER_VERSION))
    zeroed = header[:36] + b"\0\0\0\0" + header[40:]
    if zlib.crc32(zeroed) & 0xFFFFFFFF != crc_head:
        problems.append("头部 CRC 不匹配（被截断或改过？）")
    body = blob[HEADER_SIZE:HEADER_SIZE + stored_size]
    if len(body) != stored_size:
        problems.append("负载实际 {} 字节 != 头部声明 {}".format(len(body), stored_size))
    if zlib.crc32(body) & 0xFFFFFFFF != crc:
        problems.append("负载 CRC 不匹配")
    if codec == CODEC_DEFLATE:
        plain = zlib.decompress(body, -15)
    elif codec == CODEC_NONE:
        plain = body
    else:
        problems.append("未知 codec {}".format(codec))
        return report
    if len(plain) != size:
        problems.append("解压后 {} 字节 != 头部声明 {}".format(len(plain), size))
    lines = [item for item in plain.decode("utf-8").split("\n") if item]
    data = [item for item in lines if not item.startswith("#")]
    columns = {len(item.split("\t")) for item in data[:50000]}
    report.update(lines=len(lines), data_lines=len(data), columns=sorted(columns),
                  head=data[0] if data else "", tail=data[-1] if data else "")
    if len(data) != count:
        problems.append("词条数 {} != 头部声明 {}".format(len(data), count))
    return report


# --------------------------------------------------------------------------- #

def parse_sources(spec):
    """`name.yaml[:minWeight],……` → [(name, minWeight)]"""
    sources = []
    for item in spec.split(","):
        name, _, weight = item.partition(":")
        sources.append((name.strip(), int(weight) if weight else 0))
    return sources


def main():
    global MAX_SYLLABLES
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tier", choices=sorted(TIERS), default="standard",
                        help="词库组合档位（默认 standard）")
    parser.add_argument("--sources",
                        help="自定义源清单 name.yaml[:minWeight],……，给出后忽略 --tier")
    parser.add_argument("--out", default=DEFAULT_OUT, help="输出 .hdict 路径")
    parser.add_argument("--plain", help="另外 dump 未打包的行流到该路径（排查用）")
    parser.add_argument("--no-compress", action="store_true", help="容器内不压缩")
    parser.add_argument("--no-weight", action="store_true", help="负载只写两列")
    parser.add_argument("--no-canonical-flag", action="store_true",
                        help="不声明「行已规范化且已去重」，让读侧按老表一样逐行校验")
    parser.add_argument("--verify", metavar="HDICT", help="只校验已有容器")
    parser.add_argument("--max-syllables", type=int, default=MAX_SYLLABLES,
                        help="单词最多几个音节（默认与引擎一致：8）")
    args = parser.parse_args()

    MAX_SYLLABLES = args.max_syllables

    if args.verify:
        report = verify_container(args.verify)
        print("{path}：v{version} kind={kind} codec={codec} flags={flags}".format(**report))
        print("  词条 {entries}　负载 {payload_size} 字节（容器内 {stored_size}）　"
              "文件大小 {size}".format(**report))
        print("  行数 {lines}　列数 {columns}　首行 {head!r}　末行 {tail!r}".format(**report))
        for problem in report["problems"]:
            print("  ✗ " + problem)
        return 1 if report["problems"] else 0

    sources = parse_sources(args.sources) if args.sources else TIERS[args.tier]
    valid = load_syllables()
    stats = Counter()
    rows = merge(sources, valid, stats)
    plain = build_payload(rows, with_weight=not args.no_weight)
    blob, codec = build_container(plain, len(rows),
                                  codec=CODEC_NONE if args.no_compress else CODEC_DEFLATE,
                                  with_weight=not args.no_weight,
                                  canonical=not args.no_canonical_flag)

    if args.plain:
        parent = os.path.dirname(os.path.abspath(args.plain))
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(args.plain, "wb") as handle:
            handle.write(plain)
    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(blob)

    label = "custom" if args.sources else args.tier
    print("档位 {:<9} 源：{}".format(label, ", ".join(
        "{}(词频≥{})".format(*item) for item in sources)))
    for name, _ in sources:
        print("  {:<20} 收录 {:>7}".format(name, stats.get("source:" + name, 0)))
    dropped = {key: value for key, value in stats.items()
               if ":" in key and not key.startswith("source:")}
    print("词条 {:,}　跨源去重 {:,}　低于准入词频 {:,}".format(
        len(rows), stats.get("去重合并", 0), stats.get("低于准入词频", 0)))
    if dropped:
        rare = sorted(dropped.items(), key=lambda item: -item[1])
        print("丢弃：", "，".join("{} {}".format(key, value) for key, value in rare[:8]))
    print("负载 {:,} B → {} {:,} B（{:,.1f}%）　{}".format(
        len(plain), "deflate" if codec == CODEC_DEFLATE else "原样", len(blob),
        100.0 * len(blob) / max(1, len(plain)), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
