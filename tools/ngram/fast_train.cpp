// fast_train.cpp — Fire TCSKNM02 字级 trigram 高效训练器（Apple Silicon / clang -O3）
/*
语义与 tools/ngram/train_ngram.py 对齐：
  - 非保留字符 = 分句边界；句子 = BOS BOS w1..wn EOS（逐句独立计数）。
  - 默认词表 CJK 基本区 U+4E00–U+9FFF；--ext-a 加 U+3400–U+4DBF。
  - bi 语境只落 prev != BOS；导出时词表内未观察到的 ctx 补空行 λ=1。
  - tri 落全部 (prev2,prev1) 语境（含 BOS 参与）。
  - Witten-Bell：store=(c-θ)/(N+θ·T)，λ=1-Σstore（N=剪枝前 ctx 总数，
    T=剪枝后种类数；与 python kn_store_and_lambda 同口径）。
  - 输出必须通过 tools/ngram/verify_ngram.py --full。
假设：语料为 UTF-8（本语料实测 highbit 字节与 3 字节 CJK 完全吻合）。
非 UTF-8 字节序列按分句边界处理并计数报告。

编译：
  clang++ -std=c++17 -O3 -arch arm64 tools/ngram/fast_train.cpp -o tools/ngram/fast_train
用法：
tools/ngram/fast_train --corpus tools/ngram/corpus --out Fire/Resources/sentence-ngram-mobile.bin \
      --jobs 12 --min-tri-count 1
tools/ngram/fast_train \
 --corpus tools/ngram/corpus \
 --out Fire/Resources/sentence-ngram-mobile.bin \
 --jobs 12 \
 --chunk-mb 256 \
 --min-tri-count 2 \
 --min-bi-count 1 \
 --min-sent-len 2 \
 --discount 0.75 \
 --stride 16
*/

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

static const uint32_t UNK = 0, BOS = 2, EOS = 3;
static const uint64_t SHIFT = 1ull << 21;

struct Config {
    std::vector<std::string> corpus;
    std::string out;
    uint32_t min_bi = 1, min_tri = 2, min_sent_len = 2;
    double theta = 1.0;
    uint32_t stride = 64;
    bool ext_a = false;
    int jobs = 0;
    size_t chunk_bytes = 8ull << 20;
};

// ------------------------------------------------------------ 开放寻址哈希
struct HMap {  // key != 0；0 = EMPTY
    uint64_t* keys = nullptr;
    uint32_t* vals = nullptr;
    size_t cap = 0, mask = 0, sz = 0;
    size_t grow_at = 0;

    HMap() = default;
    HMap(const HMap&) = delete;
    HMap& operator=(const HMap&) = delete;

    HMap(HMap&& o) noexcept {
        keys = o.keys;
        vals = o.vals;
        cap = o.cap;
        mask = o.mask;
        sz = o.sz;
        grow_at = o.grow_at;
        o.keys = nullptr;
        o.vals = nullptr;
        o.cap = o.mask = o.sz = o.grow_at = 0;
    }

    HMap& operator=(HMap&& o) noexcept {
        if (this == &o) return *this;
        release();
        keys = o.keys;
        vals = o.vals;
        cap = o.cap;
        mask = o.mask;
        sz = o.sz;
        grow_at = o.grow_at;
        o.keys = nullptr;
        o.vals = nullptr;
        o.cap = o.mask = o.sz = o.grow_at = 0;
        return *this;
    }

    ~HMap() {
        release();
    }

    void release() {
        free(keys);
        free(vals);
        keys = nullptr;
        vals = nullptr;
        cap = mask = sz = grow_at = 0;
    }

    void init(size_t want) {
        release();

        // want 表示期望槽位容量，而不是元素数。
        cap = 16;
        while (cap < want) {
            if (cap > (std::numeric_limits<size_t>::max() >> 1)) {
                fprintf(stderr, "HMap 容量溢出\n");
                abort();
            }
            cap <<= 1;
        }

        mask = cap - 1;
        grow_at = (cap * 7) / 10;

        keys = static_cast<uint64_t*>(calloc(cap, sizeof(uint64_t)));
        vals = static_cast<uint32_t*>(calloc(cap, sizeof(uint32_t)));

        if (!keys || !vals) {
            fprintf(stderr, "HMap 分配失败: cap=%zu\n", cap);
            abort();
        }

        sz = 0;
    }

