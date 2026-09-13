//
//  LearningSerialization.swift
//  Fire
//
//  学习数据（通道 B：字符级用户 n-gram）的 TCSKNM02 分页格式导入导出。
//
//  结构与 sentence-ngram-mobile.bin 完全一致（同一读取器可解析）：
//    [0,104)      头部（magic TCSKNM02 / version=1 / headerSize=104 /
//                 declaredSize / stride=64 / 五组分节计数与偏移，
//                 36/44/76/84 为 4 字节填充，与真实模型文件一致）
//    [104,·)      unigram 表：(u32 key, f32 值) 有序；首条 key=0 为
//                 unknown 兜底（值 1e-8），与真实模型同约定
//    [·,biBlocks) bigram 页：连续 (u64 ctxKey, f32 λ, u32 succCount)
//                 + succCount × (u32 target, f32 值)；每页 stride 个上下文
//    [·,·+16)     bigram 稀疏索引：(u64 首上下文 key, u64 页偏移)
//    [·,triIndexOff) trigram 页（ctxKey = pack2(prev2, prev1)）
//    [·,fileSize) trigram 稀疏索引
//
//  字段语义差异（有意为之）：prob 字段存计数、λ 字段存上下文总量，
//  而非归一化概率/插值权重——导入需要无损还原计数（α 置信度门控依赖
//  绝对量级，归一化会丢失）。因此该文件是学习数据交换格式，不应通过
//  sentenceModelPath 当通用语言模型加载。
//
//  f32 计数在 2^24 内整数精确，衰减产生的分数计数误差 ~1e-7 相对精度。
//

import Foundation
import Defaults

enum LearningSerializationError: LocalizedError {
    case badMagic
    case unsupportedVersion(UInt32)
    case badHeaderSize(UInt32)
    case sizeMismatch(UInt64, Int)
    case badLayout(String)
    case truncated(String)

    var errorDescription: String? {
        switch self {
        case .badMagic: return "不是 TCSKNM02 格式文件"
        case .unsupportedVersion(let v): return "不支持的格式版本：\(v)"
        case .badHeaderSize(let s): return "头大小异常：\(s)"
        case .sizeMismatch(let expect, let actual):
            return "文件大小不符：声明 \(expect)，实际 \(actual)"
        case .badLayout(let why): return "分节布局异常：\(why)"
        case .truncated(let what): return "数据不完整：\(what)"
        }
    }
}

enum UserNgramBinary {
    static let magic = "TCSKNM02"
    static let headerSize = 104
    /// 每页上下文数（与真实模型文件的 stride=64 同约定）
    static let stride: UInt32 = 64
    static let shift: UInt64 = 2_097_152
    static let mask: UInt64 = shift - 1
    /// unknown 兜底值（真实模型同量级）
    static let unknownProbability: Float = 1e-8

    // MARK: - 导出

