import Foundation

struct SearchResult: Equatable, Sendable {
    let move: XiangqiMove
    let score: Int
    /// Pikafish 实际完成的迭代深度，不能用请求的最大深度代替。
    let depth: Int
    let principalVariation: [XiangqiMove]
    let elapsedMilliseconds: Int
    let nodesVisited: Int
}

/// Pikafish 专用串行队列入口。初始化只保存配置，模型加载和搜索均在首次 search 的调用队列执行。
/// search 不可并发调用；cancel 可从主线程打断搜索，取消版本号同时覆盖模型尚在加载的窗口。
final class XiangqiEngine: @unchecked Sendable {
    static let version = "Pikafish 2025-06-23 · Pro 同款模型"

    private let networkURL: URL?
    private let stateLock = NSLock()
    private var nativeEngine: XQPikafishEngine?
    private var cancellationRevision: UInt64 = 0
    /// 只由串行引擎队列写入并读取；nil 结果时用它区分终局、取消和初始化/分析失败。
    private(set) var lastError: String?

    init(networkURL: URL? = nil) {
        self.networkURL = networkURL
    }

    /// 默认让成熟引擎按时间预算迭代加深，不沿用旧原型最多 5 层的限制。
    func search(position: XiangqiPosition, timeLimit: TimeInterval = 0.8, maximumDepth: Int = 64,
                nodeLimit: Int? = nil, history: AnalysisHistory? = nil) -> SearchResult? {
        lastError = nil
        stateLock.lock()
        let revision = cancellationRevision
        stateLock.unlock()
        guard timeLimit.isFinite, timeLimit > 0, maximumDepth > 0, nodeLimit.map({ $0 > 0 }) ?? true else {
            lastError = "分析预算不足，请重试"
            return nil
        }
        let legalMoves = position.legalMoves()
        guard position.kingSquare(for: .red) != nil, position.kingSquare(for: .black) != nil,
              !legalMoves.isEmpty else { return nil }
        var root = position
        var historyMoves: [String] = []
        if let history {
            // 线性重放确认历史属于当前局面，避免长对局反复枚举所有 Swift 合法走法。
            // 每步完整棋规由原生桥再次校验；绝不把旧局历史交给搜索。
            var replay = history.root
            for move in history.moves {
                guard move.from.isOnBoard, move.to.isOnBoard, move.from != move.to,
                      replay[move.from]?.side == replay.sideToMove,
                      replay[move.to]?.side != replay.sideToMove else {
                    lastError = "棋局历史与当前棋盘不一致，请重新开启录屏"
                    return nil
                }
                replay = replay.applying(move)
            }
            guard replay == position else {
                lastError = "棋局历史与当前棋盘不一致，请重新开启录屏"
                return nil
            }
            root = history.root
            historyMoves = history.moves.map { $0.iccs() }
        }
        guard let native = prepareEngine() else { return nil }
        guard isCurrent(revision) else { return nil }
        let milliseconds = Int(min(timeLimit * 1_000, Double(Int32.max)).rounded(.up))
        let result = native.search(
            fen: Self.engineFEN(for: root),
            moves: historyMoves,
            milliseconds: milliseconds,
            maximumDepth: min(maximumDepth, 128),
            nodeLimit: UInt64(nodeLimit ?? 0),
            revision: revision
        )
        guard isCurrent(revision) else { return nil }
        guard let result else {
            lastError = native.lastError ?? "引擎未返回有效走法，请重试"
            return nil
        }
        guard let move = Self.move(fromICCS: result.bestMove), legalMoves.contains(move) else {
            lastError = "引擎返回的走法与当前棋盘不一致，请等待重新识别"
            return nil
        }
        var variation: [XiangqiMove] = []
        var linePosition = position
        for encoded in result.principalVariation {
            guard let next = Self.move(fromICCS: encoded), linePosition.legalMoves().contains(next) else { break }
            variation.append(next)
            linePosition = linePosition.applying(next)
        }
        if variation.first != move { variation = [move] }
        return SearchResult(
            move: move,
            score: result.score,
            depth: result.depth,
            principalVariation: variation,
            elapsedMilliseconds: result.elapsedMilliseconds,
            nodesVisited: Int(clamping: result.nodes)
        )
    }

    /// 新局面/停止录屏时递增版本并停止原生搜索；短锁覆盖 go/stop 的竞争，不等待完整计算。
    func cancel() {
        stateLock.lock()
        cancellationRevision &+= 1
        nativeEngine?.cancel(revision: cancellationRevision)
        stateLock.unlock()
    }

    /// 项目内部使用 H/E 与 r，Pikafish 的标准 FEN 使用 N/B 与 w；仅转换协议编码，不改变棋盘。
    static func engineFEN(for position: XiangqiPosition) -> String {
        let placement = position.fen().split(separator: " ")[0].map { character -> Character in
            switch character {
            case "H": return "N"
            case "h": return "n"
            case "E": return "B"
            case "e": return "b"
            default: return character
            }
        }
        return "\(String(placement)) \(position.sideToMove == .red ? "w" : "b") - - 0 1"
    }

    static func move(fromICCS encoded: String) -> XiangqiMove? {
        let bytes = Array(encoded.utf8)
        guard bytes.count == 4,
              (97...105).contains(bytes[0]), (48...57).contains(bytes[1]),
              (97...105).contains(bytes[2]), (48...57).contains(bytes[3]) else { return nil }
        let from = Square(row: 9 - Int(bytes[1] - 48), column: Int(bytes[0] - 97))
        let to = Square(row: 9 - Int(bytes[3] - 48), column: Int(bytes[2] - 97))
        guard from != to else { return nil }
        return XiangqiMove(from: from, to: to)
    }

    private func prepareEngine() -> XQPikafishEngine? {
        stateLock.lock()
        let existing = nativeEngine
        stateLock.unlock()
        if let existing { return existing }
        let model = networkURL
            ?? Bundle.main.url(forResource: "pikafish", withExtension: "nnue", subdirectory: "Pikafish")
            ?? Bundle.main.url(forResource: "pikafish", withExtension: "nnue")
        guard let model else {
            lastError = "Pikafish 棋力模型缺失，请重新安装应用"
            return nil
        }
        // 大模型加载必须在锁外，否则主线程 cancel 会被磁盘读取和初始化阻塞。
        let prepared = XQPikafishEngine(networkPath: model.path)
        guard prepared.ready else {
            lastError = prepared.lastError ?? "Pikafish 引擎初始化失败"
            return nil
        }
        stateLock.lock()
        prepared.cancel(revision: cancellationRevision)
        nativeEngine = prepared
        stateLock.unlock()
        return prepared
    }

    private func isCurrent(_ revision: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return revision == cancellationRevision
    }
}