    static inline uint64_t mix(uint64_t x) {
        x += 0x9e3779b97f4a7c15ull;
        x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
        x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
        return x ^ (x >> 31);
    }

    void grow() {
        size_t oc = cap;
        uint64_t* ok = keys;
        uint32_t* ov = vals;

        cap = oc << 1;
        mask = cap - 1;
        grow_at = (cap * 7) / 10;

        keys = static_cast<uint64_t*>(calloc(cap, sizeof(uint64_t)));
        vals = static_cast<uint32_t*>(calloc(cap, sizeof(uint32_t)));

        if (!keys || !vals) {
            fprintf(stderr, "HMap 扩容失败: cap=%zu\n", cap);
            abort();
        }

        size_t old_sz = sz;
        sz = 0;

        for (size_t i = 0; i < oc; ++i) {
            uint64_t k = ok[i];
            if (!k) continue;

            size_t j = mix(k) & mask;
            while (keys[j]) j = (j + 1) & mask;

            keys[j] = k;
            vals[j] = ov[i];
            ++sz;
        }

        free(ok);
        free(ov);

        if (sz != old_sz) abort();
    }

    inline void add(uint64_t k, uint32_t d = 1) {
        size_t j = mix(k) & mask;

        while (true) {
            uint64_t cur = keys[j];

            if (cur == k) {
                vals[j] += d;
                return;
            }

            if (cur == 0) break;
            j = (j + 1) & mask;
        }

        // 只有真正新增 key 时才需要考虑扩容。
        // 这避免高负载下每次命中已有 key 也触发 grow 判断/扩容。
        if (sz + 1 > grow_at) {
            grow();

            j = mix(k) & mask;
            while (keys[j]) j = (j + 1) & mask;
        }

        keys[j] = k;
        vals[j] = d;
        ++sz;
    }
};

struct Shard {
    std::vector<uint64_t> uni;  // 0x10000
    HMap bi;                     // (prev<<16)|w
    HMap tri;                    // (prev2<<32)|(prev1<<16)|w
    uint64_t n_sent = 0, n_chars = 0, bad_utf8 = 0;

    Shard() : uni(0x10000, 0) {
        bi.init(1 << 14);
        tri.init(1 << 18);
    }

    Shard(const Shard&) = delete;
    Shard& operator=(const Shard&) = delete;
    Shard(Shard&&) = default;
    Shard& operator=(Shard&&) = default;
};

static inline bool keep_cp(uint32_t cp, bool ext_a) {
    if (cp >= 0x4E00 && cp <= 0x9FFF) return true;
    if (ext_a && cp >= 0x3400 && cp <= 0x4DBF) return true;
    return false;
}

static inline bool cont(uint8_t b) {
    return (b & 0xC0u) == 0x80u;
}

