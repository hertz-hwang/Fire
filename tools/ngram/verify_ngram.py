#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_ngram.py

按 Fire/Sentence/NgramModel.swift 的查询逻辑模拟 TCSKNM02。

功能：
1. 全量模型结构检查
2. 单句 probe
3. 独立语料评估
4. 自动从任意文本中提取连续 Han/CJK 字符片段进行评估

示例：

    python3 tools/ngram/verify_ngram.py \
        --model sentence-ngram-mobile.bin \
        --full

    python3 tools/ngram/verify_ngram.py \
        --model sentence-ngram-mobile.bin \
        --probe 今天天气很好

    python3 tools/ngram/verify_ngram.py \
        --model sentence-ngram-mobile.bin \
        --eval evaluation.txt

    python3 tools/ngram/verify_ngram.py \
        --model sentence-ngram-mobile.bin \
        --eval evaluation.txt \
        --eval-limit 10000

    python3 tools/ngram/verify_ngram.py \
        --model sentence-ngram-mobile.bin \
        --eval evaluation.txt \
        --min-chars 2 \
        --details

评估切分规则：

    连续 Han/CJK 字符 -> 一个独立 sequence

其他字符全部作为边界，包括：

    - 英文
    - 数字
    - 标点
    - 空格 / TAB / 换行
    - emoji
    - 其他 Unicode 字符

例如：

    今天天气很好，我去Apple Store买了2台手机。

切分为：

    今天天气很好
    我去
    买了
    台手机

每个 sequence 自动变为：

    BOS BOS chars EOS

BOS = 0x02
EOS = 0x03
字符 ID = Unicode code point，即 ord(c)

注意：
PPL 的 prediction 数包含 EOS。

模型为插值模型：

    P1 = unigram
    P2 = succ2 + lambda2 * P1
    P3 = succ3 + lambda3 * P2

