# tools/ngram — 训练 Fire 的整句 n-gram 模型

`Fire/Resources/sentence-ngram-mobile.bin` 是一个**字级（character-level）三级插值
n-gram 语言模型**，私有 `TCSKNM02` 分页格式。它只负责"给定前两个字，下一个字是什么
的概率"；候选词图来自 `sentence-codes-liuli.txt`（编码表），排序端在
`Fire/Sentence/SentenceDecoder.swift` 里用 `NgramModel.logp(prev2, prev1, target)`
对词图边打分。

## 快速开始

```bash
# 1. 语料：直接把 .txt 丢进一个文件夹（可嵌套子目录，文件名不限）。
#    无需人工分句——英文/数字/标点/空格一律作为分句边界自动切分；
#    UTF-8 和 GBK/GB18030 编码自动识别；非 .txt 文件忽略。
#    可用来源：维基百科转储、THUCNews、小说、语录、古籍等。

# 2. 训练（80M 字语料，M3 Max 约 10 分钟，峰值内存约 10–20GB）
python3 tools/ngram/train_ngram.py \
    --corpus ~/Documents/corpus_dir \
    --out sentence-ngram-mobile.bin \
    --min-tri-count 2 --jobs 12

#    多路径混合 + 整句去重（跨文件，防转载重复放大统计）：
python3 tools/ngram/train_ngram.py \
    --corpus ~/books/ --corpus news.txt --dedup ...

# 3. 校验（结构 + 打分冒烟）
python3 tools/ngram/verify_ngram.py --model sentence-ngram-mobile.bin --full \
    --probe 今天天气很好我们一起去看电影
# 4. 装载到 Fire（两种方式任选）
#    a) 系统设置 → 词库 → 整句模型 →「重新载入」（先改 sentenceModelPath）
#    b) 覆盖 Application Support：
cp sentence-ngram-mobile.bin \
   ~/Library/"Application Support"/<bundle-id>/sentence-ngram-mobile.bin
#    然后在偏好设置里点「重新载入」
```

## 格式要点（与 NgramModel.swift 对齐）

- 全小端；header 104 字节；`total_size` 强校验。
- unigrams `(u32 key, f32 prob)` 升序，`[0]` = `<unk>`（key 0）。
- BOS=0x02、EOS=0x03；bi 语境只落 prev≠BOS（BOS 记录存在但空、λ=1）。
- context 记录：`u64 key / f32 λ / u32 count / (u32,f32)×count 升序`。
  存的 prob 是"保留质量"（已折扣、未补高阶）；解码端 `p = store + λ×高阶`，
  所以 λ = 1 − Σstore，允许 Σstore+λ ≤ 1（高阶摊到全词表后守恒）。
- 稀疏索引每 `stride`（64）条抽一条 `(first_key, offset)`，查询端二分定位页、
  页内线性扫（≤64 条）；页数据靠 mmap 由内核换页。

## 高效训练：fast_train（C++，推荐）

`fast_train.cpp` 与 Python 版语义逐字节一致（同一子集输出 `cmp` 相等），
专为 Apple Silicon 优化：开放寻址哈希计数、mmap 分页读、LF 对齐的多线程
分块（句子边界切断，结果与整读一致）、基数排序、流式导出。

```bash
# 编译（一次）
clang++ -std=c++17 -O3 -arch arm64 tools/ngram/fast_train.cpp -o tools/ngram/fast_train

# 训练整个语料目录
tools/ngram/fast_train --corpus tools/ngram/corpus --out sentence-ngram-mobile.bin \
    --jobs 12 --min-tri-count 2

# 校验
python3 tools/ngram/verify_ngram.py --model sentence-ngram-mobile.bin --full
```

实测（M3 Max 16 核，同一份 1 GB 真实语料）：**fast_train 全程 5.2 s**
（计数 348 MB/s）vs **Python 版 239.5 s，约 46 倍**；两者输出 `cmp` 逐字节一致。
8 GB 语料全程预计 **1–3 分钟**、峰值内存约 15–25 GB。已知约束：假设语料为
UTF-8（非法序列按分句边界处理并计数报告）；GBK 文件请先转码或走 Python 版。

参数与 Python 版同名同义；额外 `--chunk-mb N`（默认 8，0=整文件不切块；
切块不改变结果，仅影响并行度与内存）。

## 调参

| 参数 | 默认 | 说明 |
|---|---|---|
| `--min-tri-count` | 2 | trigram 后继最小计数，剪枝效果最大（现网 214MB / 787万 tri 语境） |
| `--min-bi-count` | 1 | bigram 剪枝，一般不动 |
| `--discount` | 1.0 | 绝对折扣 θ，0.75 更接近 KN |
| `--stride` | 64 | 必须 ≥16，改动会同时影响查询线性扫开销 |
| `--ext-a` | off | 词表纳入 CJK 扩展 A（现网模型含 651 个） |
| `--min-sent-len` | 2 | 自动切句后短于此字数的碎片丢弃 |
| `--dedup` | off | 跨文件整句去重（转载/引用多的语料建议开） |

## 评估

`verify_ngram.py` 按 Swift 解码端同一套插值公式（P1 uni → P2 bi → P3 tri）打分，
三种模式：

```bash
# 结构全量扫描（214MB 模型约 7.5s）：升序/λ范围/后继概率/页边界/区块尾对齐
python3 tools/ngram/verify_ngram.py --model … --full

# 单句逐字诊断：[T/B/U/UNK] 标记实际吃到哪一阶，--details 附 p1/p2/p3 与语境命中
python3 tools/ngram/verify_ngram.py --model … --probe 我们不知道 --details

# held-out 测试集（每行一句）：uni/bi/tri 三档 logP、NLL、PPL + 覆盖率 + 增益
python3 tools/ngram/verify_ngram.py --model … --eval test.txt \
    --eval-limit 10000 --progress 2000 --details
```

指标口径：

- **预测数含 EOS**（EOS 也是一次模型预测，与解码器 `endingAdjustment` 口径一致），
  BOS 不计入；
- **successor hit** 指后继表里有没有这个 (ctx→target)，不是硬 backoff 的"用了哪阶"
  ——这是插值模型，三阶始终在加权；
- `bigram/trigram vs … PPL reduction` 看高阶是否真的带来收益，训练集上 tri 增益
  为负说明 `--min-tri-count` 太松或语料太小；
- 实测参考：现网模型 800 句小样本 PPL ≈ 17.6（trigram），unigram 档 ≈ 1626，
  tri 相对 bi 再降约 90%。同一 eval 集横向比较你的新模型即可。

`--eval` 集务必**不要**混进训练语料；GBK 测试集需先转 UTF-8（eval 是 strict 解码，
训练输入才做编码嗅探）。

## 语法 / 校验细节速查

| verify 检查 | 对应 Swift 侧 |
|---|---|
| version==1、headerSize==104、total_size==实际大小 | `load()` 同款强校验，加载器会拒收 |
| stride≥16、blocks<index_off 顺序、section overflow | `invalidLayout` 同款 |
| 稀疏索引 key 严格升序 | 二分 `findPage` 的前提 |
| 区块恰好止于本区 index 起点 | 空洞/溢出都会让末页扫描越界 |
