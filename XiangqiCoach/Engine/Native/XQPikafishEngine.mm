#import "XQPikafishEngine.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <deque>
#include <stdexcept>
#include <exception>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "../../Vendor/Pikafish/src/bitboard.h"
#include "../../Vendor/Pikafish/src/engine.h"
#include "../../Vendor/Pikafish/src/position.h"
#include "../../Vendor/Pikafish/src/score.h"
#include "../../Vendor/Pikafish/src/uci.h"

@implementation XQPikafishResult
@end

namespace {
int scoreValue(const Stockfish::Score& score) {
    if (score.is<Stockfish::Score::Mate>()) {
        const int plies = score.get<Stockfish::Score::Mate>().plies;
        return plies > 0 ? 100000 - plies : -100000 - plies;
    }
    return score.get<Stockfish::Score::InternalUnits>().value;
}

NSString *stringFromUTF8(const std::string& value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}

void configure(Stockfish::Engine& engine, const std::string& name, const std::string& value) {
    std::istringstream command("name " + name + " value " + value);
    engine.get_options().setoption(command);
}

/// 2025 原生解析器假定合法 FEN；识别输入必须先校验，避免越界、缺将或非法特征索引。
void validatePosition(const std::string& fen, const std::vector<std::string>& moves) {
    using namespace Stockfish;
    std::istringstream fields(fen);
    std::string board, side, castle, enPassant;
    int rule60 = 0, fullMove = 1;
    if (fen.size() > 256 || !(fields >> board >> side >> castle >> enPassant >> rule60 >> fullMove)
        || (side != "w" && side != "b") || rule60 < 0 || rule60 > 119 || fullMove < 0 || fullMove > 100000)
        throw std::invalid_argument("棋盘格式或行棋轮次不正确");
    int row = 0, column = 0;
    int counts[128] = {};
    const std::string pieceSymbols = "rnbakcpRNBAKCP";
    for (unsigned char symbol : board) {
        if (symbol == '/') {
            if (column != 9 || ++row > 9) throw std::invalid_argument("棋盘行数不正确");
            column = 0;
            continue;
        }
        if (symbol >= '1' && symbol <= '9') {
            column += symbol - '0';
            if (column > 9) throw std::invalid_argument("棋盘列数不正确");
            continue;
        }
        if (column >= 9 || pieceSymbols.find(symbol) == std::string::npos)
            throw std::invalid_argument("棋子编码不正确");
        const char piece = static_cast<char>(std::tolower(symbol));
        const int rank = std::isupper(symbol) ? 9 - row : row;
        const int maximum = piece == 'p' ? 5 : piece == 'k' ? 1 : 2;
        if (++counts[symbol] > maximum) throw std::invalid_argument("棋子数量超出标准象棋范围");
        if (piece == 'k' && (rank > 2 || column < 3 || column > 5))
            throw std::invalid_argument("将帅必须位于九宫内");
        if (piece == 'a' && !((rank == 0 || rank == 2) ? column == 3 || column == 5 : rank == 1 && column == 4))
            throw std::invalid_argument("士的位置不符合棋规");
        if (piece == 'b' && !(((rank == 0 || rank == 4) && (column == 2 || column == 6))
                             || (rank == 2 && (column == 0 || column == 4 || column == 8))))
            throw std::invalid_argument("象的位置不符合棋规");
        if (piece == 'p' && (rank < 3 || (rank < 5 && column % 2 != 0)))
            throw std::invalid_argument("兵卒的位置不符合棋规");
        ++column;
    }
    if (row != 9 || column != 9 || counts['k'] != 1 || counts['K'] != 1)
        throw std::invalid_argument("棋盘不完整或缺少将帅");
    std::deque<StateInfo> states(1);
    Position position;
    position.set(fen, &states.back());
    if (position.checkers_to(position.side_to_move(), position.king_square(~position.side_to_move())))
        throw std::invalid_argument("将帅对面或行棋轮次不正确");
    for (const auto& encoded : moves) {
        if (encoded.size() != 4) throw std::invalid_argument("历史走法编码不正确");
        const auto move = UCIEngine::to_move(position, encoded);
        if (move == Move::none()) throw std::invalid_argument("历史走法与起始棋盘不一致");
        states.emplace_back();
        position.do_move(move, states.back());
    }
}

/// 搜索回调捕获局部结果；所有返回路径都先等原生线程退出，再解除这些引用。
struct SearchCallbackScope {
    Stockfish::Engine& engine;
    ~SearchCallbackScope() {
        engine.wait_for_search_finished();
        engine.set_on_update_full([](const Stockfish::Engine::InfoFull&) {});
        engine.set_on_bestmove([](std::string_view, std::string_view) {});
    }
};
}

@implementation XQPikafishEngine {
    std::unique_ptr<Stockfish::Engine> _engine;
    /// 只保护启动/停止几行调用，绝不持锁等待完整搜索，避免 cancel 阻塞主线程。
    std::mutex _startStopMutex;
    uint64_t _cancellationRevision;
    NSString *_lastError;
    BOOL _ready;
}

