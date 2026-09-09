//
//  NgramModel.swift
//  Fire
//
//  整句 n-gram 模型读取（移植虎整句 tiger_sentence.lua `kn_reader.load_mobile`）。
//  TCSKNM02 分页格式：整个文件只读 mmap，unigram 与 bi/tri 稀疏索引常驻内存，
//  页内数据交给内核按需换页——不再自建 LRU 页缓存（Lua 那 8MB 缓存是给 fseek 用的）。
//

import Foundation
import Defaults

private let kNgramMagic = "TCSKNM02"
private let kNgramHeaderSize = 104
private let kContextCacheEntries = 16384

/// 小端读取辅助：memcpy 到本地值，避免未对齐直接 load。
@inline(__always)
private func readLE<T: FixedWidthInteger>(_ base: UnsafeRawPointer, _ offset: Int, _ type: T.Type) -> T {
    var value: T = 0
    withUnsafeMutableBytes(of: &value) { raw in
        memcpy(raw.baseAddress!, base.advanced(by: offset), MemoryLayout<T>.size)
    }
    return value
}

@inline(__always)
private func readFloatLE(_ base: UnsafeRawPointer, _ offset: Int) -> Float {
    return Float(bitPattern: readLE(base, offset, UInt32.self))
}

/// 上下文块定位信息（bi 或 tri 的一个 context：lambda + 后继表位置）
private struct ContextEntry {
    var missing: Bool
    var lambda: Float
    var successorOffset: Int
    var successorCount: Int

    static let missing = ContextEntry(missing: true, lambda: 1.0, successorOffset: 0, successorCount: 0)
}

final class NgramModel {
    static let shared = NgramModel()

    private(set) var loaded: Bool = false
    private(set) var loadedPath: String?
    private(set) var loadError: String?
    private(set) var modelBytes: UInt64 = 0
    /// 常驻索引字节数（诊断用）
    private(set) var residentIndexBytes: Int = 0

    private var mmapBase: UnsafeMutableRawPointer?
    private var mmapLength: Int = 0
    private var fileDescriptor: Int32 = -1

    // 头部字段
    private var biIndexCount: Int = 0
    private var biIndexOffset: Int = 0
    private var biCtxCount: Int = 0
    private var triIndexCount: Int = 0
    private var triIndexOffset: Int = 0
    private var triCtxCount: Int = 0
    private var indexStride: Int = 0

    /// 词表里没有的字用的 unigram 概率（模型第一项，与 Lua unknown 一致）
    private var unknownProbability: Float = 0.0

    private var unigrams: [(key: UInt32, prob: Float)] = []
    private var biIndex: [(key: UInt64, offset: UInt64)] = []
    private var triIndex: [(key: UInt64, offset: UInt64)] = []

    // context / logp 环形缓存（移植虎整句 context_caches、logp_cache）
    private var biContextCache: [UInt64: ContextEntry] = [:]
    private var biContextCacheKeys: [UInt64] = []
    private var biContextCacheNext = 0
    private var triContextCache: [UInt64: ContextEntry] = [:]
    private var triContextCacheKeys: [UInt64] = []
    private var triContextCacheNext = 0

    private var logpCache: [UInt64: Double] = [:]
    private var logpCacheKeys: [UInt64] = []
    private var logpCacheNext = 0

    static let shift: UInt64 = 2097152 // 2^21，与 Lua SHIFT 一致
    static let bos: UInt32 = 0x02
    static let eos: UInt32 = 0x03

    private init() {}

    deinit {
        unload()
    }

    // MARK: - 加载

    /// 懒加载。解析顺序：设置指定路径 → Bundle Resources → Application Support 覆盖。
    func ensureLoaded() {
        if loaded || loadError != nil { return }
        load()
    }

    func reload() {
        unload()
        load()
    }

    func statusText() -> String {
        if loaded {
            return String(format: "已加载 · %.0f MB · 常驻索引 %.1f MB",
                          Double(modelBytes) / 1048576.0,
                          Double(residentIndexBytes) / 1048576.0)
        }
        return "未加载：\(loadError ?? "尚未尝试")"
    }