static void count_block(const uint8_t* p, size_t n, const Config& cfg, Shard& sh) {
    // 动态缓冲避免把超长连续 CJK 文本人为切成多个句子。
    std::vector<uint32_t> sent_buf;
    sent_buf.reserve(4096);

    auto flush = [&]() {
        const size_t slen = sent_buf.size();

        if (slen < cfg.min_sent_len) {
            sent_buf.clear();
            return;
        }

        sh.n_sent++;
        sh.n_chars += slen;

        uint32_t prev2 = BOS, prev1 = BOS;

        for (uint32_t cp : sent_buf) {
            sh.uni[cp]++;

            if (prev1 != BOS)
                sh.bi.add(((uint64_t)prev1 << 16) | cp);

            sh.tri.add(
                ((uint64_t)prev2 << 32) |
                ((uint64_t)prev1 << 16) |
                cp
            );

            prev2 = prev1;
            prev1 = cp;
        }

        sh.uni[EOS]++;

        if (prev1 != BOS)
            sh.bi.add(((uint64_t)prev1 << 16) | EOS);

        sh.tri.add(
            ((uint64_t)prev2 << 32) |
            ((uint64_t)prev1 << 16) |
            EOS
        );

        sent_buf.clear();
    };

    size_t i = 0;

    while (i < n) {
        const uint8_t b = p[i];

        uint32_t cp = 0;
        size_t l = 1;
        bool valid = false;

        if (b < 0x80) {
            cp = b;
            l = 1;
            valid = true;
        } else if (b >= 0xC2 && b <= 0xDF &&
                   i + 1 < n &&
                   cont(p[i + 1])) {
            cp = ((uint32_t)(b & 0x1Fu) << 6) |
                 (uint32_t)(p[i + 1] & 0x3Fu);
            l = 2;
            valid = true;
        } else if (b >= 0xE0 && b <= 0xEF &&
                   i + 2 < n &&
                   cont(p[i + 1]) &&
                   cont(p[i + 2])) {
            uint8_t b1 = p[i + 1];

            // E0 80..9F = overlong；ED A0..BF = UTF-16 surrogate。
            if (!((b == 0xE0 && b1 < 0xA0) ||
                  (b == 0xED && b1 >= 0xA0))) {
                cp = ((uint32_t)(b & 0x0Fu) << 12) |
                     ((uint32_t)(b1 & 0x3Fu) << 6) |
                     (uint32_t)(p[i + 2] & 0x3Fu);
                l = 3;
                valid = true;
            }
        } else if (b >= 0xF0 && b <= 0xF4 &&
                   i + 3 < n &&
                   cont(p[i + 1]) &&
                   cont(p[i + 2]) &&
                   cont(p[i + 3])) {
            uint8_t b1 = p[i + 1];

            // F0 80..8F = overlong；F4 90..BF > U+10FFFF。
            if (!((b == 0xF0 && b1 < 0x90) ||
                  (b == 0xF4 && b1 > 0x8F))) {
                cp = ((uint32_t)(b & 0x07u) << 18) |
                     ((uint32_t)(b1 & 0x3Fu) << 12) |
                     ((uint32_t)(p[i + 2] & 0x3Fu) << 6) |
                     (uint32_t)(p[i + 3] & 0x3Fu);
                l = 4;
                valid = true;
            }
        }

        if (!valid) {
            ++sh.bad_utf8;
            flush();

            // 非法序列只消费当前 byte，使后续 byte 独立重新解析。
            ++i;
            continue;
        }

        bool keep = (l == 3 && keep_cp(cp, cfg.ext_a));

        if (keep)
            sent_buf.push_back(cp);
        else
            flush();

        i += l;
    }

    flush();
}

// ------------------------------------------------------------ 基数排序
struct Ent64 {
    uint64_t key;
    uint32_t cnt;
};

static_assert(sizeof(Ent64) <= 16, "Ent64 unexpectedly large");

static void radix64(std::vector<Ent64>& a, int bytes) {
    const size_t n = a.size();

    if (n < 2) return;

    std::vector<Ent64> b(n);

    for (int pass = 0; pass < bytes; ++pass) {
        size_t hist[256] = {};
        const unsigned sh = (unsigned)pass * 8;

        for (const auto& e : a)
            ++hist[(e.key >> sh) & 0xFFu];

        size_t pos[256];
        size_t run = 0;

        for (unsigned j = 0; j < 256; ++j) {
            pos[j] = run;
            run += hist[j];
        }

        for (const auto& e : a)
            b[pos[(e.key >> sh) & 0xFFu]++] = e;

        a.swap(b);
    }
}

// ------------------------------------------------------------ 流式导出
struct StreamResult {
    size_t ctx_count = 0, index_off = 0, index_written = 0;
};

struct BlockHeader {
    uint64_t ctxkey;
    float lambda;
    uint32_t count;
};

static_assert(sizeof(BlockHeader) == 16, "unexpected block header layout");

