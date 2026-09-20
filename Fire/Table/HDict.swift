//
//  HDict.swift
//  Fire
//
//  `.hdict`：Fire 私有词库容器 —— 定长头 + 单个负载块，负载是统一码表格式的行流
//  `候选\t编码[\t词频]`（UTF-8，`\n` 分隔），块内用 raw deflate 压缩。
//
//  为什么要私有容器，而不是直接发一个大 txt：
//  * 拼音词库从八万条扩到几十万条后，明文二十多 MB、压缩后十几 MB，是要进 app 包
//    随 pkg 分发的；deflate 对「汉字 + 连写拼音 + 词频」这种高度重复的文本压到四成。
//  * 有头才有校验：magic + 版本 + 头部 CRC + 声明长度，能让「拷贝坏了一半的词库」
//    在载入时明确失败并回落，而不是解析出半张表、让用户看到莫名其妙的缺词。
//  * 版本与 kind 写进头部：词库格式以后加列（音节列、双拼码表 kind=2）时，老版本
//    app 读新文件会直接拒绝，而不是把新列当成编码的一部分。
//
//  压缩选 raw deflate（Python 侧 `zlib wbits=-15`）：与 Apple `Compression` 框架的
//  `COMPRESSION_ZLIB` 是同一种流，系统库直接解 —— 不引第三方依赖，也不动 TableBuilder。
//
//  字段偏移与 `scripts/build_pinyin_hdict.py` 的 `HEADER` 逐字段对齐（小端）。
//

import Foundation
import Compression

/// 容器里装的是哪种词库。
enum HDictKind: UInt16 {
    /// 拼音词库（编码列 = 连写全拼）。双拼不需要另一份词库：引擎先把双拼键解成
    /// 音节（`ShuangpinScheme.decode`），查的还是这同一份音节索引。
    case pinyin = 1
    /// 双拼词库（编码列 = 双拼键）。当前没有产出方，留给「按双拼码反查」这类需求。
    case shuangpin = 2
}

/// 负载块的压缩方式。
enum HDictCodec: UInt16 {
    case stored = 0     // 原样（写侧发现压不动时才用）
    case deflate = 1    // raw deflate
}

/// 定长头。`byteCount` 之后的字节全是负载。
struct HDictHeader {
    static let byteCount = 64
    static let currentVersion: UInt16 = 1
    /// 数据行带第三列词频
    static let flagWeightColumn: UInt16 = 1 << 0
    /// 数据行已规范化（词面/编码无多余空白、编码只用 a-z）且 (词,码) 已去重
    static let flagCanonicalRows: UInt16 = 1 << 1
    static let magic: [UInt8] = [0x48, 0x44, 0x43, 0x54]   // "HDCT"

    var version: UInt16
    var kind: HDictKind?
    var codec: HDictCodec?
    var flags: UInt16
    var entryCount: Int
    /// 解压后的字节数
    var payloadBytes: Int
    /// 文件内的负载字节数
    var storedBytes: Int
    var payloadCRC32: UInt32
    /// 头部 CRC（按「本字段与之后的保留区为 0」计算，读写同规则）
    var headerCRC32: UInt32

    var hasWeightColumn: Bool { flags & HDictHeader.flagWeightColumn != 0 }
    /// 读侧可以据此跳过逐行 trim 与去重（见 `PinyinLexicon.load`）
    var hasCanonicalRows: Bool { flags & HDictHeader.flagCanonicalRows != 0 }
    /// 文件里负载块结束的位置
    var storedEnd: Int { HDictHeader.byteCount + storedBytes }
}

enum HDict {
    static let fileExtension = "hdict"

    // MARK: - 判定 / 读头

    static func isHDict(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == fileExtension
    }

