// fast_train.cpp — Fire TCSKNM02 字级 trigram 高效训练器（Apple Silicon / clang -O3）
//
// 语义与 tools/ngram/train_ngram.py 对齐：
//   - 非保留字符 = 分句边界；句子 = BOS BOS w1..wn EOS（逐句独立计数）。
//   - 默认词表 CJK 基本区 U+4E00–U+9FFF；--ext-a 加 U+3400–U+4DBF。
//   - bi 语境只落 prev != BOS；导出时词表内未观察到的 ctx 补空行 λ=1。
//   - tri 落全部 (prev2,prev1) 语境（含 BOS 参与）。
//   - Witten-Bell：store=(c-θ)/(N+θ·T)，λ=1-Σstore（N=剪枝前 ctx 总数，
//     T=剪枝后种类数；与 python kn_store_and_lambda 同口径）。
//   - 输出必须通过 tools/ngram/verify_ngram.py --full。
// 假设：语料为 UTF-8（本语料实测 highbit 字节与 3 字节 CJK 完全吻合）。
// 非 UTF-8 字节序列按分句边界处理并计数报告。
//
// 编译：
//   clang++ -std=c++17 -O3 -arch arm64 tools/ngram/fast_train.cpp -o tools/ngram/fast_train
// 用法：
//   tools/ngram/fast_train --corpus tools/ngram/corpus --out ngram.bin \
//       --jobs 12 --min-tri-count 2

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <thread>
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

    void init(size_t want) {
        cap = 16;
        while (cap < want) cap <<= 1;
        mask = cap - 1;
        keys = (uint64_t*)calloc(cap, sizeof(uint64_t));
        vals = (uint32_t*)calloc(cap, sizeof(uint32_t));
        sz = 0;
    }
    static uint64_t mix(uint64_t x) {
        x += 0x9e3779b97f4a7c15ull;
        x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
        x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
        return x ^ (x >> 31);
    }
    void grow() {
        size_t oc = cap;
        uint64_t* ok = keys;
        uint32_t* ov = vals;
        keys = nullptr;
        init(oc * 2);
        for (size_t i = 0; i < oc; ++i)
            if (ok[i]) {
                size_t j = mix(ok[i]) & mask;
                while (keys[j]) j = (j + 1) & mask;
                keys[j] = ok[i];
                vals[j] = ov[i];
                ++sz;
            }
        free(ok);
        free(ov);
    }
    void add(uint64_t k, uint32_t d = 1) {
        if ((sz + 1) * 10 >= cap * 7) grow();
        size_t j = mix(k) & mask;
        while (keys[j]) {
            if (keys[j] == k) { vals[j] += d; return; }
            j = (j + 1) & mask;
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
};

static inline bool keep_cp(uint32_t cp, bool ext_a) {
    if (cp >= 0x4E00 && cp <= 0x9FFF) return true;
    if (ext_a && cp >= 0x3400 && cp <= 0x4DBF) return true;
    return false;
}

static void count_block(const uint8_t* p, size_t n, const Config& cfg, Shard& sh) {
    uint32_t sent_buf[4096];
    size_t slen = 0;

    auto flush = [&]() {
        if (slen < cfg.min_sent_len) { slen = 0; return; }
        sh.n_sent++;
        sh.n_chars += slen;
        uint32_t prev2 = BOS, prev1 = BOS;
        for (size_t i = 0; i < slen; ++i) {
            uint32_t cp = sent_buf[i];
            sh.uni[cp]++;
            if (prev1 != BOS) sh.bi.add(((uint64_t)prev1 << 16) | cp);
            sh.tri.add(((uint64_t)prev2 << 32) | ((uint64_t)prev1 << 16) | cp);
            prev2 = prev1;
            prev1 = cp;
        }
        sh.uni[EOS]++;
        if (prev1 != BOS) sh.bi.add(((uint64_t)prev1 << 16) | EOS);
        sh.tri.add(((uint64_t)prev2 << 32) | ((uint64_t)prev1 << 16) | EOS);
        slen = 0;
    };

    size_t i = 0;
    while (i < n) {
        uint8_t b = p[i];
        uint32_t cp = 0xFFFD;
        size_t l = 1;
        if (b < 0x80) { cp = b; l = 1; }
        else if ((b >> 5) == 0x6 && i + 1 < n) {
            cp = ((b & 0x1fu) << 6) | (p[i + 1] & 0x3fu);
            l = 2;
        } else if ((b >> 4) == 0xE && i + 2 < n) {
            cp = ((b & 0x0fu) << 12) | ((p[i + 1] & 0x3fu) << 6) | (p[i + 2] & 0x3fu);
            l = 3;
        } else if ((b >> 3) == 0x1E && i + 3 < n) {
            cp = ((b & 0x07u) << 18) | ((p[i + 1] & 0x3fu) << 12) |
                 ((p[i + 2] & 0x3fu) << 6) | (p[i + 3] & 0x3fu);
            l = 4;
        }
        if (cp == 0xFFFD) sh.bad_utf8++;
        bool keep = (l == 3 && keep_cp(cp, cfg.ext_a));
        if (keep) {
            if (slen == 4096) flush();
            sent_buf[slen++] = cp;
        } else {
            flush();
        }
        i += l;
    }
    flush();
}

// ------------------------------------------------------------ 基数排序
struct Ent64 { uint64_t key; uint32_t cnt; };
static void radix64(std::vector<Ent64>& a, int bytes) {
    size_t n = a.size();
    std::vector<Ent64> b(n);
    for (int pass = 0; pass < bytes; ++pass) {
        size_t hist[256] = {};
        int sh = pass * 8;
        for (size_t i = 0; i < n; ++i) hist[(a[i].key >> sh) & 0xFF]++;
        size_t run = 0;
        for (int j = 0; j < 256; ++j) { size_t t = hist[j]; hist[j] = run; run += t; }
        for (size_t i = 0; i < n; ++i) b[hist[(a[i].key >> sh) & 0xFF]++] = a[i];
        a.swap(b);
    }
}

// ------------------------------------------------------------ 流式导出
struct StreamResult { size_t ctx_count = 0, index_off = 0, index_written = 0; };

static StreamResult stream(FILE* F, size_t blocks_off, std::vector<Ent64>& ents,
                          uint32_t min_cnt, bool tri, const Config& cfg) {
    // ents 升序；key 低 16 位 = w，其余 = ctx（bi: prev；tri: prev2<<16|prev1）
    StreamResult R;
    std::vector<std::pair<uint64_t, uint64_t>> index;
    size_t filepos = blocks_off, n_written = 0;
    std::string buf;
    std::string succbuf;
    buf.reserve(1 << 16);
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
        while (j < ents.size() && (ents[j].key >> 16) == ctxbits) ctx_total += ents[j++].cnt;

        succbuf.clear();
        double kept = 0.0;
        size_t cnt = 0;
        if (ctx_total > 0) {
            double T = 0;
            for (size_t k = i; k < j; ++k)
                if (ents[k].cnt >= min_cnt) T += 1.0;
            double denom = (double)ctx_total + cfg.theta * T;
            for (size_t k = i; k < j; ++k) {
                if (ents[k].cnt < min_cnt) continue;
                double v = (double)ents[k].cnt - cfg.theta;
                if (v <= 0) continue;
                double p = v / denom;
                kept += p;
                uint32_t w = (uint32_t)(ents[k].key & 0xFFFF);
                float fp = (float)p;
                succbuf.append((const char*)&w, 4);
                succbuf.append((const char*)&fp, 4);
                ++cnt;
            }
        }
        double lam = 1.0 - kept;
        if (lam < 1e-12) lam = 1e-12;
        if (cnt == 0) {
            if (tri) { i = j; continue; }  // python: tri 空语境丢弃；bi 保留空行
            lam = 1.0;
        }

        if (n_written % cfg.stride == 0)
            index.emplace_back(ctxkey, (uint64_t)filepos);

        buf.clear();
        float fl = (float)lam;
        uint32_t c32 = (uint32_t)cnt;
        buf.append((const char*)&ctxkey, 8);
        buf.append((const char*)&fl, 4);
        buf.append((const char*)&c32, 4);
        buf.append(succbuf);
        fwrite(buf.data(), 1, buf.size(), F);
        filepos += buf.size();
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
            if (i + 1 >= argc) { fprintf(stderr, "%s 缺参数\n", argv[i]); exit(2); }
            return argv[++i];
        };
        if (a == "--corpus") cfg.corpus.push_back(need());
        else if (a == "--out") cfg.out = need();
        else if (a == "--min-tri-count") cfg.min_tri = (uint32_t)atoi(need().c_str());
        else if (a == "--min-bi-count") cfg.min_bi = (uint32_t)atoi(need().c_str());
        else if (a == "--min-sent-len") cfg.min_sent_len = (uint32_t)atoi(need().c_str());
        else if (a == "--discount") cfg.theta = atof(need().c_str());
        else if (a == "--stride") cfg.stride = (uint32_t)atoi(need().c_str());
        else if (a == "--ext-a") cfg.ext_a = true;
        else if (a == "--jobs") cfg.jobs = atoi(need().c_str());
        else if (a == "--chunk-mb") cfg.chunk_bytes = (size_t)atoi(need().c_str()) << 20;
        else { fprintf(stderr, "未知参数: %s\n", a.c_str()); return 2; }
    }
    if (cfg.corpus.empty() || cfg.out.empty()) {
        fprintf(stderr, "用法: fast_train --corpus DIR|FILE [--corpus …] --out out.bin "
                        "[--min-tri-count N] [--min-bi-count N] [--min-sent-len N] "
                        "[--discount d] [--stride N] [--ext-a] [--jobs N] [--chunk-mb N]\n");
        return 2;
    }
    if (cfg.stride < 16) { fprintf(stderr, "--stride 必须 >=16\n"); return 2; }
    if (!(cfg.theta > 0 && cfg.theta <= 1.0)) { fprintf(stderr, "--discount ∈ (0,1]\n"); return 2; }
    if (cfg.jobs < 1) cfg.jobs = 1;

    // ---- 收集文件（排序后按大小交错，让大文件均匀落不同 worker）----
    std::vector<std::pair<std::string, size_t>> files;
    uint64_t total_bytes = 0;
    for (auto& c : cfg.corpus) {
        fs::path cp(c);
        if (fs::is_directory(cp)) {
            for (auto& e : fs::recursive_directory_iterator(cp)) {
                if (!e.is_regular_file()) continue;
                std::string n = e.path().filename().string();
                std::string low = n;
                for (auto& ch : low) ch = (char)tolower(ch);
                bool txt = low.size() >= 4 &&
                           (low.substr(low.size() - 4) == ".txt" || low.substr(low.size() - 3) == ".md" ||
                            low.substr(low.size() - 5) == ".text");
                if (!n.empty() && n[0] == '.') continue;
                if (!txt) continue;
                size_t s = fs::file_size(e.path());
                files.emplace_back(e.path().string(), s);
                total_bytes += s;
            }
        } else if (fs::is_regular_file(cp)) {
            size_t s = fs::file_size(cp);
            files.emplace_back(cp.string(), s);
            total_bytes += s;
        } else fprintf(stderr, "跳过不存在: %s\n", c.c_str());
    }
    if (files.empty()) { fprintf(stderr, "没有语料文件\n"); return 2; }
    std::sort(files.begin(), files.end(),
              [](auto& x, auto& y) { return x.second != y.second ? x.second > y.second : x.first < y.first; });

    // ---- 工作块：大文件按 chunk 切（UTF-8 边界对齐），小文件整读 ----
    struct Chunk { std::string file; size_t foff, len; };
    std::vector<Chunk> chunks;
    for (auto& [fp, sz] : files) {
        if (cfg.chunk_bytes == 0 || sz <= cfg.chunk_bytes) { chunks.push_back({fp, 0, sz}); continue; }
        int fd = open(fp.c_str(), O_RDONLY);
        if (fd < 0) { fprintf(stderr, "打不开: %s\n", fp.c_str()); continue; }
        uint8_t* m = (uint8_t*)mmap(nullptr, sz, PROT_READ, MAP_PRIVATE, fd, 0);
        if (m == MAP_FAILED) { int e = errno; close(fd); fprintf(stderr, "mmap 失败(切块): %s len=%zu errno=%d %s\n", fp.c_str(), sz, e, strerror(e)); continue; }
        size_t pos = 0;
        while (pos < sz) {
            size_t end = std::min(pos + cfg.chunk_bytes, sz);
            if (end < sz) {
                // 优先对齐 LF（句子边界，与 python 按行切批语义一致）
                size_t scan = end, lf = std::min(sz, pos + cfg.chunk_bytes + ((size_t)4 << 20));
                while (scan < lf && m[scan] != '\n') ++scan;
                if (scan < lf) {
                    end = scan + 1;
                } else {
                    while (end < sz && (m[end] & 0xC0) == 0x80) ++end;
                }
            }
            chunks.push_back({fp, pos, end - pos});
            pos = end;
        }
        munmap(m, sz);
        close(fd);
    }
    printf("[1/4] 计数: %zu 文件 / %.2f GB, jobs=%d, 工作块 %zu 个, chunk=%.0fMB\n",
           files.size(), total_bytes / 1e9, cfg.jobs, chunks.size(), cfg.chunk_bytes / 1e6);
    fflush(stdout);

    // ---- 并行计数 ----
    std::vector<Shard> shards(cfg.jobs);
    std::atomic<size_t> next{0};
    std::atomic<uint64_t> done_bytes{0};
    std::atomic<bool> stop{false};
    auto t0 = std::chrono::steady_clock::now();

    std::thread heartbeat([&] {
        while (!stop.load()) {
            uint64_t d = done_bytes.load();
            double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            printf("\r      %.1f/%.1f GB (%zu%%)  %.0f MB/s   ", d / 1e9, total_bytes / 1e9,
                   total_bytes ? (size_t)(d * 100 / total_bytes) : 100,
                   el > 0 ? d / el / 1e6 : 0.0);
            fflush(stdout);
            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
        }
    });

    std::vector<std::thread> pool;
    for (int t = 0; t < cfg.jobs; ++t) {
        pool.emplace_back([&, t] {
            while (true) {
                size_t k = next.fetch_add(1);
                if (k >= chunks.size()) break;
                auto& ck = chunks[k];
                int fd = open(ck.file.c_str(), O_RDONLY);
                if (fd < 0) { fprintf(stderr, "\n打不开: %s\n", ck.file.c_str()); continue; }
                // mmap 偏移必须对齐到系统页大小——Apple Silicon 是 16 KB，
                // 硬编码 4096 会在 arm64 上返回 EINVAL。
                static const size_t PAGE = (size_t)sysconf(_SC_PAGESIZE);
                size_t pa = ck.foff & ~(PAGE - 1);
                size_t slack = ck.foff - pa;
                uint8_t* base = (uint8_t*)mmap(nullptr, ck.len + slack, PROT_READ, MAP_PRIVATE, fd, pa);
                if (base == MAP_FAILED) { int e = errno; close(fd); fprintf(stderr, "mmap 失败: %s off=%zu len=%zu errno=%d %s\n", ck.file.c_str(), ck.foff, ck.len, e, strerror(e)); continue; }
                uint8_t* m = base + slack;
                madvise(base, ck.len + slack, MADV_SEQUENTIAL);
                count_block(m, ck.len, cfg, shards[t]);
                munmap(base, ck.len + slack);
                close(fd);
                done_bytes += ck.len;
            }
        });
    }
    for (auto& th : pool) th.join();
    stop = true;
    heartbeat.join();
    double el_count = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("\r      计数完成 %.1f GB / %.0fs (%.0f MB/s)                    \n",
           total_bytes / 1e9, el_count, total_bytes / el_count / 1e6);

    // ---- 合并 ----
    uint64_t uni[0x10000] = {};
    HMap bi, tri;
    {
        size_t bi_want = 0, tri_want = 0;
        for (auto& sh : shards) { bi_want += sh.bi.sz; tri_want += sh.tri.sz; }
        bi.init(bi_want + 0x10000);
        tri.init(tri_want);
    }
    uint64_t n_sent = 0, n_chars = 0, bad = 0;
    for (auto& sh : shards) {
        for (int cp = 0; cp < 0x10000; ++cp) uni[cp] += sh.uni[cp];
        n_sent += sh.n_sent;
        n_chars += sh.n_chars;
        bad += sh.bad_utf8;
        for (size_t i = 0; i < sh.bi.cap; ++i)
            if (sh.bi.keys[i]) bi.add(sh.bi.keys[i], sh.bi.vals[i]);
        for (size_t i = 0; i < sh.tri.cap; ++i)
            if (sh.tri.keys[i]) tri.add(sh.tri.keys[i], sh.tri.vals[i]);
    }
    uint64_t total_tokens = 0;
    for (int cp = 0; cp < 0x10000; ++cp) total_tokens += uni[cp];
    printf("[2/4] 合并完成: 句子=%llu 字符=%llu tokens=%llu bi条目=%llu tri条目=%llu\n",
           (unsigned long long)n_sent, (unsigned long long)n_chars,
           (unsigned long long)total_tokens, (unsigned long long)bi.sz,
           (unsigned long long)tri.sz);
    if (bad) printf("      ⚠ 非法 UTF-8 %llu 处（按分句边界处理）\n", (unsigned long long)bad);
    if (!total_tokens) { fprintf(stderr, "清洗后为空\n"); return 1; }

    // ---- 导出 ----
    std::vector<Ent64> biV, triV;
    biV.reserve(bi.sz + 0x10000);
    triV.reserve(tri.sz);
    for (size_t i = 0; i < bi.cap; ++i)
        if (bi.keys[i]) biV.push_back({bi.keys[i], bi.vals[i]});
    for (size_t i = 0; i < tri.cap; ++i)
        if (tri.keys[i]) triV.push_back({tri.keys[i], tri.vals[i]});
    radix64(biV, 4);
    radix64(triV, 6);

    std::vector<uint32_t> vocab;
    vocab.reserve(0x8000);
    for (int cp = 1; cp < 0x10000; ++cp)
        if (uni[cp]) vocab.push_back((uint32_t)cp);

    // bi：词表中没有任何观察后继的字补空条目（保 bi_ctx ≥ 词表覆盖，与 python 一致）
    {
        std::vector<uint8_t> seen(0x10000, 0);
        for (auto& e : biV) seen[e.key >> 16] = 1;
        for (auto cp : vocab)
            if (!seen[cp]) biV.push_back({(uint64_t)cp << 16, 0});
        radix64(biV, 4);
    }

    FILE* F = fopen((cfg.out + ".tmp").c_str(), "wb");
    if (!F) { fprintf(stderr, "打不开输出: %s\n", cfg.out.c_str()); return 1; }
    const size_t HEADER = 104;
    fseeko(F, HEADER, SEEK_SET);

    // unigrams：<unk> = 词表最小概率兜底，全体归一
    {
        double floor_p = -1.0;
        for (auto cp : vocab) {
            double p = (double)uni[cp] / total_tokens;
            if (floor_p < 0 || p < floor_p) floor_p = p;
        }
        double sum = floor_p;
        for (auto cp : vocab) sum += (double)uni[cp] / total_tokens;
        std::string buf;
        buf.reserve((vocab.size() + 1) * 8);
        auto put = [&](uint32_t k, float p) {
            buf.append((const char*)&k, 4);
            buf.append((char*)&p, 4);
        };
        put(UNK, (float)(floor_p / sum));
        for (auto cp : vocab) put(cp, (float)((double)uni[cp] / total_tokens / sum));
        fwrite(buf.data(), 1, buf.size(), F);
    }
    size_t uni_off = HEADER;
    size_t bi_blocks = uni_off + (vocab.size() + 1) * 8;

    StreamResult B = stream(F, bi_blocks, biV, cfg.min_bi, false, cfg);
    size_t bi_index_off = B.index_off;                       // bi blocks 尾 = bi index
    size_t bi_idx_cnt = B.ctx_count == 0 ? 0 : (B.ctx_count + cfg.stride - 1) / cfg.stride;
    // 实际写入的索引条数以 stream 记录为准
    bi_idx_cnt = B.index_written;
    size_t tri_blocks = bi_index_off + bi_idx_cnt * 16;
    StreamResult T = stream(F, tri_blocks, triV, cfg.min_tri, true, cfg);
    size_t tri_index_off = T.index_off;
    size_t tri_idx_cnt = T.index_written;
    size_t total = tri_index_off + tri_idx_cnt * 16;

    char h[HEADER] = {};
    memcpy(h, "TCSKNM02", 8);
    uint32_t v32 = 1, hs = HEADER, st = cfg.stride,
             uc = (uint32_t)(vocab.size() + 1);
    uint64_t ts = total, uoff = uni_off;
    uint32_t bc32 = (uint32_t)B.ctx_count, bi_idx32 = (uint32_t)bi_idx_cnt;
    uint64_t bblocks = bi_blocks, bidxoff = bi_index_off;
    uint32_t tc32 = (uint32_t)T.ctx_count, ti_idx32 = (uint32_t)tri_idx_cnt;
    uint64_t tblocks = tri_blocks, tidxoff = tri_index_off;
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
    fseeko(F, 0, SEEK_SET);
    fwrite(h, 1, HEADER, F);
    fclose(F);
    rename((cfg.out + ".tmp").c_str(), cfg.out.c_str());

    printf("[3/4] 导出 %llu 字节（%.0f MB）uni=%u bi_ctx=%llu bi_idx=%zu tri_ctx=%llu tri_idx=%zu\n",
           (unsigned long long)total, total / 1048576.0, uc,
           (unsigned long long)B.ctx_count, bi_idx_cnt,
           (unsigned long long)T.ctx_count, tri_idx_cnt);
    printf("[4/4] 总耗时 %.0fs。请校验: python3 tools/ngram/verify_ngram.py --model %s --full\n",
           std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(),
           cfg.out.c_str());
    return 0;
}