static StreamResult stream(FILE* F, size_t blocks_off, std::vector<Ent64>& ents,
                           uint32_t min_cnt, bool tri, const Config& cfg) {
    // ents 升序；key 低 16 位 = w，其余 = ctx（bi: prev；tri: prev2<<16|prev1）
    StreamResult R;

    std::vector<std::pair<uint64_t, uint64_t>> index;
    if (!ents.empty())
        index.reserve(ents.size() / cfg.stride + 1);

    size_t filepos = blocks_off;
    size_t n_written = 0;

    std::vector<uint8_t> succbuf;
    succbuf.reserve(1 << 16);

    size_t i = 0;

    while (i < ents.size()) {
        uint64_t ctxbits = ents[i].key >> 16;
        uint64_t ctxkey;

        if (tri) {
            uint32_t prev2 = (uint32_t)(ctxbits >> 16);
            uint32_t prev1 = (uint32_t)(ctxbits & 0xFFFF);
            ctxkey = (uint64_t)prev2 * SHIFT + prev1;
        } else {
            ctxkey = ctxbits;  // bi: prev1（< 0x10000）
        }

        size_t j = i;
        uint64_t ctx_total = 0;

        while (j < ents.size() && (ents[j].key >> 16) == ctxbits) {
            ctx_total += ents[j].cnt;
            ++j;
        }

        succbuf.clear();

        double kept = 0.0;
        size_t cnt = 0;

        if (ctx_total > 0) {
            size_t Tn = 0;

            for (size_t k = i; k < j; ++k)
                if (ents[k].cnt >= min_cnt)
                    ++Tn;

            const double T = (double)Tn;
            const double denom = (double)ctx_total + cfg.theta * T;

            for (size_t k = i; k < j; ++k) {
                if (ents[k].cnt < min_cnt)
                    continue;

                double v = (double)ents[k].cnt - cfg.theta;
                if (v <= 0)
                    continue;

                double p = v / denom;
                kept += p;

                uint32_t w = (uint32_t)(ents[k].key & 0xFFFF);
                float fp = (float)p;

                size_t old = succbuf.size();
                succbuf.resize(old + 8);

                memcpy(succbuf.data() + old, &w, 4);
                memcpy(succbuf.data() + old + 4, &fp, 4);

                ++cnt;
            }
        }

        double lam = 1.0 - kept;

        if (lam < 1e-12)
            lam = 1e-12;

        if (cnt == 0) {
            if (tri) {
                i = j;
                continue;
            }  // python: tri 空语境丢弃；bi 保留空行

            lam = 1.0;
        }

        if (n_written % cfg.stride == 0)
            index.emplace_back(ctxkey, (uint64_t)filepos);

        BlockHeader bh;
        bh.ctxkey = ctxkey;
        bh.lambda = (float)lam;
        bh.count = (uint32_t)cnt;

        fwrite(&bh, sizeof(bh), 1, F);

        if (!succbuf.empty())
            fwrite(succbuf.data(), 1, succbuf.size(), F);

        filepos += sizeof(bh) + succbuf.size();
        ++n_written;

        i = j;
    }

    for (auto& [k, off] : index) {
        fwrite(&k, 8, 1, F);
        fwrite(&off, 8, 1, F);
    }

    R.ctx_count = n_written;
    R.index_off = filepos;
    R.index_written = index.size();

    return R;
}