    private func candidatePaths() -> [String] {
        var paths: [String] = []
        let override = Defaults[.sentenceModelPath]
        if !override.isEmpty {
            paths.append(override)
        }
        if let resourceURL = Bundle.main.resourceURL {
            paths.append(resourceURL.appendingPathComponent("sentence-ngram-mobile.bin").path)
        }
        if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(supportDir
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Fire")
                .appendingPathComponent("sentence-ngram-mobile.bin").path)
        }
        return paths
    }

    private func load() {
        for path in candidatePaths() where FileManager.default.fileExists(atPath: path) {
            do {
                try load(path: path)
                loaded = true
                loadedPath = path
                loadError = nil
                NSLog("[NgramModel] loaded %@ (%.0f MB, resident index %.2f MB)", path,
                      Double(modelBytes) / 1048576.0, Double(residentIndexBytes) / 1048576.0)
                return
            } catch let error as NgramModelError {
                loadError = error.description
                NSLog("[NgramModel] load %@ failed: %@", path, error.description)
            } catch {
                loadError = "\(path): \(error.localizedDescription)"
                NSLog("[NgramModel] load %@ failed: %@", path, "\(error)")
            }
        }
        if loadError == nil {
            loadError = "未找到 sentence-ngram-mobile.bin"
        }
    }

    enum NgramModelError: Error {
        case cannotOpen(String)
        case mmapFailed(String)
        case notTCSKNM02
        case unsupportedVersion(String)
        case invalidLayout(String)
        case sizeMismatch(UInt64, UInt64)

        var description: String {
            switch self {
            case .cannotOpen(let path): return "cannot open n-gram: \(path)"
            case .mmapFailed: return "mmap failed"
            case .notTCSKNM02: return "not a TCSKNM02 model"
            case .unsupportedVersion(let v): return "unsupported mobile n-gram version: \(v)"
            case .invalidLayout(let l): return "invalid mobile layout: \(l)"
            case .sizeMismatch(let expect, let actual):
                return "size mismatch: expect \(expect), actual \(actual)"
            }
        }
    }

    private func load(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw NgramModelError.cannotOpen(path) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw NgramModelError.cannotOpen(path)
        }
        let fileSize = Int(st.st_size)
        guard fileSize >= kNgramHeaderSize else {
            close(fd)
            throw NgramModelError.sizeMismatch(UInt64(kNgramHeaderSize), UInt64(fileSize))
        }

        let mapped = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fd, 0)
        // mmap 失败返回 MAP_FAILED(-1)，Swift 桥接成非 nil 指针，guard let 抓不住
        guard mapped != MAP_FAILED, let base = mapped else {
            let err = errno
            close(fd)
            throw NgramModelError.mmapFailed("errno=\(err) \(String(cString: strerror(err)))")
        }

        do {
            // magic：8 字节 ASCII，直接逐字节比
            let magicPointer = base.assumingMemoryBound(to: UInt8.self)
            let expected = Array(kNgramMagic.utf8)
            var magicMatches = true
            for i in 0..<8 where magicPointer[i] != expected[i] {
                magicMatches = false
            }
            guard magicMatches else {
                throw NgramModelError.notTCSKNM02
            }

            let version = readLE(base, 8, UInt32.self)
            let headerSize = readLE(base, 12, UInt32.self)
            let declaredSize = readLE(base, 16, UInt64.self)
            let stride = readLE(base, 24, UInt32.self)
            let uniCnt = Int(readLE(base, 32, UInt32.self))
            let uniOff = Int(readLE(base, 40, UInt32.self))
            let biCtx = Int(readLE(base, 48, UInt32.self))
            let biIdx = Int(readLE(base, 52, UInt32.self))
            let biBlocks = Int(readLE(base, 56, UInt64.self))
            let biIndexOff = Int(readLE(base, 64, UInt64.self))
            let triCtx = Int(readLE(base, 72, UInt32.self))
            let triIdx = Int(readLE(base, 80, UInt32.self))
            let triBlocks = Int(readLE(base, 88, UInt64.self))
            let triIndexOff = Int(readLE(base, 96, UInt64.self))

            guard version == 1, headerSize == UInt32(kNgramHeaderSize) else {
                throw NgramModelError.unsupportedVersion("v\(version)/headerSize\(headerSize)")
            }
            guard stride >= 16, biBlocks < biIndexOff, biIndexOff < triBlocks, triBlocks < triIndexOff else {
                throw NgramModelError.invalidLayout(
                    "biBlocks=\(biBlocks) biIndex=\(biIndexOff) triBlocks=\(triBlocks) triIndex=\(triIndexOff)")
            }
            guard declaredSize == UInt64(fileSize) else {
                throw NgramModelError.sizeMismatch(declaredSize, UInt64(fileSize))
            }
            guard uniOff + uniCnt * 8 <= biBlocks,
                  biIndexOff + biIdx * 16 <= triBlocks,
                  triIndexOff + triIdx * 16 <= fileSize else {
                throw NgramModelError.invalidLayout("section overflow")
            }

            self.biCtxCount = biCtx
            self.biIndexCount = biIdx
            self.biIndexOffset = biIndexOff
            self.triCtxCount = triCtx
            self.triIndexCount = triIdx
            self.triIndexOffset = triIndexOff
            self.indexStride = Int(stride)

            // 常驻：unigram 表 + bi/tri 稀疏索引（页数据留在 mmap 由内核换页）
            var uni: [(key: UInt32, prob: Float)] = []
            uni.reserveCapacity(uniCnt)
            for i in 0..<uniCnt {
                let at = uniOff + i * 8
                uni.append((readLE(base, at, UInt32.self), readFloatLE(base, at + 4)))
            }
            guard !uni.isEmpty else {
                throw NgramModelError.invalidLayout("empty unigrams")
            }
            unigrams = uni
            unknownProbability = uni[0].prob

            var biList: [(key: UInt64, offset: UInt64)] = []
            biList.reserveCapacity(biIdx)
            for i in 0..<biIdx {
                let at = biIndexOff + i * 16
                biList.append((readLE(base, at, UInt64.self), readLE(base, at + 8, UInt64.self)))
            }
            biIndex = biList

            var triList: [(key: UInt64, offset: UInt64)] = []
            triList.reserveCapacity(triIdx)
            for i in 0..<triIdx {
                let at = triIndexOff + i * 16
                triList.append((readLE(base, at, UInt64.self), readLE(base, at + 8, UInt64.self)))
            }
            triIndex = triList

            residentIndexBytes = uniCnt * 8 + biIdx * 16 + triIdx * 16
            modelBytes = declaredSize

            mmapBase = base
            mmapLength = fileSize
            fileDescriptor = fd
        } catch {
            munmap(base, fileSize)
            close(fd)
            throw error
        }
    }

    private func unload() {
        if let base = mmapBase {
            munmap(base, mmapLength)
            mmapBase = nil
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        unigrams.removeAll()
        biIndex.removeAll()
        triIndex.removeAll()
        biContextCache.removeAll()
        biContextCacheKeys.removeAll()
        triContextCache.removeAll()
        triContextCacheKeys.removeAll()
        logpCache.removeAll()
        logpCacheKeys.removeAll()
        biContextCacheNext = 0
        triContextCacheNext = 0
        logpCacheNext = 0
        loaded = false
        loadedPath = nil
    }

    // MARK: - 查询

    /// 与 Lua pack2 一致：first * 2^21 + second % 2^21
    static func pack2(_ first: UInt64, _ second: UInt64) -> UInt64 {
        return first &* shift + (second % shift)
    }

    static func pack3(_ first: UInt64, _ second: UInt64, _ third: UInt64) -> UInt64 {
        return pack2(first, second) &* shift + (third % shift)
    }

    private func lookupUnigram(_ key: UInt32) -> Float {
        var low = 0
        var high = unigrams.count
        while low < high {
            let middle = low + (high - low) / 2
            if unigrams[middle].key < key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < unigrams.count, unigrams[low].key == key {
            return unigrams[low].prob
        }
        return unknownProbability
    }

    /// 在稀疏索引里找 ≤ key 的最后一页（Lua find_page）
    private func findPage(_ index: [(key: UInt64, offset: UInt64)], _ key: UInt64) -> Int {
        var low = 0
        var high = index.count
        while low < high {
            let middle = low + (high - low) / 2
            if index[middle].key <= key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low - 1
    }

    /// 定位一个 context（bi: key=prev 码点；tri: key=pack2(prev2, prev1)）。
    /// 命中后缓存 lambda 与后继表位置；页内容由内核按需换页。
    private func lookupContext(tri: Bool, key: UInt64) -> ContextEntry {
        guard let base = mmapBase else { return .missing }

        if let cached = (tri ? triContextCache : biContextCache)[key] {
            return cached
        }

        let index = tri ? triIndex : biIndex
        let indexCount = tri ? triIndexCount : biIndexCount
        let contextCount = tri ? triCtxCount : biCtxCount
        let sectionEnd = tri ? triIndexOffset : biIndexOffset

        var entry = ContextEntry.missing
        let page = findPage(index, key)
        if page >= 0 {
            let pageOffset = index[page].offset
            let pageEnd = (page + 1 < indexCount)
                ? index[page + 1].offset : UInt64(sectionEnd)
            var position = Int(pageOffset)
            let limit = Swift.min(indexStride, contextCount - page * indexStride)
            var scanned = 0
            while scanned < limit {
                if position + 16 > Int(pageEnd) { break }
                let contextKey = readLE(base, position, UInt64.self)
                if contextKey == key {
                    let lambda = readFloatLE(base, position + 8)
                    let successorCount = Int(readLE(base, position + 12, UInt32.self))
                    let successorPosition = position + 16
                    if successorPosition + successorCount * 8 <= Int(pageEnd) {
                        entry = ContextEntry(missing: false, lambda: lambda,
                                             successorOffset: successorPosition,
                                             successorCount: successorCount)
                    }
                    break
                }
                if contextKey > key {
                    break
                }
                let successorCount = Int(readLE(base, position + 12, UInt32.self))
                position = position + 16 + successorCount * 8
                scanned += 1
            }
        }

        // 环形逐出（Lua context_caches）
        if tri {
            if triContextCacheKeys.count >= kContextCacheEntries {
                triContextCache.removeValue(forKey: triContextCacheKeys[triContextCacheNext])
                triContextCacheKeys[triContextCacheNext] = key
            } else {
                triContextCacheKeys.append(key)
            }
            triContextCacheNext = (triContextCacheNext + 1) % kContextCacheEntries
            triContextCache[key] = entry
        } else {
            if biContextCacheKeys.count >= kContextCacheEntries {
                biContextCache.removeValue(forKey: biContextCacheKeys[biContextCacheNext])
                biContextCacheKeys[biContextCacheNext] = key
            } else {
                biContextCacheKeys.append(key)
            }
            biContextCacheNext = (biContextCacheNext + 1) % kContextCacheEntries
            biContextCache[key] = entry
        }
        return entry
    }

    /// 后继表二分：(u32 target, f32 prob) * count
    private func lookupSuccessor(_ entry: ContextEntry, _ target: UInt32) -> Float {
        guard !entry.missing, entry.successorCount > 0, let base = mmapBase else { return 0.0 }
        var low = 0
        var high = entry.successorCount
        while low < high {
            let middle = low + (high - low) / 2
            let key = readLE(base, entry.successorOffset + middle * 8, UInt32.self)
            if key < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < entry.successorCount {
            let at = entry.successorOffset + low * 8
            if readLE(base, at, UInt32.self) == target {
                return readFloatLE(base, at + 4)
            }
        }
        return 0.0
    }

    /// 三级插值 logP(target | prev2, prev1)，与 Lua `logp` 逐行对齐：
    /// uni→bi（λbi），bi→tri（λtri），取 log，下限 1e-300。
    func logp(prev2: UInt32, prev1: UInt32, target: UInt32) -> Double {
        let cacheKey = NgramModel.pack3(UInt64(prev2), UInt64(prev1), UInt64(target))
        if let cached = logpCache[cacheKey] {
            return cached
        }
        let unigram = lookupUnigram(target)
        let biEntry = lookupContext(tri: false, key: UInt64(prev1))
        let bigram = Double(lookupSuccessor(biEntry, target)) + Double(biEntry.lambda) * Double(unigram)
        let triEntry = lookupContext(tri: true, key: NgramModel.pack2(UInt64(prev2), UInt64(prev1)))
        var probability = Double(lookupSuccessor(triEntry, target)) + Double(triEntry.lambda) * bigram
        if probability < 1e-300 {
            probability = 1e-300
        }
        let result = Foundation.log(probability)

        if logpCache.count >= SentenceConfig.logpCacheLimit {
            logpCache.removeValue(forKey: logpCacheKeys[logpCacheNext])
        }
        if logpCacheKeys.count > logpCacheNext {
            logpCacheKeys[logpCacheNext] = cacheKey
        } else {
            logpCacheKeys.append(cacheKey)
        }
        logpCacheNext = (logpCacheNext + 1) % SentenceConfig.logpCacheLimit
        logpCache[cacheKey] = result
        return result
    }

    /// bigram 是否被模型观察到（生僻字孤立惩罚预留，虎整句 has_observed_bigram）
    func hasObservedBigram(prev: UInt32, target: UInt32) -> Bool {
        let entry = lookupContext(tri: false, key: UInt64(prev))
        guard !entry.missing else { return false }
        guard let base = mmapBase else { return false }
        var low = 0
        var high = entry.successorCount
        while low < high {
            let middle = low + (high - low) / 2
            let key = readLE(base, entry.successorOffset + middle * 8, UInt32.self)
            if key < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < entry.successorCount
            && readLE(base, entry.successorOffset + low * 8, UInt32.self) == target
    }
}