    /// 把字符 n-gram 计数写成 TCSKNM02 分页结构。
    /// 上下文按 key 升序、后继按 target 升序；空分节垫 8 字节以满足
    /// 读取器的严格不等式（biBlocks < biIndexOff < triBlocks < triIndexOff）。
    static func export(_ store: UserCharNgramStore) -> Data {
        // ---- 收集与排序 ----
        // unigram：跳过结构键（0=unknown / 2=BOS / 3=EOS，正文不会出现）
        let unigrams: [(key: UInt32, count: Double)] = store.unigrams
            .filter { $0.value > 0 && $0.key >= 4 }
            .map { ($0.key, $0.value) }
            .sorted { $0.key < $1.key }

        struct BiContext {
            var ctx: UInt32
            var total: Double
            var succs: [(target: UInt32, count: Double)]
        }
        var biByCtx: [UInt32: [(UInt32, Double)]] = [:]
        for (key, count) in store.bigrams where count > 0 {
            let target = UInt32(truncatingIfNeeded: key & mask)
            let prev1 = UInt32(truncatingIfNeeded: key >> 21)
            biByCtx[prev1, default: []].append((target, count))
        }
        let biContexts: [BiContext] = biByCtx.map { ctx, succs in
            BiContext(ctx: ctx,
                      total: store.bigramTotals[ctx] ?? succs.reduce(0) { $0 + $1.1 },
                      succs: succs.map { ($0.0, $0.1) }.sorted { $0.0 < $1.0 })
        }.sorted { $0.ctx < $1.ctx }

        struct TriContext {
            var ctxKey: UInt64
            var total: Double
            var succs: [(target: UInt32, count: Double)]
        }
        var triByCtx: [UInt64: [(UInt32, Double)]] = [:]
        for (key, count) in store.trigrams where count > 0 {
            let target = UInt32(truncatingIfNeeded: key & mask)
            let ctxKey = key >> 21 // pack2(prev2, prev1)
            triByCtx[ctxKey, default: []].append((target, count))
        }
        let triContexts: [TriContext] = triByCtx.map { ctxKey, succs in
            TriContext(ctxKey: ctxKey,
                       total: store.trigramTotals[ctxKey] ?? succs.reduce(0) { $0 + $1.1 },
                       succs: succs.map { ($0.0, $0.1) }.sorted { $0.0 < $1.0 })
        }.sorted { $0.ctxKey < $1.ctxKey }

        // ---- 布局计算 ----
        let uniCount = UInt32(1 + unigrams.count) // key=0 兜底条 + 真实条目
        let uniEnd = UInt64(headerSize) + UInt64(uniCount) * 8
        let biDataSize = biContexts.reduce(0) { $0 + 16 + UInt64($1.succs.count) * 8 }
        let biPageCount = biContexts.isEmpty
            ? 0 : UInt32((biContexts.count + Int(stride) - 1) / Int(stride))
        // 空分节垫 8 字节，保证严格不等式成立
        let biIndexOff = uniEnd + biDataSize + (biDataSize == 0 ? 8 : 0)
        let biIndexEnd = biIndexOff + UInt64(biPageCount) * 16
        let triDataSize = triContexts.reduce(0) { $0 + 16 + UInt64($1.succs.count) * 8 }
        let triPageCount = triContexts.isEmpty
            ? 0 : UInt32((triContexts.count + Int(stride) - 1) / Int(stride))
        let triIndexOff = biIndexEnd + triDataSize + (triDataSize == 0 ? 8 : 0)
        let fileSize = triIndexOff + UInt64(triPageCount) * 16

        // ---- 写出 ----
        var out = Data()
        out.reserveCapacity(Int(fileSize))
        putMagic(&out)
        putU32(&out, 1)                                 // version
        putU32(&out, UInt32(headerSize))                // headerSize
        putU64(&out, fileSize)                          // declaredSize
        putU32(&out, stride)                            // stride
        putU32(&out, 0)                                 // pad 28
        putU32(&out, uniCount)                          // uniCnt
        putU32(&out, 0)                                 // pad 36
        putU32(&out, UInt32(headerSize))                // uniOff
        putU32(&out, 0)                                 // pad 44
        putU32(&out, UInt32(biContexts.count))          // biCtx
        putU32(&out, biPageCount)                       // biIdx
        putU64(&out, uniEnd)                            // biBlocks（uni 表结束 = bi 页起点）
        putU64(&out, biIndexOff)
        putU32(&out, UInt32(triContexts.count))         // triCtx
        putU32(&out, 0)                                 // pad 76
        putU32(&out, triPageCount)                      // triIdx
        putU32(&out, 0)                                 // pad 84
        putU64(&out, biIndexEnd)                        // triBlocks（bi 索引结束 = tri 页起点）
        putU64(&out, triIndexOff)
        precondition(out.count == headerSize)

        // unigram：key=0 unknown 兜底 + 有序真实条目
        putU32(&out, 0)
        putF32(&out, unknownProbability)
        for entry in unigrams {
            putU32(&out, entry.key)
            putF32(&out, Float(entry.count))
        }
        // bigram 页 + 索引
        var biIndex: [(key: UInt64, offset: UInt64)] = []
        if !biContexts.isEmpty {
            var position = out.count
            for (index, context) in biContexts.enumerated() {
                if index % Int(stride) == 0 {
                    biIndex.append((UInt64(context.ctx), UInt64(position)))
                }
                putU64(&out, UInt64(context.ctx))
                putF32(&out, Float(context.total))
                putU32(&out, UInt32(context.succs.count))
                for succ in context.succs {
                    putU32(&out, succ.target)
                    putF32(&out, Float(succ.count))
                }
                position = out.count
            }
        }
        for entry in biIndex {
            putU64(&out, entry.key)
            putU64(&out, entry.offset)
        }
        // trigram 页 + 索引
        var triIndex: [(key: UInt64, offset: UInt64)] = []
        if !triContexts.isEmpty {
            var position = out.count
            for (index, context) in triContexts.enumerated() {
                if index % Int(stride) == 0 {
                    triIndex.append((context.ctxKey, UInt64(position)))
                }
                putU64(&out, context.ctxKey)
                putF32(&out, Float(context.total))
                putU32(&out, UInt32(context.succs.count))
                for succ in context.succs {
                    putU32(&out, succ.target)
                    putF32(&out, Float(succ.count))
                }
                position = out.count
            }
        }
        for entry in triIndex {
            putU64(&out, entry.key)
            putU64(&out, entry.offset)
        }
        precondition(out.count == Int(fileSize))
        return out
    }

