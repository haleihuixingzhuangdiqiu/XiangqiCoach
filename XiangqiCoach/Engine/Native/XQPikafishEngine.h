#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 已完成迭代的原生结果；坐标采用 UCI/ICCS，评分视角为当前行棋方。
@interface XQPikafishResult : NSObject
@property(nonatomic, copy) NSString *bestMove;
@property(nonatomic, copy) NSArray<NSString *> *principalVariation;
@property(nonatomic) NSInteger score;
@property(nonatomic) NSInteger depth;
@property(nonatomic) NSInteger elapsedMilliseconds;
@property(nonatomic) uint64_t nodes;
@end

/// 搜索和初始化仅在专用串行队列执行；cancel 可在任意线程打断当前搜索。
@interface XQPikafishEngine : NSObject
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly, copy, nullable) NSString *lastError;
- (instancetype)initWithNetworkPath:(NSString *)networkPath;
- (nullable XQPikafishResult *)searchFEN:(NSString *)fen
                         milliseconds:(NSInteger)milliseconds
                         maximumDepth:(NSInteger)maximumDepth
                            nodeLimit:(uint64_t)nodeLimit
                             revision:(uint64_t)revision
    NS_SWIFT_NAME(search(fen:milliseconds:maximumDepth:nodeLimit:revision:));
- (nullable XQPikafishResult *)searchFEN:(NSString *)fen
                                moves:(NSArray<NSString *> *)moves
                         milliseconds:(NSInteger)milliseconds
                         maximumDepth:(NSInteger)maximumDepth
                            nodeLimit:(uint64_t)nodeLimit
                             revision:(uint64_t)revision
    NS_SWIFT_NAME(search(fen:moves:milliseconds:maximumDepth:nodeLimit:revision:));
- (void)cancelWithRevision:(uint64_t)revision NS_SWIFT_NAME(cancel(revision:));
@end

NS_ASSUME_NONNULL_END
