#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// iSH 引擎 glue：boot / 会话 / tty 桥（全部内核调用必须在专用内核线程上执行）
@interface IshGlue : NSObject

+ (instancetype)shared;

/// 默认根文件系统目录（Documents/ish/roots/Default Root）
+ (NSURL *)defaultRootDir;

/// 首启：把 bundle 里的 rootfs tar.gz 导入为 fakefs SQLite（已存在则跳过返回 YES）
- (BOOL)installRootIfMissingTarResource:(NSString *)resourceName
                                rootDir:(NSURL *)rootDir
                                  error:(NSError **)error;

/// 启动内核（mount_root → init 进程）。必须在本引擎线程调用。
- (int)bootWithRootDir:(NSURL *)rootDir;

/// 开会话：pty + stdio + exec。输出/退出通过 block 回调（内核线程直接调用，Swift 侧自行派发）。
- (int)startSessionCommand:(NSArray<NSString *> *)command
                 onOutput:(void (^)(NSData *chunk))onOutput
                   onExit:(void (^)(int code))onExit;

/// 向当前会话 tty 写输入
- (void)sendInputData:(NSData *)data;

/// 调整会话窗口尺寸
- (void)setWinSizeRow:(int)row col:(int)col;

/// 当前是否有活动会话
@property (nonatomic, readonly) BOOL sessionActive;

@end

NS_ASSUME_NONNULL_END