    // MARK: - 解析与导入

    struct ParsedBlob {
        var unigrams: [(key: UInt32, count: Double)] = []
        var bigramTotals: [UInt32: Double] = [:]
        var bigrams: [UInt64: Double] = [:]
        var trigramTotals: [UInt64: Double] = [:]
        var trigrams: [UInt64: Double] = [:]
    }

    /// 解析 TCSKNM02 结构（镜像 NgramModel.load 的全部校验与分页遍历）。
    /// prob 字段按计数解释；key 0/2/3（unknown/BOS/EOS）不入学习数据。
    static func parse(_ data: Data) throws -> ParsedBlob {
        guard data.count >= headerSize else {
            throw LearningSerializationError.truncated("文件不足 \(headerSize) 字节")
        }
        var blob = ParsedBlob()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else {
                throw LearningSerializationError.truncated("空文件")
            }
            func readU32(_ offset: Int) -> UInt32 {
                var value: UInt32 = 0
                withUnsafeMutableBytes(of: &value) { dest in
                    memcpy(dest.baseAddress!, base.advanced(by: offset), 4)
                }
                return value.littleEndian
            }
            func readU64(_ offset: Int) -> UInt64 {
                var value: UInt64 = 0
                withUnsafeMutableBytes(of: &value) { dest in
                    memcpy(dest.baseAddress!, base.advanced(by: offset), 8)
                }
                return value.littleEndian
            }
            func readF32(_ offset: Int) -> Float {
                Float(bitPattern: readU32(offset))
            }

            let magicBytes = Array(magic.utf8)
            for i in 0..<8 where base.load(fromByteOffset: i, as: UInt8.self) != magicBytes[i] {
                throw LearningSerializationError.badMagic
            }
            let version = readU32(8)
            guard version == 1 else { throw LearningSerializationError.unsupportedVersion(version) }
            let headerSizeRead = readU32(12)
            guard headerSizeRead == UInt32(headerSize) else {
                throw LearningSerializationError.badHeaderSize(headerSizeRead)
            }
            let declaredSize = readU64(16)
            guard declaredSize == UInt64(data.count) else {
                throw LearningSerializationError.sizeMismatch(declaredSize, data.count)
            }
            let strideRead = readU32(24)
            guard strideRead >= 16 else {
                throw LearningSerializationError.badLayout("stride \(strideRead) < 16")
            }
            let uniCnt = Int(readU32(32))
            let uniOff = Int(readU32(40))
            let biCtx = Int(readU32(48))
            let biIdx = Int(readU32(52))
            let biBlocks = Int(readU64(56))
            let biIndexOff = Int(readU64(64))
            let triCtx = Int(readU32(72))
            let triIdx = Int(readU32(80))
            let triBlocks = Int(readU64(88))
            let triIndexOff = Int(readU64(96))

            guard strideRead >= 16, biBlocks < biIndexOff,
                  biIndexOff < triBlocks, triBlocks < triIndexOff else {
                throw LearningSerializationError.badLayout(
                    "biBlocks=\(biBlocks) biIndex=\(biIndexOff) triBlocks=\(triBlocks) triIndex=\(triIndexOff)")
            }
            guard declaredSize == UInt64(data.count) else {
                throw LearningSerializationError.sizeMismatch(declaredSize, data.count)
            }
            guard uniOff + uniCnt * 8 <= biBlocks,
                  biIndexOff + biIdx * 16 <= triBlocks,
                  triIndexOff + triIdx * 16 <= data.count else {
                throw LearningSerializationError.badLayout("分节越界")
            }

            // unigram 表
            for i in 0..<uniCnt {
                let at = uniOff + i * 8
                let key = readU32(at)
                let value = Double(readF32(at + 4))
                guard key >= 4, value > 0 else { continue } // 0/2/3 结构键跳过
                blob.unigrams.append((key, value))
            }

            // 按索引遍历页（与 lookupContext 的页边界语义一致）
            func walkPages(indexOffset: Int, indexCount: Int, sectionEnd: Int,
                           contextCount: Int, isTri: Bool) throws {
                var previousKeys = Set<UInt64>()
                for page in 0..<indexCount {
                    let pageOffset = Int(readU64(indexOffset + page * 16 + 8))
                    let pageEnd = page + 1 < indexCount
                        ? Int(readU64(indexOffset + (page + 1) * 16 + 8)) : sectionEnd
                    var position = pageOffset
                    let limit = Swift.min(Int(strideRead), contextCount - page * Int(strideRead))
                    var scanned = 0
                    while scanned < limit {
                        guard position + 16 <= pageEnd, position + 16 <= data.count else {
                            throw LearningSerializationError.truncated(isTri ? "tri 页" : "bi 页")
                        }
                        let ctxKey = readU64(position)
                        let total = Double(readF32(position + 8))
                        let succCount = Int(readU32(position + 12))
                        var cursor = position + 16
                        guard cursor + succCount * 8 <= pageEnd, cursor + succCount * 8 <= data.count else {
                            throw LearningSerializationError.truncated(isTri ? "tri 后继" : "bi 后继")
                        }
                        for _ in 0..<succCount {
                            let target = readU32(cursor)
                            let count = Double(readF32(cursor + 4))
                            cursor += 8
                            guard count > 0 else { continue }
                            if isTri {
                                blob.trigrams[NgramModel.pack3(ctxKey >> 21, ctxKey & mask, UInt64(target))] = count
                            } else {
                                blob.bigrams[NgramModel.pack2(ctxKey, UInt64(target))] = count
                            }
                        }
                        if isTri {
                            guard ctxKey >> 21 < shift, ctxKey & mask < shift, previousKeys.insert(ctxKey).inserted else {
                                throw LearningSerializationError.badLayout("tri 上下文 key 越界或重复")
                            }
                            blob.trigramTotals[ctxKey] = total
                        } else {
                            guard ctxKey < shift, previousKeys.insert(ctxKey).inserted else {
                                throw LearningSerializationError.badLayout("bi 上下文 key 越界或重复")
                            }
                            blob.bigramTotals[UInt32(truncatingIfNeeded: ctxKey)] = total
                        }
                        position = cursor
                        scanned += 1
                    }
                }
            }
            try walkPages(indexOffset: biIndexOff, indexCount: biIdx,
                          sectionEnd: biIndexOff, contextCount: biCtx, isTri: false)
            try walkPages(indexOffset: triIndexOff, indexCount: triIdx,
                          sectionEnd: triIndexOff, contextCount: triCtx, isTri: true)
        }
        return blob
    }

    /// 从 TCSKNM02 数据重建通道 B 存储（计数语义）。
    /// 衰减纪元从导入日起算（导出侧的计数已衰减到导出日）。
    static func importStore(from data: Data) throws -> UserCharNgramStore {
        let blob = try parse(data)
        var uni: [UInt32: Double] = [:]
        var total = 0.0
        for (key, count) in blob.unigrams {
            uni[key] = count
            total += count
        }
        let store = UserCharNgramStore()
        store.importCounts(unigrams: uni,
                           bigrams: blob.bigrams,
                           bigramTotals: blob.bigramTotals,
                           trigrams: blob.trigrams,
                           trigramTotals: blob.trigramTotals,
                           unigramTotal: total,
                           lastDecayDay: learningDayNumber())
        return store
    }

    // MARK: - 二进制写出原语

    private static func putU32(_ out: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }

    private static func putU64(_ out: inout Data, _ value: UInt64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }

    private static func putF32(_ out: inout Data, _ value: Float) {
        putU32(&out, value.bitPattern)
    }

    private static func putMagic(_ out: inout Data) {
        out.append(contentsOf: Array(magic.utf8))
    }
}

