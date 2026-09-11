#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
统一 Fire/Resources/schemas/ 下方案码表为「候选\t编码」格式。

原格式有三类（按行自动嗅探，逐行判定）：
  1. 编码[空格]候选一[空格]候选二……   —— 行首为 ASCII 编码，行内空格分词多个候选
  2. 候选[空格]编码                     —— 行尾为 ASCII 编码，行首为单个候选
  3. 候选\t编码                        —— 已是目标格式

规则：
  - 文件头三行（# 开头：#name= / #describe= / #author=）原样保留；
    任意 # 注释行与空行也原样保留（运行时统一跳过）。
  - 数据行按"ASCII 侧即编码"判定方向，统一输出 `候选\t编码`；
    格式 1 的一行多候选拆成多行（保持原有候选序 = rank 序）。
  - 行尾游离的纯数字 token（旧数据里个别行的频率值）丢弃并告警。
  - 两侧都是 ASCII、或都无 ASCII 的行无法判定方向：报错退出，人工处理。

用法：
  python3 scripts/normalize_schemas.py            # 原地转换 schemas 目录
  python3 scripts/normalize_schemas.py --check    # 只检查不改写
"""
import os
import re
import sys

SCHEMAS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Fire", "Resources", "schemas",
)

# 编码由 ASCII 可见字符组成（小写字母为主，个别表带数字/撇号，如 ear2、bi'an）
CODE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9'\-`]*$")
DIGITS_RE = re.compile(r"^[0-9]+$")


def normalize_line(line):
    """返回转换后的若干行（保持顺序）；None 表示原样保留（注释/空行）。"""
    if not line.strip() or line.lstrip().startswith("#"):
        return None  # 保留原行

    if "\t" in line:
        parts = [p for p in line.split("\t") if p.strip()]
        if len(parts) == 2:
            text, code = parts[0].strip(), parts[1].strip()
            if CODE_RE.match(code) and not CODE_RE.match(text):
                return ["{}\t{}".format(text, code)]  # 已是目标格式
    # 空格/混合分隔：先拆 token 再判定方向
    tokens = [t for t in re.split(r"[ \t]+", line) if t]
    if not tokens:
        return None
    # 行尾游离的纯数字（旧数据残留频率值）：丢弃并告警
    if DIGITS_RE.match(tokens[-1]) and len(tokens) >= 2:
        sys.stderr.write("[warn] 丢弃行尾游离数字: {!r}\n".format(line))
        tokens = tokens[:-1]
    if len(tokens) < 2:
        raise ValueError("无法解析的行: {!r}".format(line))
    head_code = bool(CODE_RE.match(tokens[0]))
    tail_code = bool(CODE_RE.match(tokens[-1]))
    if head_code and not tail_code:
        # 编码 候选1 候选2 …… → 拆行
        code = tokens[0]
        return ["{}\t{}".format(c, code) for c in tokens[1:]]
    if tail_code and not head_code:
        # 候选 编码（候选可能含空格？原表候选间以空格分隔，故此处即单候选）
        if len(tokens) != 2:
            raise ValueError("无法解析的行: {!r}".format(line))
        return ["{}\t{}".format(tokens[0], tokens[1])]
    raise ValueError("无法判定方向的行: {!r}".format(line))


def normalize_file(path, check_only=False):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    out = []
    changed = 0
    for line in lines:
        conv = normalize_line(line.rstrip("\r"))
        if conv is None:
            out.append(line)
        else:
            if [line] != conv:
                changed += 1
            out.extend(conv)
    new_content = "\n".join(out)
    old_content = "\n".join(lines)
    if new_content != old_content and not check_only:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
    return changed


def main():
    check_only = "--check" in sys.argv
    exts = (".txt", ".yaml", ".yml", ".toml", ".conf")
    total = 0
    for fn in sorted(os.listdir(SCHEMAS_DIR)):
        path = os.path.join(SCHEMAS_DIR, fn)
        if not os.path.isfile(path) or not fn.lower().endswith(exts):
            continue
        changed = normalize_file(path, check_only)
        total += changed
        print("{}: {} 行需转换{}".format(fn, changed, "（--check）" if check_only else ""))
    print("共", total, "行", "待转换" if check_only else "已统一为 候选\\t编码")


if __name__ == "__main__":
    main()