    /// 只读头部：magic / 版本 / 头部 CRC 任一不对即 nil。
    static func header(at path: String) -> HDictHeader? {
        guard let data = read(path) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> HDictHeader? in
            parseHeader(raw)
        }
    }

    private static func read(_ path: String) -> Data? {
        // 映射读：容器十几 MB，读个头不必先拷一份
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedRead)
    }

    private static func parseHeader(_ raw: UnsafeRawBufferPointer) -> HDictHeader? {
        guard raw.count >= HDictHeader.byteCount else { return nil }
        for (index, byte) in HDictHeader.magic.enumerated() where raw[index] != byte {
            return nil
        }
        var head = [UInt8](repeating: 0, count: HDictHeader.byteCount)
        for index in 0 ..< HDictHeader.byteCount { head[index] = raw[index] }
        let storedCRC = UInt32(littleEndianBytes: head, at: 36)
        // CRC 要按「本字段为 0」算：先取出、再清零、算完还原
        for index in 36 ..< 40 { head[index] = 0 }
        guard CRC32.of(head) == storedCRC else { return nil }
        let version = UInt16(littleEndianBytes: head, at: 4)
        guard version == HDictHeader.currentVersion else { return nil }
        return HDictHeader(
            version: version,
            kind: HDictKind(rawValue: UInt16(littleEndianBytes: head, at: 6)),
            codec: HDictCodec(rawValue: UInt16(littleEndianBytes: head, at: 8)),
            flags: UInt16(littleEndianBytes: head, at: 10),
            entryCount: Int(UInt32(littleEndianBytes: head, at: 12)),
            payloadBytes: Int(UInt64(littleEndianBytes: head, at: 16)),
            storedBytes: Int(UInt64(littleEndianBytes: head, at: 24)),
            payloadCRC32: UInt32(littleEndianBytes: head, at: 32),
            headerCRC32: storedCRC
        )
    }

    // MARK: - 取负载

    /// 解出负载全文。头坏 / 长度对不上 / inflate 失败 / 非 UTF-8 → nil，
    /// 调用方按「这份词库读不了」处理（回落内置表或用户的旧 txt）。
    static func payloadText(at path: String) -> String? {
        guard let data = read(path),
              let head = data.withUnsafeBytes({ (raw: UnsafeRawBufferPointer) -> HDictHeader? in
                  parseHeader(raw)
              }) else { return nil }
        // 头部坏成天文数字时先挡住 malloc：宁可乐观地读不了，不要吃进几 GB 内存
        guard let codec = head.codec, head.payloadBytes > 0,
              data.count >= head.storedEnd, head.payloadBytes < 512 << 20 else { return nil }
        if codec == .stored && head.storedBytes != head.payloadBytes { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress else { return nil }
            let from = base + HDictHeader.byteCount
            // malloc/free 配对：解出来的那块直接交给 `Data(bytesNoCopy:deallocator: .free)`，
            // 用 Swift 分配器申请、再让 free() 释放是早晚要爆的错配
            guard let buffer = malloc(head.payloadBytes) else { return nil }
            let destination = buffer.assumingMemoryBound(to: UInt8.self)
            let source = from.assumingMemoryBound(to: UInt8.self)
            let written: Int
            switch codec {
            case .deflate:
                // Swift 侧 `compression_decode_buffer` 的签名不带 scratch_size（overlay 已合并），
                // 目标缓冲给足 payloadBytes 即可整块解出
                written = compression_decode_buffer(destination, head.payloadBytes, source,
                                                    head.storedBytes, nil, COMPRESSION_ZLIB)
            case .stored:
                buffer.copyMemory(from: from, byteCount: head.storedBytes)
                written = head.storedBytes
            }
            guard written == head.payloadBytes else {
                free(buffer)
                return nil
            }
            // 解出来的就是最终文本，交给 Data 接管这块内存，不再拷一份
            return String(data: Data(bytesNoCopy: buffer, count: written,
                                     deallocator: .free), encoding: .utf8)
        }
    }

    /// 码表全文的统一入口：`.hdict` 解压，其余（txt / yaml /……）按 UTF-8 直读。
    /// 拼音音节索引与整句词图都从这里取文本，不必各自再判一次文件类型。
    static func tableText(path: String) -> String? {
        if isHDict(path: path) { return payloadText(at: path) }
        guard let data = read(path), let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 导出明文（给只认「候选\t编码」的下游，如 TableBuilder）

    /// 导出明文码表；`columns` 决定每行保留前几列（2 = 丢掉词频列，TableBuilder
    /// 的 `split()` 只认两列，多给它词频列会整表被判为不合格行）。
    /// `limit` 只导前 N 行（词库按词频降序写，就是「取最常用 N 条」）。
    /// 返回写出的行数。
    @discardableResult
    static func exportText(at path: String, columns: Int, to url: URL, limit: Int = 0) -> Int? {
        guard let text = tableText(path: path) else { return nil }
        var output = ""
        output.unicodeScalars.reserveCapacity(text.unicodeScalars.underestimatedCount)
        var rows = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            output.append(parts.prefix(columns).joined(separator: "\t"))
            output.append("\n")
            rows += 1
            if limit > 0, rows >= limit { break }
        }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return rows
    }

    // MARK: - 体检（自检 / 离线校验；正常载入不跑逐字节 CRC）

    /// 逐字段体检，返回问题列表（空即健康）。负载 CRC 要扫十几 MB，只在自检里跑。
    static func verify(at path: String) -> [String] {
        guard let data = read(path) else { return ["读不到文件：\(path)"] }
        guard data.count > HDictHeader.byteCount else { return ["文件不足头部长度"] }
        guard let head = data.withUnsafeBytes({ (raw: UnsafeRawBufferPointer) -> HDictHeader? in
            parseHeader(raw)
        }) else { return ["头部 magic / 版本 / CRC 校验失败"] }
        var problems: [String] = []
        if head.kind == nil { problems.append("kind 未知") }
        if head.kind == .shuangpin { problems.append("双拼词库当前没有消费方") }
        guard let codec = head.codec else {
            problems.append("codec 未知")
            return problems
        }
        guard data.count >= head.storedEnd else {
            problems.append("负载不完整：声明 \(head.storedBytes) 字节，文件只剩 \(data.count - HDictHeader.byteCount)")
            return problems
        }
        if data.count > head.storedEnd {
            problems.append("文件尾部多出 \(data.count - head.storedEnd) 字节")
        }
        let body = [UInt8](data.subdata(in: HDictHeader.byteCount ..< head.storedEnd))
        if CRC32.of(body) != head.payloadCRC32 { problems.append("负载 CRC 不匹配") }
        if codec == .stored && head.storedBytes != head.payloadBytes {
            problems.append("未压缩块长度 \(head.payloadBytes) 与容器内 \(head.storedBytes) 不一致")
        }
        guard let text = payloadText(at: path) else {
            problems.append("负载解不出来（inflate 失败或不是合法 UTF-8）")
            return problems
        }
        if text.utf8.count != head.payloadBytes {
            problems.append("解压后 \(text.utf8.count) 字节 != 头部声明 \(head.payloadBytes)")
        }
        var rows = 0
        var widest = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            rows += 1
            widest = max(widest, line.split(separator: "\t", omittingEmptySubsequences: false).count)
        }
        if rows != head.entryCount { problems.append("词条数 \(rows) != 头部声明 \(head.entryCount)") }
        if widest > 3 { problems.append("数据行最多 \(widest) 列，超出容器约定（≤3）") }
        return problems
    }

    /// 一句话摘要（日志 / 词库面板）
    static func describe(at path: String) -> String {
        guard let head = header(at: path) else { return "\(path)：不是可用的 .hdict" }
        let ratio = head.storedBytes * 100 / max(1, head.payloadBytes)
        let name = head.kind == .pinyin ? "拼音" : (head.kind == .shuangpin ? "双拼" : "未知")
        return "\(name)词库 v\(head.version)：词条 \(head.entryCount)，负载 "
            + "\(head.payloadBytes) B → \(head.storedBytes) B（\(ratio)%）"
    }
}

// MARK: - 小端读数与 CRC-32

private extension UInt16 {
    init(littleEndianBytes bytes: [UInt8], at offset: Int) {
        self = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}

private extension UInt32 {
    init(littleEndianBytes bytes: [UInt8], at offset: Int) {
        var value: UInt32 = 0
        for index in 0 ..< 4 { value |= UInt32(bytes[offset + index]) << (8 * index) }
        self = value
    }
}

private extension UInt64 {
    init(littleEndianBytes bytes: [UInt8], at offset: Int) {
        var value: UInt64 = 0
        for index in 0 ..< 8 { value |= UInt64(bytes[offset + index]) << (8 * index) }
        self = value
    }
}

/// CRC-32/IEEE（与 Python `zlib.crc32` 同值）。读头只扫 64 字节；负载全量扫描
/// 留给 `verify`，不进载入路径。
enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func of(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