// MARK: - 自检（CLI --learning-selftest）

enum LearningSelfTest {
    /// 合成计数 → 导出 → 导入比对 + 用真实 NgramModel 读取器交叉验证。
    @discardableResult
    static func run() -> Int32 {
        // 1. 合成 store：已知计数（含分数衰减值）
        let source = UserCharNgramStore()
        let de = UInt32(0x7684) // 的
        let shi = UInt32(0x662F) // 是
        let wo = UInt32(0x6211) // 我
        source.importCounts(
            unigrams: [de: 100.5, shi: 50, wo: 25],
            bigrams: [NgramModel.pack2(UInt64(de), UInt64(shi)): 10,
                      NgramModel.pack2(UInt64(wo), UInt64(de)): 5],
            bigramTotals: [de: 30, wo: 8],
            trigrams: [NgramModel.pack3(UInt64(wo), UInt64(de), UInt64(shi)): 3],
            trigramTotals: [NgramModel.pack2(UInt64(wo), UInt64(de)): 6],
            unigramTotal: 175.5,
            lastDecayDay: learningDayNumber())

        // 2. 导出 → 导入 → 逐字段比对
        let data = UserNgramBinary.export(source)
        guard let imported = try? UserNgramBinary.importStore(from: data) else {
            print("[LearningSelfTest] FAIL: 导入解析失败")
            return 1
        }
        var ok = true
        func expect(_ name: String, _ left: Double, _ right: Double) {
            if abs(left - right) > 1e-3 {
                print("[LearningSelfTest] FAIL: \(name) 导出前 \(left) ≠ 导入后 \(right)")
                ok = false
            }
        }
        for (key, count) in source.unigrams {
            expect("uni(\(key))", count, imported.unigrams[key] ?? -1)
        }
        for (key, count) in source.bigrams {
            expect("bi(\(key))", count, imported.bigrams[key] ?? -1)
        }
        for (key, count) in source.bigramTotals {
            expect("biTotal(\(key))", count, imported.bigramTotals[key] ?? -1)
        }
        for (key, count) in source.trigrams {
            expect("tri(\(key))", count, imported.trigrams[key] ?? -1)
        }
        for (key, count) in source.trigramTotals {
            expect("triTotal(\(key))", count, imported.trigramTotals[key] ?? -1)
        }
        // 幂等：导出 → 导入 → 再导出，字节应完全一致
        let reexport = UserNgramBinary.export(imported)
        if reexport != data {
            print("[LearningSelfTest] FAIL: 二次导出字节不一致（\(data.count) vs \(reexport.count)）")
            ok = false
        }

        // 3. 交叉验证：让真实 NgramModel 读取器加载导出文件，
        //    exp(logp) 应精确等于计数语义的组合值
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fire-learning-selftest-\(UUID().uuidString).bin")
        do {
            try data.write(to: tempURL)
            let originalPath = Defaults[.sentenceModelPath]
            defer {
                Defaults[.sentenceModelPath] = originalPath
                try? FileManager.default.removeItem(at: tempURL)
                NgramModel.shared.reload()
            }
            Defaults[.sentenceModelPath] = tempURL.path
            NgramModel.shared.reload()
            guard NgramModel.shared.loaded else {
                print("[LearningSelfTest] FAIL: NgramModel 无法加载导出文件：\(NgramModel.shared.loadError ?? "?")")
                return 1
            }
            // p(是|我,的)：tri 命中 → exp(logp) = c3 + t3·(c2 + t2·c1)
            //             = 3 + 6·(10 + 30·50) = 9063
            let p1 = NgramModel.shared.logp(prev2: wo, prev1: de, target: shi)
            let expect1 = 3.0 + 6.0 * (10.0 + 30.0 * 50.0)
            if abs(Foundation.exp(p1) - expect1) / expect1 > 1e-5 {
                print("[LearningSelfTest] FAIL: exp(logp(是|我,的))=\(Foundation.exp(p1)) 期望 \(expect1)")
                ok = false
            }
            // p(的|bos,我)：tri 缺失 → λ=1 退到 bi → exp = c2 + t2·c1 = 5 + 8·100.5
            let p2 = NgramModel.shared.logp(prev2: NgramModel.bos, prev1: wo, target: de)
            let expect2 = 5.0 + 8.0 * 100.5
            if abs(Foundation.exp(p2) - expect2) / expect2 > 1e-5 {
                print("[LearningSelfTest] FAIL: exp(logp(的|bos,我))=\(Foundation.exp(p2)) 期望 \(expect2)")
                ok = false
            }
            // p(我|bos,的)：bi 无 (的→我) 后继 → exp = t2·c1 = 30·25
            let p3 = NgramModel.shared.logp(prev2: NgramModel.bos, prev1: de, target: wo)
            let expect3 = 30.0 * 25.0
            if abs(Foundation.exp(p3) - expect3) / expect3 > 1e-5 {
                print("[LearningSelfTest] FAIL: exp(logp(我|bos,的))=\(Foundation.exp(p3)) 期望 \(expect3)")
                ok = false
            }
        } catch {
            print("[LearningSelfTest] FAIL: \(error)")
            return 1
        }

        print(ok ? "[LearningSelfTest] PASS（合成计数往返一致 + NgramModel 读取器交叉验证通过）"
                 : "[LearningSelfTest] FAIL")
        return ok ? 0 : 1
    }
}
