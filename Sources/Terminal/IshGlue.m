#import "IshGlue.h"

#include "kernel/calls.h"
#include "kernel/init.h"
#include "fs/tty.h"
#include "fs/dyndev.h"
#include "misc.h"

// MARK: - 会话状态（单会话模型：交互终端 + AI 一次性命令共用）
static void (^sessionOutputBlock)(NSData *) = NULL;
static struct tty *sessionTty = NULL;
static int sessionPid = 0;
static void (^sessionExitBlock)(int) = NULL;

static void null_progress(void *cookie, double progress, const char *message, bool *cancel_out) {
    *cancel_out = false;
}

static void fill_args(NSArray<NSString *> *cmd, char *buf, size_t limit) {
    size_t off = 0;
    for (NSUInteger i = 0; i < cmd.count; i++) {
        const char *s = cmd[i].UTF8String;
        size_t n = strlen(s);
        if (off + n + 2 >= limit) break;
        memcpy(buf + off, s, n + 1);
        off += n + 1;
    }
    buf[off] = '\0';
}

// 多变量环境（NUL 分隔 + 双 NUL 收尾）
static const char *session_envp =
    "TERM=xterm-256color\0"
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
    "HOME=/root\0"
    "LANG=C.UTF-8\0"
    "\0";

// MARK: - tty 驱动（替代 ios_tty_ops：输出直达回调块，不挂 hterm）
static int glue_tty_init(struct tty *tty) {
    return 0;
}

static int glue_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    if (tty == sessionTty && sessionOutputBlock != NULL) {
        NSData *data = [NSData dataWithBytes:buf length:len];
        sessionOutputBlock(data);
    }
    return (int)len;
}

static void glue_tty_cleanup(struct tty *tty) {
    if (tty == sessionTty) {
        sessionTty = NULL;
        sessionOutputBlock = NULL;
    }
    tty->data = NULL;
}

struct tty_driver_ops glue_tty_ops = {
    .init = glue_tty_init,
    .write = glue_tty_write,
    .cleanup = glue_tty_cleanup,
};

DEFINE_TTY_DRIVER(glue_console_driver, &glue_tty_ops, TTY_CONSOLE_MAJOR, 64);
struct tty_driver glue_pty_driver = {.ops = &glue_tty_ops};

static void glue_exit_hook(struct task *task, int code) {
    if (task != NULL && task->pid == sessionPid && sessionExitBlock != NULL) {
        void (^block)(int) = sessionExitBlock;
        sessionExitBlock = NULL;
        sessionTty = NULL;
        sessionOutputBlock = NULL;
        sessionPid = 0;
        block(code);
    }
}

@implementation IshGlue

+ (instancetype)shared {
    static IshGlue *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[IshGlue alloc] init]; });
    return instance;
}

+ (NSURL *)defaultRootDir {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                        inDomains:NSUserDomainMask].firstObject;
    return [docs URLByAppendingPathComponent:@"ish/roots/Default Root"];
}

- (BOOL)sessionActive {
    return sessionTty != NULL;
}

- (BOOL)installRootIfMissingTarResource:(NSString *)resourceName
                                rootDir:(NSURL *)rootDir
                                  error:(NSError **)error {
    NSURL *dataFile = [rootDir URLByAppendingPathComponent:@"data"];
    if ([NSFileManager.defaultManager fileExistsAtPath:dataFile.path]) return YES;

    NSURL *tar = [NSBundle.mainBundle URLForResource:resourceName withExtension:@"tar.gz"];
    if (tar == nil) {
        if (error) {
            *error = [NSError errorWithDomain:@"IshGlue" code:-1 userInfo:
                      @{NSLocalizedDescriptionKey: @"bundle 内找不到 rootfs tar.gz"}];
        }
        return NO;
    }
    [NSFileManager.defaultManager createDirectoryAtURL:rootDir
                           withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                  URLByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]];
    struct fakefsify_error fs_err;
    struct progress p = {NULL, null_progress};
    if (!fakefs_import(tar.fileSystemRepresentation, tmp.fileSystemRepresentation, &fs_err, p)) {
        if (error) {
            NSString *domain = fs_err.type == ERR_SQLITE ? @"SQLite" : @"IshArchive";
            *error = [NSError errorWithDomain:domain code:fs_err.code userInfo:
                      @{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"%s (line %d)", fs_err.message, fs_err.line]}];
        }
        if (fs_err.message) free(fs_err.message);
        [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
        return NO;
    }
    return [NSFileManager.defaultManager moveItemAtURL:tmp toURL:dataFile error:error];
}

- (int)bootWithRootDir:(NSURL *)rootDir {
    int err = mount_root(&fakefs, [rootDir URLByAppendingPathComponent:@"data"].path.fileSystemRepresentation);
    if (err < 0) return err;

    err = become_first_process();
    if (err < 0) return err;

    create_some_device_nodes();
    generic_setattrat(AT_PWD, "/", (struct attr) {.type = attr_mode, .mode = 0755}, false);

    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    NSString *sockTmp = [NSTemporaryDirectory() stringByAppendingString:@"ishsock"];
    sock_tmp_prefix = strdup(sockTmp.fileSystemRepresentation);

    tty_drivers[TTY_CONSOLE_MAJOR] = &glue_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) return err;

    exit_hook = glue_exit_hook;

    // PID 1：/sbin/init（inittab 在 console 上起 getty，输出会被丢弃，无碍）
    NSArray<NSString *> *cmd = @[@"/sbin/init"];
    char argv[4096];
    fill_args(cmd, argv, sizeof(argv));
    err = do_execve(cmd[0].UTF8String, cmd.count, argv, "TERM=xterm-256color");
    if (err < 0) return err;
    task_start(current);
    return 0;
}

- (int)startSessionCommand:(NSArray<NSString *> *)command
                 onOutput:(void (^)(NSData *))onOutput
                   onExit:(void (^)(int))onExit {
    if (sessionTty != NULL) return -100;   // 一次一个会话

    int err = become_new_init_child();
    if (err < 0) return err;

    struct tty *tty = pty_open_fake(&glue_pty_driver);
    if (IS_ERR(tty)) return (int) PTR_ERR(tty);

    sessionTty = tty;
    sessionOutputBlock = [onOutput copy];
    sessionExitBlock = [onExit copy];

    char stdioFile[64];
    snprintf(stdioFile, sizeof(stdioFile), "/dev/pts/%d", tty->num);
    err = create_stdio(stdioFile, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0) return err;
    tty_release(tty);

    char argv[8192];
    fill_args(command, argv, sizeof(argv));
    err = do_execve(command[0].UTF8String, command.count, argv, session_envp);
    if (err < 0) return err;
    sessionPid = current->pid;
    task_start(current);
    return 0;
}

- (void)sendInputData:(NSData *)data {
    if (sessionTty != NULL && data.length > 0) {
        tty_input(sessionTty, data.bytes, data.length, false);
    }
}

- (void)setWinSizeRow:(int)row col:(int)col {
    if (sessionTty != NULL) {
        tty_set_winsize(sessionTty, (struct winsize_) {.row = row, .col = col, .xpixel = 0, .ypixel = 0});
    }
}

@end