- (instancetype)initWithNetworkPath:(NSString *)networkPath {
    self = [super init];
    if (!self) return nil;
    _cancellationRevision = 0;
    _ready = NO;
    if (![[NSFileManager defaultManager] isReadableFileAtPath:networkPath]) {
        _lastError = @"Pikafish 棋力模型缺失，请重新安装应用";
        return self;
    }
    try {
        static std::once_flag tablesOnce;
        std::call_once(tablesOnce, [] {
            Stockfish::Bitboards::init();
            Stockfish::Position::init();
        });
        // Engine 用传入路径的父目录加载默认 pikafish.nnue，不依赖进程工作目录。
        _engine = std::make_unique<Stockfish::Engine>(std::string(networkPath.UTF8String));
        if (!_engine->is_network_loaded()) {
            _lastError = @"Pikafish 棋力模型损坏或版本不匹配，请重新安装应用";
            _engine.reset();
            return self;
        }
        configure(*_engine, "Hash", "16");
        configure(*_engine, "Threads", "1");
        _engine->set_on_update_no_moves([](const Stockfish::Engine::InfoShort&) {});
        _engine->set_on_update_full([](const Stockfish::Engine::InfoFull&) {});
        _engine->set_on_iter([](const Stockfish::Engine::InfoIter&) {});
        _engine->set_on_bestmove([](std::string_view, std::string_view) {});
        _engine->set_on_verify_networks([](std::string_view) {});
        _ready = YES;
    } catch (const std::exception& error) {
        _lastError = [@"Pikafish 初始化失败：" stringByAppendingString:stringFromUTF8(error.what())];
        _engine.reset();
    }
    return self;
}

- (BOOL)ready { return _ready; }
- (NSString *)lastError { return _lastError; }

- (XQPikafishResult *)searchFEN:(NSString *)fen
                 milliseconds:(NSInteger)milliseconds
                 maximumDepth:(NSInteger)maximumDepth
                    nodeLimit:(uint64_t)nodeLimit
                     revision:(uint64_t)revision {
    return [self searchFEN:fen moves:@[] milliseconds:milliseconds maximumDepth:maximumDepth
                nodeLimit:nodeLimit revision:revision];
}

- (XQPikafishResult *)searchFEN:(NSString *)fen
                        moves:(NSArray<NSString *> *)moves
                 milliseconds:(NSInteger)milliseconds
                 maximumDepth:(NSInteger)maximumDepth
                    nodeLimit:(uint64_t)nodeLimit
                     revision:(uint64_t)revision {
    _lastError = nil;
    if (!_ready || !_engine) {
        _lastError = @"Pikafish 引擎尚未准备好";
        return nil;
    }
    try {
        const auto start = std::chrono::steady_clock::now();
        std::vector<std::string> history;
        history.reserve(moves.count);
        for (NSString *move in moves) history.emplace_back(move.UTF8String);
        validatePosition(fen.UTF8String, history);
        _engine->set_position(fen.UTF8String, history);
        std::string bestMove;
        std::string pv;
        int score = 0;
        int depth = 0;
        uint64_t nodes = 0;
        _engine->set_on_update_full([&](const Stockfish::Engine::InfoFull& info) {
            if (info.multiPV != 1) return;
            // 上下界可能来自未完成的 aspiration 重搜，不能作为最终评分展示。
            if (!info.bound.empty()) return;
            score = scoreValue(info.score);
            depth = info.depth;
            nodes = info.nodes;
            pv = std::string(info.pv);
        });
        _engine->set_on_bestmove([&](std::string_view move, std::string_view) { bestMove = std::string(move); });
        SearchCallbackScope callbackScope{*_engine};
        Stockfish::Search::LimitsType limits;
        limits.startTime = Stockfish::now();
        limits.movetime = std::max<NSInteger>(1, milliseconds);
        limits.depth = static_cast<int>(std::clamp<NSInteger>(maximumDepth, 1, 128));
        limits.nodes = nodeLimit;
        {
            std::lock_guard<std::mutex> lock(_startStopMutex);
            if (revision != _cancellationRevision) return nil;
            _engine->go(limits);
        }
        _engine->wait_for_search_finished();
        {
            std::lock_guard<std::mutex> lock(_startStopMutex);
            if (revision != _cancellationRevision) return nil;
        }
        if (bestMove.empty() || bestMove == "(none)" || bestMove == "0000") return nil;
        XQPikafishResult *result = [XQPikafishResult new];
        result.bestMove = stringFromUTF8(bestMove);
        NSMutableArray<NSString *> *variation = [NSMutableArray array];
        std::istringstream line(pv);
        for (std::string move; line >> move;) [variation addObject:stringFromUTF8(move)];
        result.principalVariation = variation;
        result.depth = depth;
        result.score = score;
        result.nodes = nodes;
        result.elapsedMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start).count();
        return result;
    } catch (const std::exception& error) {
        _lastError = [@"Pikafish 分析失败：" stringByAppendingString:stringFromUTF8(error.what())];
        return nil;
    }
}

- (void)cancelWithRevision:(uint64_t)revision {
    std::lock_guard<std::mutex> lock(_startStopMutex);
    if (revision > _cancellationRevision) _cancellationRevision = revision;
    if (_engine) _engine->stop();
}
@end