int main(int argc, char** argv) {
    Config cfg;

    cfg.jobs = (int)std::thread::hardware_concurrency();
    if (cfg.jobs < 1) cfg.jobs = 1;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];

        auto need = [&]() -> std::string {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s 缺参数\n", argv[i]);
                exit(2);
            }
            return argv[++i];
        };

        if (a == "--corpus")
            cfg.corpus.push_back(need());
        else if (a == "--out")
            cfg.out = need();
        else if (a == "--min-tri-count")
            cfg.min_tri = (uint32_t)atoi(need().c_str());
        else if (a == "--min-bi-count")
            cfg.min_bi = (uint32_t)atoi(need().c_str());
        else if (a == "--min-sent-len")
            cfg.min_sent_len = (uint32_t)atoi(need().c_str());
        else if (a == "--discount")
            cfg.theta = atof(need().c_str());
        else if (a == "--stride")
            cfg.stride = (uint32_t)atoi(need().c_str());
        else if (a == "--ext-a")
            cfg.ext_a = true;
        else if (a == "--jobs")
            cfg.jobs = atoi(need().c_str());
        else if (a == "--chunk-mb")
            cfg.chunk_bytes = (size_t)atoi(need().c_str()) << 20;
        else {
            fprintf(stderr, "未知参数: %s\n", a.c_str());
            return 2;
        }
    }

    if (cfg.corpus.empty() || cfg.out.empty()) {
        fprintf(stderr,
                "用法: fast_train --corpus DIR|FILE [--corpus …] --out out.bin "
                "[--min-tri-count N] [--min-bi-count N] [--min-sent-len N] "
                "[--discount d] [--stride N] [--ext-a] [--jobs N] [--chunk-mb N]\n");
        return 2;
    }

    if (cfg.stride < 16) {
        fprintf(stderr, "--stride 必须 >=16\n");
        return 2;
    }

    if (!(cfg.theta > 0 && cfg.theta <= 1.0)) {
        fprintf(stderr, "--discount ∈ (0,1]\n");
        return 2;
    }

    if (cfg.jobs < 1)
        cfg.jobs = 1;

    // ---- 收集文件（排序后按大小交错，让大文件均匀落不同 worker）----
    std::vector<std::pair<std::string, size_t>> files;
    uint64_t total_bytes = 0;

    for (auto& c : cfg.corpus) {
        fs::path cp(c);

        if (fs::is_directory(cp)) {
            for (auto& e : fs::recursive_directory_iterator(cp)) {
                if (!e.is_regular_file())
                    continue;

                std::string n = e.path().filename().string();
                std::string low = n;

                for (auto& ch : low)
                    ch = (char)tolower((unsigned char)ch);

                bool txt =
                    low.size() >= 4 &&
                    (low.substr(low.size() - 4) == ".txt" ||
                     low.substr(low.size() - 3) == ".md" ||
                     low.substr(low.size() - 5) == ".text");

                if (!n.empty() && n[0] == '.')
                    continue;

                if (!txt)
                    continue;

                size_t s = fs::file_size(e.path());
                files.emplace_back(e.path().string(), s);
                total_bytes += s;
            }
        } else if (fs::is_regular_file(cp)) {
            size_t s = fs::file_size(cp);
            files.emplace_back(cp.string(), s);
            total_bytes += s;
        } else {
            fprintf(stderr, "跳过不存在: %s\n", c.c_str());
        }
    }

    if (files.empty()) {
        fprintf(stderr, "没有语料文件\n");
        return 2;
    }

    std::sort(
        files.begin(),
        files.end(),
        [](const auto& x, const auto& y) {
            return x.second != y.second
                ? x.second > y.second
                : x.first < y.first;
        });

    // ---- 工作块：大文件按 chunk 切（UTF-8 边界对齐），小文件整读 ----
    struct Chunk {
        std::string file;
        size_t foff, len;
    };

    std::vector<Chunk> chunks;

    if (cfg.chunk_bytes)
        chunks.reserve((size_t)(total_bytes / cfg.chunk_bytes) + files.size() + 1);

    for (auto& [fp, sz] : files) {
        if (cfg.chunk_bytes == 0 || sz <= cfg.chunk_bytes) {
            chunks.push_back({fp, 0, sz});
            continue;
        }

        int fd = open(fp.c_str(), O_RDONLY);

        if (fd < 0) {
            fprintf(stderr, "打不开: %s\n", fp.c_str());
            continue;
        }

        uint8_t* m =
            (uint8_t*)mmap(nullptr, sz, PROT_READ, MAP_PRIVATE, fd, 0);

        if (m == MAP_FAILED) {
            int e = errno;
            close(fd);
            fprintf(stderr,
                    "mmap 失败(切块): %s len=%zu errno=%d %s\n",
                    fp.c_str(), sz, e, strerror(e));
            continue;
        }

        size_t pos = 0;

        while (pos < sz) {
            size_t end = std::min(pos + cfg.chunk_bytes, sz);

            if (end < sz) {
                // 优先对齐 LF（句子边界，与 python 按行切批语义一致）
                size_t scan = end;
                size_t lf =
                    std::min(sz,
                             pos + cfg.chunk_bytes +
                             ((size_t)4 << 20));

                while (scan < lf && m[scan] != '\n')
                    ++scan;

                if (scan < lf) {
                    end = scan + 1;
                } else {
                    while (end < sz &&
                           (m[end] & 0xC0) == 0x80)
                        ++end;
                }
            }

            chunks.push_back({fp, pos, end - pos});
            pos = end;
        }

        munmap(m, sz);
        close(fd);
    }

    printf("[1/4] 计数: %zu 文件 / %.2f GB, jobs=%d, 工作块 %zu 个, chunk=%.0fMB\n",
           files.size(),
           total_bytes / 1e9,
           cfg.jobs,
           chunks.size(),
           cfg.chunk_bytes / 1e6);
    fflush(stdout);

    // ---- 并行计数 ----
    std::vector<Shard> shards;
    shards.reserve(cfg.jobs);

    for (int i = 0; i < cfg.jobs; ++i)
        shards.emplace_back();

    std::atomic<size_t> next{0};
    std::atomic<uint64_t> done_bytes{0};
    std::atomic<bool> stop{false};

    auto t0 = std::chrono::steady_clock::now();

    std::thread heartbeat([&] {
        while (!stop.load(std::memory_order_relaxed)) {
            uint64_t d =
                done_bytes.load(std::memory_order_relaxed);

            double el =
                std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - t0)
                    .count();

            printf("\r      %.1f/%.1f GB (%zu%%)  %.0f MB/s   ",
                   d / 1e9,
                   total_bytes / 1e9,
                   total_bytes
                       ? (size_t)(d * 100 / total_bytes)
                       : 100,
                   el > 0 ? d / el / 1e6 : 0.0);

            fflush(stdout);
            std::this_thread::sleep_for(
                std::chrono::milliseconds(1000));
        }
    });

    std::vector<std::thread> pool;
    pool.reserve(cfg.jobs);

    const long page_raw = sysconf(_SC_PAGESIZE);
    const size_t PAGE =
        page_raw > 0 ? (size_t)page_raw : 4096;

    for (int t = 0; t < cfg.jobs; ++t) {
        pool.emplace_back([&, t] {
            Shard& shard = shards[t];

            while (true) {
                size_t k =
                    next.fetch_add(1, std::memory_order_relaxed);

                if (k >= chunks.size())
                    break;

                const auto& ck = chunks[k];

                if (ck.len == 0) {
                    continue;
                }

                int fd = open(ck.file.c_str(), O_RDONLY);

                if (fd < 0) {
                    fprintf(stderr,
                            "\n打不开: %s\n",
                            ck.file.c_str());
                    continue;
                }

                // mmap 偏移必须对齐到系统页大小——Apple Silicon 是 16 KB，
                // 硬编码 4096 会在 arm64 上返回 EINVAL。
                size_t pa = ck.foff - (ck.foff % PAGE);
                size_t slack = ck.foff - pa;
                size_t map_len = ck.len + slack;

                uint8_t* base =
                    (uint8_t*)mmap(
                        nullptr,
                        map_len,
                        PROT_READ,
                        MAP_PRIVATE,
                        fd,
                        (off_t)pa);

                if (base == MAP_FAILED) {
                    int e = errno;
                    close(fd);

                    fprintf(stderr,
                            "mmap 失败: %s off=%zu len=%zu errno=%d %s\n",
                            ck.file.c_str(),
                            ck.foff,
                            ck.len,
                            e,
                            strerror(e));
                    continue;
                }

                uint8_t* m = base + slack;

                madvise(base, map_len, MADV_SEQUENTIAL);

                count_block(m, ck.len, cfg, shard);

                munmap(base, map_len);
                close(fd);

                done_bytes.fetch_add(
                    ck.len,
                    std::memory_order_relaxed);
            }
        });
    }

    for (auto& th : pool)
        th.join();

    stop.store(true, std::memory_order_relaxed);
    heartbeat.join();

    double el_count =
        std::chrono::duration<double>(
            std::chrono::steady_clock::now() - t0)
            .count();

    printf("\r      计数完成 %.1f GB / %.0fs (%.0f MB/s)                    \n",
           total_bytes / 1e9,
           el_count,
           el_count > 0
               ? total_bytes / el_count / 1e6
               : 0.0);

    // ---- 合并 ----
    uint64_t uni[0x10000] = {};

    HMap bi, tri;

    {
        size_t bi_want = 0;
        size_t tri_want = 0;

        for (auto& sh : shards) {
            bi_want += sh.bi.sz;
            tri_want += sh.tri.sz;
        }

        // init() 的参数是槽位数。为了尽量避免 merge 期间再次 grow，
        // 按最坏情况下的 shard entry 总数预留到 <= 70% load。
        auto slots_for = [](size_t entries) -> size_t {
            if (entries == 0)
                return 16;

            if (entries >
                (std::numeric_limits<size_t>::max() / 10))
                return entries;

            return entries * 10 / 7 + 16;
        };

        bi.init(slots_for(bi_want + 0x10000));
        tri.init(slots_for(tri_want));
    }

    uint64_t n_sent = 0;
    uint64_t n_chars = 0;
    uint64_t bad = 0;

    for (auto& sh : shards) {
        for (int cp = 0; cp < 0x10000; ++cp)
            uni[cp] += sh.uni[cp];

        n_sent += sh.n_sent;
        n_chars += sh.n_chars;
        bad += sh.bad_utf8;

        for (size_t i = 0; i < sh.bi.cap; ++i) {
            if (sh.bi.keys[i])
                bi.add(sh.bi.keys[i], sh.bi.vals[i]);
        }

        // bi 合并完成后立刻释放这个 shard 的 bi，
        // 避免它继续占用内存直到程序结束。
        sh.bi.release();

        for (size_t i = 0; i < sh.tri.cap; ++i) {
            if (sh.tri.keys[i])
                tri.add(sh.tri.keys[i], sh.tri.vals[i]);
        }

        // tri 通常远大于 bi；尽早释放能明显降低后续排序的峰值内存。
        sh.tri.release();

        std::vector<uint64_t>().swap(sh.uni);
    }

    // shard 本体现在已经没有大块动态内存。
    shards.clear();
    shards.shrink_to_fit();

    uint64_t total_tokens = 0;

    for (int cp = 0; cp < 0x10000; ++cp)
        total_tokens += uni[cp];

    printf("[2/4] 合并完成: 句子=%llu 字符=%llu tokens=%llu bi条目=%llu tri条目=%llu\n",
           (unsigned long long)n_sent,
           (unsigned long long)n_chars,
           (unsigned long long)total_tokens,
           (unsigned long long)bi.sz,
           (unsigned long long)tri.sz);

    if (bad)
        printf("      ⚠ 非法 UTF-8 %llu 处（按分句边界处理）\n",
               (unsigned long long)bad);

    if (!total_tokens) {
        fprintf(stderr, "清洗后为空\n");
        return 1;
    }

    // ---- 导出 ----
    std::vector<Ent64> biV;
    std::vector<Ent64> triV;

    biV.reserve(bi.sz + 0x10000);
    triV.reserve(tri.sz);

    for (size_t i = 0; i < bi.cap; ++i) {
        if (bi.keys[i])
            biV.push_back({bi.keys[i], bi.vals[i]});
    }

    // bi 已转为紧凑数组，立即释放哈希表。
    bi.release();

    for (size_t i = 0; i < tri.cap; ++i) {
        if (tri.keys[i])
            triV.push_back({tri.keys[i], tri.vals[i]});
    }

    // 这一步很重要：radix64 还会创建一份同尺寸 scratch，
    // 所以必须在排序之前释放巨大的 tri hash table。
    tri.release();

    radix64(biV, 4);
    radix64(triV, 6);

    std::vector<uint32_t> vocab;
    vocab.reserve(0x8000);

    for (int cp = 1; cp < 0x10000; ++cp) {
        if (uni[cp])
            vocab.push_back((uint32_t)cp);
    }

    // bi：词表中没有任何观察后继的字补空条目（保 bi_ctx ≥ 词表覆盖，与 python 一致）
    {
        std::vector<uint8_t> seen(0x10000, 0);

        for (auto& e : biV)
            seen[e.key >> 16] = 1;

        for (auto cp : vocab) {
            if (!seen[cp])
                biV.push_back(
                    {(uint64_t)cp << 16, 0});
        }

        radix64(biV, 4);
    }

    std::string tmp_path = cfg.out + ".tmp";

    FILE* F = fopen(tmp_path.c_str(), "wb");

    if (!F) {
        fprintf(stderr,
                "打不开输出: %s\n",
                cfg.out.c_str());
        return 1;
    }

    // 大块顺序输出，减少 libc write 调用。
    std::vector<char> file_buffer(8u << 20);
    setvbuf(F,
            file_buffer.data(),
            _IOFBF,
            file_buffer.size());

    const size_t HEADER = 104;

    if (fseeko(F, (off_t)HEADER, SEEK_SET) != 0) {
        fprintf(stderr, "输出 seek 失败\n");
        fclose(F);
        unlink(tmp_path.c_str());
        return 1;
    }

    // unigrams：<unk> = 词表最小概率兜底，全体归一
    {
        double floor_p = -1.0;

        for (auto cp : vocab) {
            double p =
                (double)uni[cp] / total_tokens;

            if (floor_p < 0 || p < floor_p)
                floor_p = p;
        }

        double sum = floor_p;

        for (auto cp : vocab)
            sum +=
                (double)uni[cp] / total_tokens;

        std::vector<uint8_t> buf;
        buf.resize((vocab.size() + 1) * 8);

        size_t pos = 0;

        auto put = [&](uint32_t k, float p) {
            memcpy(buf.data() + pos, &k, 4);
            memcpy(buf.data() + pos + 4, &p, 4);
            pos += 8;
        };

        put(UNK, (float)(floor_p / sum));

        for (auto cp : vocab) {
            put(cp,
                (float)(
                    (double)uni[cp] /
                    total_tokens /
                    sum));
        }

        fwrite(buf.data(), 1, buf.size(), F);
    }

    size_t uni_off = HEADER;
    size_t bi_blocks =
        uni_off + (vocab.size() + 1) * 8;

    StreamResult B =
        stream(F,
               bi_blocks,
               biV,
               cfg.min_bi,
               false,
               cfg);

    size_t bi_index_off = B.index_off;                       // bi blocks 尾 = bi index
    size_t bi_idx_cnt =
        B.ctx_count == 0
            ? 0
            : (B.ctx_count + cfg.stride - 1) /
                  cfg.stride;

    // 实际写入的索引条数以 stream 记录为准
    bi_idx_cnt = B.index_written;

    size_t tri_blocks =
        bi_index_off + bi_idx_cnt * 16;

    // bi 后面不再需要，主动释放；给 tri stream 和 OS page cache 腾空间。
    std::vector<Ent64>().swap(biV);

    StreamResult T =
        stream(F,
               tri_blocks,
               triV,
               cfg.min_tri,
               true,
               cfg);

    size_t tri_index_off = T.index_off;
    size_t tri_idx_cnt = T.index_written;

    size_t total =
        tri_index_off + tri_idx_cnt * 16;

    char h[HEADER] = {};

    memcpy(h, "TCSKNM02", 8);

    uint32_t v32 = 1;
    uint32_t hs = HEADER;
    uint32_t st = cfg.stride;
    uint32_t uc =
        (uint32_t)(vocab.size() + 1);

    uint64_t ts = total;
    uint64_t uoff = uni_off;

    uint32_t bc32 =
        (uint32_t)B.ctx_count;
    uint32_t bi_idx32 =
        (uint32_t)bi_idx_cnt;

    uint64_t bblocks = bi_blocks;
    uint64_t bidxoff = bi_index_off;

    uint32_t tc32 =
        (uint32_t)T.ctx_count;
    uint32_t ti_idx32 =
        (uint32_t)tri_idx_cnt;

    uint64_t tblocks = tri_blocks;
    uint64_t tidxoff = tri_index_off;

    memcpy(h + 8, &v32, 4);
    memcpy(h + 12, &hs, 4);
    memcpy(h + 16, &ts, 8);
    memcpy(h + 24, &st, 4);
    memcpy(h + 32, &uc, 4);
    memcpy(h + 40, &uoff, 8);
    memcpy(h + 48, &bc32, 4);
    memcpy(h + 52, &bi_idx32, 4);
    memcpy(h + 56, &bblocks, 8);
    memcpy(h + 64, &bidxoff, 8);
    memcpy(h + 72, &tc32, 4);
    memcpy(h + 80, &ti_idx32, 4);
    memcpy(h + 88, &tblocks, 8);
    memcpy(h + 96, &tidxoff, 8);

    if (fseeko(F, 0, SEEK_SET) != 0) {
        fprintf(stderr, "header seek 失败\n");
        fclose(F);
        unlink(tmp_path.c_str());
        return 1;
    }

    if (fwrite(h, 1, HEADER, F) != HEADER) {
        fprintf(stderr, "header 写入失败\n");
        fclose(F);
        unlink(tmp_path.c_str());
        return 1;
    }

    if (fclose(F) != 0) {
        fprintf(stderr, "输出文件关闭失败\n");
        unlink(tmp_path.c_str());
        return 1;
    }

    if (rename(tmp_path.c_str(),
               cfg.out.c_str()) != 0) {
        fprintf(stderr,
                "rename 失败: %s -> %s: %s\n",
                tmp_path.c_str(),
                cfg.out.c_str(),
                strerror(errno));
        unlink(tmp_path.c_str());
        return 1;
    }

    printf("[3/4] 导出 %llu 字节（%.0f MB）uni=%u bi_ctx=%llu bi_idx=%zu tri_ctx=%llu tri_idx=%zu\n",
           (unsigned long long)total,
           total / 1048576.0,
           uc,
           (unsigned long long)B.ctx_count,
           bi_idx_cnt,
           (unsigned long long)T.ctx_count,
           tri_idx_cnt);

    printf("[4/4] 总耗时 %.0fs。请校验: python3 tools/ngram/verify_ngram.py --model %s --full\n",
           std::chrono::duration<double>(
               std::chrono::steady_clock::now() - t0)
               .count(),
           cfg.out.c_str());

    return 0;
}