tri/bi successor hit 表示 successor 表中是否存在 target，
不是硬 backoff 意义上的最终使用阶数。
"""

import argparse
import math
import os
import struct
import sys
import time
from dataclasses import dataclass


MAGIC = b"TCSKNM02"
SHIFT = 1 << 21

BOS = 0x02
EOS = 0x03


@dataclass
class EvalStats:
    sentences: int = 0

    # 模型 prediction 数。
    # 每个 sequence = Han chars + EOS。
    chars: int = 0

    # 实际输入模型的 Han 字符数，不包含 EOS。
    han_chars: int = 0

    total_logp_uni: float = 0.0
    total_logp_bi: float = 0.0
    total_logp_tri: float = 0.0

    tri_ctx_hit: int = 0
    bi_ctx_hit: int = 0

    tri_succ_hit: int = 0
    bi_succ_hit: int = 0

    unigram_exact: int = 0
    unknown: int = 0

    invalid_uni: int = 0
    invalid_bi: int = 0
    invalid_tri: int = 0

    def add(self, other):
        for name in self.__dataclass_fields__:
            setattr(
                self,
                name,
                getattr(self, name) + getattr(other, name),
            )


@dataclass
class SegmentStats:
    # 从文件中读取到的 Unicode code point 数。
    input_chars: int = 0

    # 判定为 Han/CJK 的字符数。
    han_chars: int = 0

    # 作为边界丢弃的字符数。
    separators: int = 0

    # 找到的连续 Han 片段数，包括因 min_chars 被跳过的。
    raw_segments: int = 0

    # 因长度过短被跳过的片段数。
    short_segments: int = 0

    # 被跳过片段包含的 Han 字符。
    short_chars: int = 0


class Reader:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()

        d = self.data

        if len(d) < 104:
            raise ValueError(f"文件过小: {len(d)} bytes")

        if d[:8] != MAGIC:
            raise ValueError(
                f"magic 不匹配: expected={MAGIC!r}, got={d[:8]!r}"
            )

        u = lambda fmt, off: struct.unpack_from("<" + fmt, d, off)[0]

        self.version = u("I", 8)
        self.header_size = u("I", 12)
        self.total_size = u("Q", 16)

        if self.version != 1:
            raise ValueError(
                f"unsupported version: {self.version}"
            )

        if self.header_size != 104:
            raise ValueError(
                f"unsupported headerSize: {self.header_size}"
            )

        if self.total_size != len(d):
            raise ValueError(
                f"size mismatch: header declares {self.total_size}, "
                f"actual {len(d)}"
            )

        self.stride = u("I", 24)

        self.uni_cnt = u("I", 32)
        self.uni_off = u("Q", 40)

        self.bi_ctx = u("I", 48)
        self.bi_idx = u("I", 52)
        self.bi_blocks = u("Q", 56)
        self.bi_index_off = u("Q", 64)

        self.tri_ctx = u("I", 72)
        self.tri_idx = u("I", 80)
        self.tri_blocks = u("Q", 88)
        self.tri_index_off = u("Q", 96)

        if self.stride < 16:
            raise ValueError(
                f"invalid stride: {self.stride}"
            )

        if not (
            self.bi_blocks < self.bi_index_off
            < self.tri_blocks < self.tri_index_off
        ):
            raise ValueError(
                f"invalid layout: "
                f"biBlocks={self.bi_blocks} "
                f"biIndexOff={self.bi_index_off} "
                f"triBlocks={self.tri_blocks} "
                f"triIndexOff={self.tri_index_off}"
            )

        if (
            self.uni_off + self.uni_cnt * 8
            > self.bi_blocks
        ):
            raise ValueError(
                "section overflow: unigrams"
            )

        if (
            self.bi_index_off + self.bi_idx * 16
            > self.tri_blocks
        ):
            raise ValueError(
                "section overflow: bi index"
            )

        if (
            self.tri_index_off + self.tri_idx * 16
            > len(d)
        ):
            raise ValueError(
                "section overflow: tri index"
            )

        if self.uni_off < self.header_size:
            raise ValueError(
                f"uni_off {self.uni_off} "
                f"< header_size {self.header_size}"
            )

        if self.uni_cnt == 0:
            raise ValueError("empty unigram table")

        self.unknown = self._uni_at(0)

        self.bi_index = self._load_index(
            self.bi_index_off,
            self.bi_idx,
            "bi",
        )

        self.tri_index = self._load_index(
            self.tri_index_off,
            self.tri_idx,
            "tri",
        )

    def _load_index(self, off, cnt, label):
        d = self.data
        need = off + cnt * 16

        if need > len(d):
            raise ValueError(
                f"{label} index 越界: "
                f"off={off}, cnt={cnt}, file={len(d)}"
            )

        result = []
        prev_key = -1

        for i in range(cnt):
            key, pos = struct.unpack_from(
                "<QQ",
                d,
                off + i * 16,
            )

            if key <= prev_key:
                raise ValueError(
                    f"{label} index key 非严格升序 @{i}: "
                    f"{key} <= {prev_key}"
                )

            result.append((key, pos))
            prev_key = key

        return result

    def _uni_at(self, i):
        return struct.unpack_from(
            "<f",
            self.data,
            self.uni_off + i * 8 + 4,
        )[0]

    def unigram_exact(self, key):
        lo = 0
        hi = self.uni_cnt
        d = self.data

        while lo < hi:
            m = (lo + hi) // 2

            k = struct.unpack_from(
                "<I",
                d,
                self.uni_off + m * 8,
            )[0]

            if k < key:
                lo = m + 1
            else:
                hi = m

        if lo < self.uni_cnt:
            k = struct.unpack_from(
                "<I",
                d,
                self.uni_off + lo * 8,
            )[0]

            if k == key:
                return self._uni_at(lo), True

        return self.unknown, False

    def unigram(self, key):
        return self.unigram_exact(key)[0]

    @staticmethod
    def _find_page(index, key):
        lo = 0
        hi = len(index)

        while lo < hi:
            m = (lo + hi) // 2

            if index[m][0] <= key:
                lo = m + 1
            else:
                hi = m

        return lo - 1

    def _ctx(self, tri, key):
        d = self.data

        if tri:
            index = self.tri_index
            end = self.tri_index_off
            stride = self.stride
            cnt = self.tri_ctx
        else:
            index = self.bi_index
            end = self.bi_index_off
            stride = self.stride
            cnt = self.bi_ctx

        if not index:
            return None

        page = self._find_page(index, key)

        if page < 0:
            return None

        pos = index[page][1]

        page_end = (
            index[page + 1][1]
            if page + 1 < len(index)
            else end
        )

        remaining = cnt - page * stride

        if remaining <= 0:
            return None

        max_scan = min(stride, remaining)
        scanned = 0

        while scanned < max_scan:
            if pos + 16 > page_end:
                break

            ck = struct.unpack_from(
                "<Q",
                d,
                pos,
            )[0]

            if ck == key:
                lam = struct.unpack_from(
                    "<f",
                    d,
                    pos + 8,
                )[0]

                sc = struct.unpack_from(
                    "<I",
                    d,
                    pos + 12,
                )[0]

                sp = pos + 16

                if sp + sc * 8 <= page_end:
                    return lam, sp, sc

                return None

            if ck > key:
                break

            sc = struct.unpack_from(
                "<I",
                d,
                pos + 12,
            )[0]

            pos += 16 + sc * 8
            scanned += 1

        return None

    def _succ_value(self, entry, target):
        if not entry:
            return 0.0, False

        _lam, off, cnt = entry
        d = self.data

        lo = 0
        hi = cnt

        while lo < hi:
            m = (lo + hi) // 2

            k = struct.unpack_from(
                "<I",
                d,
                off + m * 8,
            )[0]

            if k < target:
                lo = m + 1
            else:
                hi = m

        if lo < cnt:
            k = struct.unpack_from(
                "<I",
                d,
                off + lo * 8,
            )[0]

            if k == target:
                p = struct.unpack_from(
                    "<f",
                    d,
                    off + lo * 8 + 4,
                )[0]

                return p, True

        return 0.0, False

    def _succ(self, entry, target):
        return self._succ_value(
            entry,
            target,
        )[0]

    @staticmethod
    def _safe_log(p):
        return math.log(
            max(p, 1e-300)
        )

    @staticmethod
    def _valid_probability(p):
        return (
            math.isfinite(p)
            and p >= 0.0
        )

    def probabilities(
        self,
        prev2,
        prev1,
        target,
    ):
        uni, uni_exact = self.unigram_exact(
            target
        )

        bi = self._ctx(
            False,
            prev1,
        )

        bi_succ, bi_succ_hit = (
            self._succ_value(
                bi,
                target,
            )
        )

        if bi:
            bi_p = (
                bi_succ
                + bi[0] * uni
            )
        else:
            bi_p = uni

        tri_key = (
            prev2 * SHIFT
            + prev1 % SHIFT
        )

        tri = self._ctx(
            True,
            tri_key,
        )

        tri_succ, tri_succ_hit = (
            self._succ_value(
                tri,
                target,
            )
        )

        if tri:
            tri_p = (
                tri_succ
                + tri[0] * bi_p
            )
        else:
            tri_p = bi_p

        return {
            "uni": uni,
            "bi": bi_p,
            "tri": tri_p,

            "uni_exact": uni_exact,

            "bi_ctx_hit": bi is not None,
            "tri_ctx_hit": tri is not None,

            "bi_succ_hit": bi_succ_hit,
            "tri_succ_hit": tri_succ_hit,

            "bi_lambda": (
                bi[0]
                if bi
                else None
            ),

            "tri_lambda": (
                tri[0]
                if tri
                else None
            ),

            "bi_succ": bi_succ,
            "tri_succ": tri_succ,
        }

    def logp(
        self,
        prev2,
        prev1,
        target,
    ):
        p = self.probabilities(
            prev2,
            prev1,
            target,
        )["tri"]

        return self._safe_log(p)

    def score_sequence(
        self,
        text,
        collect_rows=True,
    ):
        """
        对一个已经切分好的连续 Han sequence 打分。

        predictions = Han chars + EOS
        BOS 不参与预测。
        """
        stats = EvalStats(
            sentences=1,
            han_chars=len(text),
        )

        rows = [] if collect_rows else None

        # 不构造完整 seq list，降低 corpus eval 的临时内存。
        prev2 = BOS
        prev1 = BOS

        for ch in text:
            target = ord(ch)

            info = self.probabilities(
                prev2,
                prev1,
                target,
            )

            self._add_prediction(
                stats,
                info,
            )

            if collect_rows:
                rows.append(
                    (
                        prev2,
                        prev1,
                        target,
                        info,
                    )
                )

            prev2 = prev1
            prev1 = target

        # EOS 也是一次 prediction。
        target = EOS

        info = self.probabilities(
            prev2,
            prev1,
            target,
        )

        self._add_prediction(
            stats,
            info,
        )

        if collect_rows:
            rows.append(
                (
                    prev2,
                    prev1,
                    target,
                    info,
                )
            )

        return stats, rows

    def _add_prediction(
        self,
        stats,
        info,
    ):
        p1 = info["uni"]
        p2 = info["bi"]
        p3 = info["tri"]

        stats.chars += 1

        if info["uni_exact"]:
            stats.unigram_exact += 1
        else:
            stats.unknown += 1

        if info["bi_ctx_hit"]:
            stats.bi_ctx_hit += 1

        if info["tri_ctx_hit"]:
            stats.tri_ctx_hit += 1

        if info["bi_succ_hit"]:
            stats.bi_succ_hit += 1

        if info["tri_succ_hit"]:
            stats.tri_succ_hit += 1

        if not self._valid_probability(p1):
            stats.invalid_uni += 1

        if not self._valid_probability(p2):
            stats.invalid_bi += 1

        if not self._valid_probability(p3):
            stats.invalid_tri += 1

        stats.total_logp_uni += (
            self._safe_log(p1)
        )

        stats.total_logp_bi += (
            self._safe_log(p2)
        )

        stats.total_logp_tri += (
            self._safe_log(p3)
        )

    def full_scan(self):
        d = self.data
        errs = []

        # ---------- unigram ----------

        prev = -1
        s = 0.0

        for i in range(self.uni_cnt):
            off = (
                self.uni_off
                + i * 8
            )

            if off + 8 > len(d):
                errs.append(
                    f"uni 越界 @{i}"
                )
                break

            k, p = struct.unpack_from(
                "<If",
                d,
                off,
            )

            if k <= prev:
                errs.append(
                    f"uni key 非升序 @{i}"
                )
                break

            if (
                not math.isfinite(p)
                or p < 0
            ):
                errs.append(
                    f"uni probability 非法 @{i}: {p}"
                )
                break

            prev = k
            s += p

        if abs(s - 1.0) > 0.02:
            errs.append(
                f"unigram Σ={s}"
            )

        # ---------- contexts ----------

        def walk(
            blocks_off,
            index_off,
            ctx_cnt,
            idx_cnt,
            label,
        ):
            prev_ctx = -1
            n = 0
            p = blocks_off
            page = 0

            if blocks_off > index_off:
                errs.append(
                    f"{label} blocks_off > index_off: "
                    f"{blocks_off}>{index_off}"
                )
                return

            while (
                p + 16 <= index_off
                and n < ctx_cnt
            ):
                k = struct.unpack_from(
                    "<Q",
                    d,
                    p,
                )[0]

                lam = struct.unpack_from(
                    "<f",
                    d,
                    p + 8,
                )[0]

                cnt = struct.unpack_from(
                    "<I",
                    d,
                    p + 12,
                )[0]

                if k <= prev_ctx:
                    errs.append(
                        f"{label} ctx 非升序 @{n}"
                    )
                    return

                if (
                    not math.isfinite(lam)
                    or not (
                        0
                        <= lam
                        <= 1.0 + 1e-6
                    )
                ):
                    errs.append(
                        f"{label} λ={lam} @{n}"
                    )
                    return

                rec_end = (
                    p
                    + 16
                    + cnt * 8
                )

                if rec_end > index_off:
                    errs.append(
                        f"{label} 记录越界 @{n}"
                    )
                    return

                prev_target = -1

                for j in range(cnt):
                    t, pr = struct.unpack_from(
                        "<If",
                        d,
                        p + 16 + j * 8,
                    )

                    if t <= prev_target:
                        errs.append(
                            f"{label} 后继非升序 "
                            f"ctx={hex(k)}"
                        )
                        return

                    if (
                        not math.isfinite(pr)
                        or pr < 0
                        or pr > 1.0 + 1e-6
                    ):
                        errs.append(
                            f"{label} successor probability "
                            f"非法 ctx={hex(k)} "
                            f"target={hex(t)} "
                            f"p={pr}"
                        )
                        return

                    prev_target = t

                prev_ctx = k
                n += 1
                p = rec_end

                if n % self.stride == 0:
                    page += 1

                    if page < idx_cnt:
                        idx_entry = (
                            index_off
                            + page * 16
                        )

                        if (
                            idx_entry + 16
                            > len(d)
                        ):
                            errs.append(
                                f"{label} index 越界 "
                                f"page={page}"
                            )
                            return

                        exp = struct.unpack_from(
                            "<Q",
                            d,
                            idx_entry + 8,
                        )[0]

                        if p != exp:
                            errs.append(
                                f"{label} 页 {page} "
                                f"边界 {p}!={exp}"
                            )
                            return

            if n != ctx_cnt:
                errs.append(
                    f"{label} 记录数 "
                    f"{n}!={ctx_cnt}"
                )

            elif p != index_off:
                errs.append(
                    f"{label} 区块尾部 "
                    f"{p}!={index_off}"
                )

        walk(
            self.bi_blocks,
            self.bi_index_off,
            self.bi_ctx,
            self.bi_idx,
            "bi",
        )

        walk(
            self.tri_blocks,
            self.tri_index_off,
            self.tri_ctx,
            self.tri_idx,
            "tri",
        )

        return errs


# ------------------------------------------------------------
# Unicode / segmentation
# ------------------------------------------------------------

def is_han_char(ch):
    """
    判断 Unicode code point 是否属于主要 Han/CJK ideograph 区域。

    包含：
    - CJK Unified Ideographs
    - Extension A
    - Extension B-I
    - Compatibility Ideographs

    不包含中文标点，因此标点自然成为 sequence 边界。
    """
    cp = ord(ch)

    return (
        0x3400 <= cp <= 0x4DBF
        or 0x4E00 <= cp <= 0x9FFF
        or 0xF900 <= cp <= 0xFAFF
        or 0x20000 <= cp <= 0x2A6DF
        or 0x2A700 <= cp <= 0x2B73F
        or 0x2B740 <= cp <= 0x2B81F
        or 0x2B820 <= cp <= 0x2CEAF
        or 0x2CEB0 <= cp <= 0x2EBEF
        or 0x2EBF0 <= cp <= 0x2EE5F
        or 0x30000 <= cp <= 0x3134F
        or 0x31350 <= cp <= 0x3347F
    )


def iter_han_segments(
    file_obj,
    segment_stats,
    chunk_size=1024 * 1024,
):
    """
    从整个文本流中提取连续 Han/CJK 字符片段。

    不依赖换行。

    英文、数字、空格、标点、emoji 等任何非 Han 字符
    都会结束当前片段。

    chunk 边界不会人为截断中文片段。
    """
    buf = []

    while True:
        chunk = file_obj.read(chunk_size)

        if not chunk:
            break

        for ch in chunk:
            segment_stats.input_chars += 1

            if is_han_char(ch):
                segment_stats.han_chars += 1
                buf.append(ch)
                continue

            segment_stats.separators += 1

            if buf:
                segment_stats.raw_segments += 1
                yield "".join(buf)
                buf.clear()

    if buf:
        segment_stats.raw_segments += 1
        yield "".join(buf)


# ------------------------------------------------------------
# Output
# ------------------------------------------------------------

def display_char(cp):
    if cp == BOS:
        return "<BOS>"

    if cp == EOS:
        return "<EOS>"

    try:
        ch = chr(cp)
    except ValueError:
        return f"<U+{cp:04X}>"

    if ch == "\t":
        return "\\t"

    if ch == "\n":
        return "\\n"

    if ch == "\r":
        return "\\r"

    if ch.isspace():
        return repr(ch)

    return ch


def pct(n, d):
    if d == 0:
        return 0.0

    return (
        n * 100.0 / d
    )


def perplexity(
    total_logp,
    count,
):
    if count == 0:
        return float("nan")

    nll = (
        -total_logp
        / count
    )

    if nll > 700:
        return float("inf")

    return math.exp(nll)


def print_stats(
    stats,
    segment_stats=None,
    elapsed=None,
    details=False,
):
    n = stats.chars

    if n == 0:
        print(
            "没有可评估的中文 sequence。"
        )
        return

    avg_uni = (
        stats.total_logp_uni
        / n
    )

    avg_bi = (
        stats.total_logp_bi
        / n
    )

    avg_tri = (
        stats.total_logp_tri
        / n
    )

    ppl_uni = perplexity(
        stats.total_logp_uni,
        n,
    )

    ppl_bi = perplexity(
        stats.total_logp_bi,
        n,
    )

    ppl_tri = perplexity(
        stats.total_logp_tri,
        n,
    )

    print()
    print("=== Corpus evaluation ===")

    print(
        f"sequences             : "
        f"{stats.sentences:,}"
    )

    print(
        f"han chars             : "
        f"{stats.han_chars:,}"
    )

    print(
        f"EOS predictions       : "
        f"{stats.sentences:,}"
    )

    print(
        f"total predictions     : "
        f"{stats.chars:,}"
    )

    if segment_stats is not None:
        print(
            f"input chars           : "
            f"{segment_stats.input_chars:,}"
        )

        print(
            f"separator chars       : "
            f"{segment_stats.separators:,}"
        )

        print(
            f"raw Han segments      : "
            f"{segment_stats.raw_segments:,}"
        )

        if segment_stats.short_segments:
            print(
                f"short segments skipped: "
                f"{segment_stats.short_segments:,} "
                f"({segment_stats.short_chars:,} chars)"
            )

    if elapsed is not None:
        print(
            f"elapsed               : "
            f"{elapsed:.2f}s"
        )

        if elapsed > 0:
            print(
                f"speed                 : "
                f"{stats.chars / elapsed:,.0f} pred/s"
            )

    print()

    print(
        "unigram               : "
        f"logP={stats.total_logp_uni:.3f}  "
        f"avg={avg_uni:.6f}  "
        f"NLL={-avg_uni:.6f}  "
        f"PPL={ppl_uni:.4f}"
    )

    print(
        "bigram                : "
        f"logP={stats.total_logp_bi:.3f}  "
        f"avg={avg_bi:.6f}  "
        f"NLL={-avg_bi:.6f}  "
        f"PPL={ppl_bi:.4f}"
    )

    print(
        "trigram               : "
        f"logP={stats.total_logp_tri:.3f}  "
        f"avg={avg_tri:.6f}  "
        f"NLL={-avg_tri:.6f}  "
        f"PPL={ppl_tri:.4f}"
    )

    print()

    print(
        f"trigram successor hit : "
        f"{stats.tri_succ_hit:,}/{n:,} "
        f"({pct(stats.tri_succ_hit, n):.2f}%)"
    )

    print(
        f"bigram successor hit  : "
        f"{stats.bi_succ_hit:,}/{n:,} "
        f"({pct(stats.bi_succ_hit, n):.2f}%)"
    )

    print(
        f"unigram exact hit     : "
        f"{stats.unigram_exact:,}/{n:,} "
        f"({pct(stats.unigram_exact, n):.2f}%)"
    )

    print(
        f"unknown/OOV           : "
        f"{stats.unknown:,}/{n:,} "
        f"({pct(stats.unknown, n):.4f}%)"
    )

    if details:
        print()

        print(
            f"trigram context hit   : "
            f"{stats.tri_ctx_hit:,}/{n:,} "
            f"({pct(stats.tri_ctx_hit, n):.2f}%)"
        )

        print(
            f"bigram context hit    : "
            f"{stats.bi_ctx_hit:,}/{n:,} "
            f"({pct(stats.bi_ctx_hit, n):.2f}%)"
        )

        tri_given_ctx = (
            pct(
                stats.tri_succ_hit,
                stats.tri_ctx_hit,
            )
            if stats.tri_ctx_hit
            else 0.0
        )

        bi_given_ctx = (
            pct(
                stats.bi_succ_hit,
                stats.bi_ctx_hit,
            )
            if stats.bi_ctx_hit
            else 0.0
        )

        print(
            f"tri succ | ctx        : "
            f"{tri_given_ctx:.2f}%"
        )

        print(
            f"bi succ | ctx         : "
            f"{bi_given_ctx:.2f}%"
        )

        if stats.sentences:
            avg_len = (
                stats.han_chars
                / stats.sentences
            )

            print(
                f"avg sequence length   : "
                f"{avg_len:.2f} Han chars"
            )

    print()

    print(
        "invalid probability   : "
        f"uni={stats.invalid_uni:,} "
        f"bi={stats.invalid_bi:,} "
        f"tri={stats.invalid_tri:,}"
    )

    if (
        math.isfinite(ppl_uni)
        and ppl_uni > 0
    ):
        bi_gain = (
            (
                ppl_uni - ppl_bi
            )
            / ppl_uni
            * 100
            if math.isfinite(ppl_bi)
            else float("nan")
        )

        print(
            f"bigram vs unigram PPL : "
            f"{bi_gain:+.2f}% reduction"
        )

    if (
        math.isfinite(ppl_bi)
        and ppl_bi > 0
    ):
        tri_gain = (
            (
                ppl_bi - ppl_tri
            )
            / ppl_bi
            * 100
            if math.isfinite(ppl_tri)
            else float("nan")
        )

        print(
            f"trigram vs bigram PPL : "
            f"{tri_gain:+.2f}% reduction"
        )


# ------------------------------------------------------------
# Evaluation
# ------------------------------------------------------------

def evaluate_file(
    reader,
    path,
    limit=0,
    progress=0,
    min_chars=1,
):
    """
    自动扫描整个文件，不依赖人工换行。

    连续 Han/CJK 字符构成一个 sequence。
    任何非 Han 字符作为边界。

    limit:
        限制实际参与评估的 sequence 数。

    min_chars:
        小于该长度的 Han sequence 不参与评估。
    """
    stats = EvalStats()
    seg_stats = SegmentStats()

    started = time.monotonic()

    with open(
        path,
        "r",
        encoding="utf-8",
        errors="strict",
    ) as f:
        for text in iter_han_segments(
            f,
            seg_stats,
        ):
            if len(text) < min_chars:
                seg_stats.short_segments += 1
                seg_stats.short_chars += len(text)
                continue

            sentence_stats, _ = (
                reader.score_sequence(
                    text,
                    collect_rows=False,
                )
            )

            stats.add(
                sentence_stats
            )

            if (
                progress > 0
                and stats.sentences % progress == 0
            ):
                elapsed = (
                    time.monotonic()
                    - started
                )

                rate = (
                    stats.chars / elapsed
                    if elapsed > 0
                    else 0.0
                )

                print(
                    f"\rprocessed "
                    f"{stats.sentences:,} sequences, "
                    f"{stats.han_chars:,} Han chars, "
                    f"{stats.chars:,} predictions, "
                    f"{rate:,.0f} pred/s",
                    end="",
                    file=sys.stderr,
                    flush=True,
                )

            if (
                limit > 0
                and stats.sentences >= limit
            ):
                break

    elapsed = (
        time.monotonic()
        - started
    )

    if progress > 0:
        print(
            file=sys.stderr
        )

    return (
        stats,
        seg_stats,
        elapsed,
    )


def run_probe(
    reader,
    text,
    details=False,
):
    stats, rows = (
        reader.score_sequence(
            text,
            collect_rows=True,
        )
    )

    print()
    print(
        f"probe: {text!r}"
    )

    for (
        _prev2,
        _prev1,
        target,
        info,
    ) in rows:

        p1 = info["uni"]
        p2 = info["bi"]
        p3 = info["tri"]

        lp = Reader._safe_log(
            p3
        )

        if info["tri_succ_hit"]:
            hit = "T"
        elif info["bi_succ_hit"]:
            hit = "B"
        elif info["uni_exact"]:
            hit = "U"
        else:
            hit = "UNK"

        extra = ""

        if details:
            extra = (
                f"  p1={p1:.8g}"
                f" p2={p2:.8g}"
                f" p3={p3:.8g}"
                f" ctx3="
                f"{'Y' if info['tri_ctx_hit'] else 'N'}"
                f" ctx2="
                f"{'Y' if info['bi_ctx_hit'] else 'N'}"
            )

        print(
            f"  {display_char(target)}: "
            f"logp={lp:.4f} "
            f"[{hit}]"
            f"{extra}"
        )

    n = stats.chars

    if n:
        avg = (
            stats.total_logp_tri
            / n
        )

        ppl = perplexity(
            stats.total_logp_tri,
            n,
        )

        print(
            f"  句 logP="
            f"{stats.total_logp_tri:.3f}  "
            f"每预测均分={avg:.3f}  "
            f"PPL={ppl:.3f}"
        )


# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description=(
            "验证并评估 TCSKNM02 "
            "character n-gram model"
        )
    )

    ap.add_argument(
        "--model",
        required=True,
        help="TCSKNM02 模型路径",
    )

    ap.add_argument(
        "--full",
        action="store_true",
        help="全量结构扫描",
    )

    ap.add_argument(
        "--probe",
        default="",
        help="对单句话逐字符打印 logP",
    )

    ap.add_argument(
        "--eval",
        dest="eval_path",
        default="",
        help=(
            "独立测试文本；"
            "自动提取连续 Han/CJK 字符片段"
        ),
    )

    ap.add_argument(
        "--eval-limit",
        type=int,
        default=0,
        help=(
            "最多评估多少个切分后的 "
            "Han sequence；0=全部"
        ),
    )

    ap.add_argument(
        "--min-chars",
        type=int,
        default=1,
        help=(
            "参与 eval 的最短 Han sequence "
            "长度；默认 1"
        ),
    )

    ap.add_argument(
        "--progress",
        type=int,
        default=10000,
        help=(
            "eval 每 N 个 sequence "
            "在 stderr 输出进度；"
            "0=关闭，默认 10000"
        ),
    )

    ap.add_argument(
        "--details",
        action="store_true",
        help=(
            "输出更多 context/hit "
            "和切分诊断信息"
        ),
    )

    args = ap.parse_args()

    if args.eval_limit < 0:
        ap.error(
            "--eval-limit 不能小于 0"
        )

    if args.progress < 0:
        ap.error(
            "--progress 不能小于 0"
        )

    if args.min_chars < 1:
        ap.error(
            "--min-chars 必须 >= 1"
        )

    if not os.path.isfile(
        args.model
    ):
        print(
            f"模型不存在: {args.model}",
            file=sys.stderr,
        )
        sys.exit(2)

    try:
        r = Reader(
            args.model
        )
    except (
        OSError,
        ValueError,
        struct.error,
        AssertionError,
    ) as e:
        print(
            f"加载模型失败: {e}",
            file=sys.stderr,
        )
        sys.exit(2)

    print(
        f"model: "
        f"uni={r.uni_cnt:,} "
        f"bi_ctx={r.bi_ctx:,} "
        f"tri_ctx={r.tri_ctx:,} "
        f"stride={r.stride:,} "
        f"size="
        f"{len(r.data) / 1048576:.1f}MB"
    )

    if args.full:
        started = (
            time.monotonic()
        )

        errs = r.full_scan()

        elapsed = (
            time.monotonic()
            - started
        )

        if errs:
            print(
                f"full scan: FAILED "
                f"({elapsed:.2f}s)"
            )

            for e in errs[:20]:
                print(
                    f"  - {e}"
                )

            if len(errs) > 20:
                print(
                    f"  ... 还有 "
                    f"{len(errs) - 20} 个错误"
                )

            sys.exit(1)

        print(
            f"full scan: OK "
            f"({elapsed:.2f}s)"
        )

    if args.probe:
        run_probe(
            r,
            args.probe,
            details=args.details,
        )

    if args.eval_path:
        if not os.path.isfile(
            args.eval_path
        ):
            print(
                f"测试集不存在: "
                f"{args.eval_path}",
                file=sys.stderr,
            )
            sys.exit(2)

        try:
            (
                stats,
                seg_stats,
                elapsed,
            ) = evaluate_file(
                r,
                args.eval_path,
                limit=args.eval_limit,
                progress=args.progress,
                min_chars=args.min_chars,
            )

        except UnicodeDecodeError as e:
            print(
                f"测试集不是合法 UTF-8: {e}",
                file=sys.stderr,
            )
            sys.exit(2)

        except OSError as e:
            print(
                f"读取测试集失败: {e}",
                file=sys.stderr,
            )
            sys.exit(2)

        print_stats(
            stats,
            segment_stats=seg_stats,
            elapsed=elapsed,
            details=args.details,
        )

        if (
            stats.invalid_uni
            or stats.invalid_bi
            or stats.invalid_tri
        ):
            sys.exit(1)

    if (
        not args.full
        and not args.probe
        and not args.eval_path
    ):
        print(
            "没有指定操作；"
            "使用 --full、--probe 或 --eval。"
        )


if __name__ == "__main__":
    main()
