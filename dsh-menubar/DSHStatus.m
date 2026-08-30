#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <mach/vm_statistics.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

// ============================================================================
// DSH Status —— macOS 菜单栏常驻应用（Objective-C 版）
//
// 为什么用 Objective-C 而不是 SwiftUI：
//   本机只装了 Command Line Tools（无 Xcode.app），其 /usr/include/swift/ 下
//   module.modulemap 与 bridging.modulemap 重复定义 SwiftBridging，
//   只要 import SwiftUI/AppKit 就报 redefinition。clang 编译 ObjC 不受影响。
//
// 功能：
//   - 状态栏实时显示内存占用百分比（与「活动监视器」口径一致）
//   - 点开菜单可单独启停 DSH Web / 各模型，或一键启停全套
//   - 内存用 Mach host_statistics64 直读，端口用 BSD socket 探测（绕开代理）
//   - oMLX 子模型展开显示：◉ 绿色高亮「当前在内存」者，○ 标「待命」，
//     区分「可服务清单」(/v1/models) 与「真正常驻 RAM 的模型」(解析 oMLX 日志)
// ============================================================================

// 资源定位：全部相对 app 自身 bundle（自包含，可拷到任意 Mac）。
// dsh-manager.sh / dsh-web-control.py / dsh-control.html / python 都内置在
// Contents/Resources/ 下，不再依赖本机 WorkBuddy 安装路径。
static NSString *DSHBundleResource(NSString *name) {
    return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:name];
}
static NSString *DSHBundleScript(void)  { return DSHBundleResource(@"dsh-manager.sh"); }
static NSString *DSHBundlePython(void) {
    return [DSHBundleResource(@"python/bin/python3") stringByStandardizingPath];
}
static NSString *DSHBundlePythonBin(void) {
    return [DSHBundlePython() stringByDeletingLastPathComponent];
}
static NSString * const kWebConsoleURL = @"http://127.0.0.1:8899";
static NSString * const kDSHWebURL = @"http://127.0.0.1:3080";

// 轻量日志（写文件，便于确认 statusItem.button 是否成功创建）
static void DSHLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/dshstatus.log"];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [msg writeToFile:@"/tmp/dshstatus.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

typedef struct {
    int port;
    const char *title;
    const char *model;      // NULL = DSH Web 服务（非模型后端）
} ItemDef;

static ItemDef kItems[] = {
    {3080, "DSH Web",          NULL},
    {8000, "oMLX 9B/4B/14B",   "omlx"},
    {8001, "Qwen3-8B ablit",   "qwen3-8b-ablit"},
    {8002, "Qwen3-14B ablit",  "qwen3-14b-ablit"},
};
static const NSInteger kItemCount = 4;

// MARK: - 内存读取（对齐活动监视器「已使用内存」）

typedef struct {
    uint64_t total, used, available, cached, compressed, freeBytes;
    int usedPct;
} MemInfo;

static MemInfo readMemory(void) {
    MemInfo m = {0};
    m.total = [[NSProcessInfo processInfo] physicalMemory];

    vm_size_t pageSize = 0;
    if (host_page_size(mach_host_self(), &pageSize) != KERN_SUCCESS) return m;

    struct vm_statistics64 stats;
    mach_msg_type_number_t count = sizeof(stats) / sizeof(integer_t);
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (integer_t *)&stats, &count) != KERN_SUCCESS) return m;

    uint64_t ps = (uint64_t)pageSize;
    // 已用 = active + speculative + wired + compressor（压缩后实际占用）
    uint64_t usedPages = (uint64_t)stats.active_count
                       + (uint64_t)stats.speculative_count
                       + (uint64_t)stats.wire_count
                       + (uint64_t)stats.compressor_page_count;

    m.used = MIN(usedPages * ps, m.total);
    m.available = m.total - m.used;
    m.cached = ((uint64_t)stats.inactive_count + (uint64_t)stats.purgeable_count) * ps;
    m.compressed = (uint64_t)stats.compressor_page_count * ps;
    m.freeBytes = (uint64_t)stats.free_count * ps;
    m.usedPct = m.total > 0 ? (int)(m.used * 100 / m.total) : 0;
    return m;
}

// MARK: - 端口探测（BSD socket，绕开系统代理）

static BOOL isPortOpen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    struct timeval tv = {0, 250000};   // 250ms 超时
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    close(fd);
    return r == 0;
}

// 模型内存标注：优先用磁盘扫描出的实测权重大小，未命中才回退按名字关键字估算。
// 注意：这是权重下限，运行时还有 KV cache / 运行时开销，实际会再多一些。
static NSString *modelMemLabel(NSString *mid, NSDictionary<NSString *, NSString *> *weights) {
    NSString *w = weights[mid];
    if (w.length > 0) return [NSString stringWithFormat:@"约 %@ GB 权重", w];
    if ([mid containsString:@"14B"]) return @"约 8.3 GB 权重";
    if ([mid containsString:@"9B"])  return @"约 5.0 GB 权重";
    if ([mid containsString:@"4B"])  return @"约 2.4 GB 权重";
    return @"";
}

// MARK: - 控制动作（复用 dsh-manager.sh）

static void runManager(NSArray<NSString *> *args) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    NSMutableArray<NSString *> *full = [NSMutableArray arrayWithObject:DSHBundleScript()];
    [full addObjectsFromArray:args];
    task.arguments = full;

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"no_proxy"] = @"*";
    env[@"http_proxy"] = @"";
    env[@"https_proxy"] = @"";
    // 自包含：python 解释器已内联进 app（Contents/Resources/python），
    // 优先用 bundle 内 python；node 不打包（DSH Web 为可选组件），其余走系统 PATH。
    env[@"PATH"] = [NSString stringWithFormat:@"%@:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    DSHBundlePythonBin()];
    task.environment = env;
    DSHLog(@"runManager %@", [full componentsJoinedByString:@" "]);

    NSError *err = nil;
    [task launchAndReturnError:&err];
    if (err) NSLog(@"[DSHStatus] 执行失败: %@", err);
}

static NSString *gb(uint64_t bytes) {
    return [NSString stringWithFormat:@"%.1f GB", bytes / 1073741824.0];
}

// oMLX 在 kItems 中的下标（其 model 字段为 "omlx"）
static NSInteger omlxItemIndex(void) {
    for (NSInteger i = 0; i < kItemCount; i++)
        if (kItems[i].model && strcmp(kItems[i].model, "omlx") == 0) return i;
    return -1;
}

// 抓取 oMLX 可服务模型清单（/v1/models，绕代理）。失败回退到已知三模型。
static NSArray<NSString *> *fetchOmlxModels(void) {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/curl"];
    t.arguments = @[@"--noproxy", @"*", @"--max-time", @"3", @"-s",
                    @"http://127.0.0.1:8000/v1/models"];
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    [t launchAndReturnError:nil];
    [t waitUntilExit];
    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    if (json.length) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\"id\":\"([^\"]+)\""
                                                                             options:0 error:nil];
        for (NSTextCheckingResult *r in [re matchesInString:json options:0 range:NSMakeRange(0, json.length)]) {
            [ids addObject:[json substringWithRange:[r rangeAtIndex:1]]];
        }
    }
    if (ids.count) return ids;
    // 回退：已知三模型（与 OMLX_MODELS_DIR 内容一致）
    return @[@"Hermes-4-14B-4bit", @"Qwen3.5-4B-MLX-4bit", @"Qwen3.5-9B-MLX-4bit"];
}

// 抓取 oMLX 当前真正常驻 RAM 的模型集合（调用 dsh-manager.sh omlx_resident，解析引擎池日志）
static NSSet<NSString *> *fetchOmlxResident(void) {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    t.arguments = @[DSHBundleScript(), @"omlx_resident"];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"] = @"/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    t.environment = env;
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    [t launchAndReturnError:nil];
    [t waitUntilExit];
    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        NSString *s = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length && ![s isEqualToString:@"none"]) [set addObject:s];
    }
    return set;
}

// 扫描 oMLX 模型目录，返回 @[@{@"name":..., @"gb":...}, ...]。
// 这是模型清单与占用量的权威来源：增删模型后自动反映，不写死；
// 占用量是实测权重文件大小，不按名字猜。服务未启动时也照样能扫。
static NSArray<NSDictionary *> *fetchOmlxScan(void) {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    t.arguments = @[DSHBundleScript(), @"omlx_scan"];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"] = @"/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    t.environment = env;
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    [t launchAndReturnError:nil];
    [t waitUntilExit];
    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        NSString *s = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray<NSString *> *parts = [s componentsSeparatedByString:@"|"];
        if (parts.count == 2 && parts[0].length && parts[1].length) {
            [list addObject:@{@"name": parts[0], @"gb": parts[1]}];
        }
    }
    return list;
}

// 返回所有注册模型的权重大小映射：name -> GB 字符串。
// 包括 llamacpp 的 GGUF 和 oMLX 子模型；数据源为 dsh-manager.sh model_weights（实测文件）。
static NSDictionary<NSString *, NSString *> *fetchModelWeights(void) {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    t.arguments = @[DSHBundleScript(), @"model_weights"];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"] = @"/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    t.environment = env;
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    [t launchAndReturnError:nil];
    [t waitUntilExit];
    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        NSString *s = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray<NSString *> *parts = [s componentsSeparatedByString:@"|"];
        if (parts.count == 2 && parts[0].length && parts[1].length) {
            dict[parts[0]] = parts[1];
        }
    }
    return dict;
}

// MARK: - App Delegate

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL menuOpen;
// 磁盘扫描结果缓存：模型目录不常变，没必要每 5 秒遍历一次磁盘。
// 只有首次启动或用户点「重新扫描模型」时才真正扫描。
@property (nonatomic, strong) NSArray<NSDictionary *> *cachedOmlxScan;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *cachedModelWeights;
// 置 YES 时，即使菜单处于展开状态也强制重建一次（用于手动重扫后立即看到结果）
@property (nonatomic, assign) BOOL forceRebuild;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self ensureStatusItem];
    [self setupAutoStart];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                  target:self
                                                selector:@selector(refresh)
                                                userInfo:nil
                                                 repeats:YES];
    // 菜单打开时（NSRunLoop 处于 tracking mode）也要能刷新
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

// 确保状态栏 item 存在且按钮可用；launchd 在窗口服务器未就绪时拉起会导致
// button 为 nil，这里在再次激活（双击）时重建，保证图标一定出现。
// 自包含登录自启：首次运行把 LaunchAgent 写到用户目录，指向本 app 实际路径。
// 这样拷到任意 Mac 双击一次后即开机自启，无需安装器、无需管理员密码。
- (void)setupAutoStart {
    NSString *agentDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    NSString *plistPath = [agentDir stringByAppendingPathComponent:@"com.rory.dshstatus.plist"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:plistPath]) return;   // 已注册则跳过
    [fm createDirectoryAtPath:agentDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *exe = [[NSBundle mainBundle] executablePath];
    NSString *plist = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        @"<plist version=\"1.0\"><dict>\n"
        @"  <key>Label</key><string>com.rory.dshstatus</string>\n"
        @"  <key>ProgramArguments</key><array><string>%@</string></array>\n"
        @"  <key>RunAtLoad</key><true/>\n"
        @"  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>\n"
        @"  <key>ProcessType</key><string>Interactive</string>\n"
        @"  <key>LimitLoadToSessionType</key><string>Aqua</string>\n"
        @"</dict></plist>\n", exe];
    NSError *werr = nil;
    if ([plist writeToFile:plistPath atomically:YES encoding:NSUTF8StringEncoding error:&werr]) {
        DSHLog(@"setupAutoStart: 已写入 %@", plistPath);
        NSTask *lt = [[NSTask alloc] init];
        lt.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
        lt.arguments = @[@"load", plistPath];
        [lt launchAndReturnError:nil];
    } else {
        DSHLog(@"setupAutoStart: 写 plist 失败 %@", werr);
    }
}

- (void)ensureStatusItem {
    if (self.statusItem && self.statusItem.button) return;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"…";
    self.statusItem.button.toolTip = @"DSH Status —— 本地模型与 Harness 状态";
    DSHLog(@"ensureStatusItem button=%@", self.statusItem.button ? @"OK" : @"NIL");
    [self refresh];
    // 窗口服务器尚未就绪（如 launchd 登录早期拉起）时，延迟重试直至成功
    if (!self.statusItem.button) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self ensureStatusItem]; });
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    [self ensureStatusItem];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refresh {
    MemInfo m = readMemory();
    self.statusItem.button.title = [NSString stringWithFormat:@"%d%%", m.usedPct];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSNumber *> *states = [NSMutableArray arrayWithCapacity:kItemCount];
        for (NSInteger i = 0; i < kItemCount; i++) {
            [states addObject:@(isPortOpen(kItems[i].port))];
        }
        // 磁盘扫描结果走缓存：只在首次或手动重扫时才真正遍历磁盘，
        // 常态 5 秒刷新只做轻量的端口探测与内存读取。
        NSArray<NSDictionary *> *omlxScan = self.cachedOmlxScan;
        NSDictionary<NSString *, NSString *> *modelWeights = self.cachedModelWeights;
        if (!omlxScan) {
            omlxScan = fetchOmlxScan();
            self.cachedOmlxScan = omlxScan;
        }
        if (!modelWeights) {
            modelWeights = fetchModelWeights();
            self.cachedModelWeights = modelWeights;
        }
        NSArray<NSString *> *omlxModels = nil;
        NSSet<NSString *> *omlxResident = nil;
        NSInteger oi = omlxItemIndex();
        if (oi >= 0 && oi < (NSInteger)states.count && states[oi].boolValue) {
            omlxModels = fetchOmlxModels();
            omlxResident = fetchOmlxResident();
        }
        if (omlxModels.count == 0) {
            // 服务未运行 / /v1/models 取不到：退回磁盘扫描出的目录清单
            omlxModels = [omlxScan valueForKey:@"name"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // 菜单展开时不重建，避免闪烁/被关闭；手动重扫时强制重建一次
            if (self.menuOpen && !self.forceRebuild) return;
            self.forceRebuild = NO;
            [self rebuildMenuWithMem:m states:states omlxModels:omlxModels
                        omlxResident:omlxResident omlxScan:omlxScan
                       modelWeights:modelWeights];
        });
    });
}

- (void)rebuildMenuWithMem:(MemInfo)m
                     states:(NSArray<NSNumber *> *)states
                 omlxModels:(NSArray<NSString *> *)omlxModels
                omlxResident:(NSSet<NSString *> *)omlxResident
                    omlxScan:(NSArray<NSDictionary *> *)omlxScan
                modelWeights:(NSDictionary<NSString *, NSString *> *)modelWeights {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;

    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"内存占用 %d%%", m.usedPct]
                                                    action:nil keyEquivalent:@""];
    header.enabled = NO;
    [menu addItem:header];

    NSMenuItem *detail = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"已用 %@ · 可用 %@", gb(m.used), gb(m.available)]
                                                    action:nil keyEquivalent:@""];
    detail.enabled = NO;
    [menu addItem:detail];

    NSMenuItem *detail2 = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"缓存 %@ · 压缩 %@", gb(m.cached), gb(m.compressed)]
                                                     action:nil keyEquivalent:@""];
    detail2.enabled = NO;
    [menu addItem:detail2];

    [menu addItem:[NSMenuItem separatorItem]];

    for (NSInteger i = 0; i < kItemCount; i++) {
        ItemDef def = kItems[i];
        BOOL running = (i < (NSInteger)states.count) ? states[i].boolValue : NO;

        NSString *weightLabel = @"";
        if (def.model && strcmp(def.model, "omlx") != 0) {
            NSString *gbStr = modelWeights[[NSString stringWithUTF8String:def.model]];
            if (gbStr.length > 0) {
                weightLabel = [NSString stringWithFormat:@" · 约 %@ GB 权重", gbStr];
            }
        }
        NSString *title = [NSString stringWithFormat:@"%@ %s :%d %@%@",
                           running ? @"●" : @"○", def.title, def.port,
                           running ? @"运行中" : @"已停止", weightLabel];
        NSMenuItem *stateItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        stateItem.enabled = NO;
        [menu addItem:stateItem];

        NSString *actionTitle = running
            ? [NSString stringWithFormat:@"    停止 %s", def.title]
            : [NSString stringWithFormat:@"    启动 %s", def.title];
        NSMenuItem *actionItem = [[NSMenuItem alloc] initWithTitle:actionTitle
                                                            action:@selector(toggleItem:)
                                                     keyEquivalent:@""];
        actionItem.target = self;
        actionItem.tag = i;
        actionItem.enabled = !self.busy;
        [menu addItem:actionItem];

        // oMLX 子模型展开：◉ 绿色高亮「当前在内存」，○ 标「待命」
        // 模型清单与占用量均来自磁盘扫描（增删自动更新），不再写死
        if (def.model && strcmp(def.model, "omlx") == 0 && omlxModels.count > 0) {
            BOOL omlxUp = running;   // 本项端口通断即 oMLX 是否在跑
            [menu addItem:[NSMenuItem separatorItem]];
            NSString *hdr = omlxUp
                ? @"oMLX 模型（◉=在内存，○=待命/按需加载）"
                : @"oMLX 模型（服务未运行 · 均未加载）";
            NSMenuItem *subHeader = [[NSMenuItem alloc]
                initWithTitle:hdr action:nil keyEquivalent:@""];
            subHeader.enabled = NO;
            [menu addItem:subHeader];

            // 实测权重（磁盘扫描）优先，未命中才回退按名字估算
            NSMutableDictionary<NSString *, NSString *> *weights = [modelWeights mutableCopy];
            if (!weights) weights = [NSMutableDictionary dictionary];

            for (NSString *mid in omlxModels) {
                BOOL resident = [omlxResident containsObject:mid];
                NSString *mark = resident ? @"◉" : @"○";
                NSString *extra = resident ? @"在内存" : (omlxUp ? @"待命" : @"未加载");
                NSString *mem = modelMemLabel(mid, weights);
                NSString *t;
                if (mem.length > 0) {
                    t = [NSString stringWithFormat:@"   %@ %@  ·  %@  ·  %@", mark, mid, extra, mem];
                } else {
                    t = [NSString stringWithFormat:@"   %@ %@  ·  %@", mark, mid, extra];
                }
                NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:t action:nil keyEquivalent:@""];
                mi.enabled = NO;
                if (resident) {
                    NSDictionary *attr = @{NSForegroundColorAttributeName: [NSColor systemGreenColor]};
                    mi.attributedTitle = [[NSAttributedString alloc] initWithString:t attributes:attr];
                }
                [menu addItem:mi];
            }
        }
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *startAll = [[NSMenuItem alloc] initWithTitle:@"▶ 启动全套"
                                                      action:@selector(startAll:) keyEquivalent:@""];
    startAll.target = self;
    startAll.enabled = !self.busy;
    [menu addItem:startAll];

    NSMenuItem *stopAll = [[NSMenuItem alloc] initWithTitle:@"■ 停止全部"
                                                     action:@selector(stopAll:) keyEquivalent:@""];
    stopAll.target = self;
    stopAll.enabled = !self.busy;
    [menu addItem:stopAll];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *openWeb = [[NSMenuItem alloc] initWithTitle:@"打开网页控制台"
                                                     action:@selector(openWeb:) keyEquivalent:@""];
    openWeb.target = self;
    [menu addItem:openWeb];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"立即刷新"
                                                         action:@selector(manualRefresh:) keyEquivalent:@"r"];
    refreshItem.target = self;
    [menu addItem:refreshItem];

    NSMenuItem *rescanItem = [[NSMenuItem alloc] initWithTitle:@"⟳ 重新扫描模型"
                                                        action:@selector(rescanModels:) keyEquivalent:@""];
    rescanItem.target = self;
    [menu addItem:rescanItem];

    // 一键把本地模型配置为 DeepSeekHarness(DSH Web) 默认模型。
    // 子菜单列出 oMLX 子模型 + llama.cpp 模型，点击即用 dsh-manager.sh config-harness 写入 settings.yaml。
    NSMenuItem *harnessItem = [[NSMenuItem alloc] initWithTitle:@"⚙ 配置到 DeepSeekHarness"
                                                          action:nil keyEquivalent:@""];
    NSMenu *harnessSub = [[NSMenu alloc] init];
    for (NSString *mid in omlxModels) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:mid
                                                    action:@selector(configHarnessModel:) keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = mid;
        [harnessSub addItem:mi];
    }
    NSMenuItem *lc = [[NSMenuItem alloc] initWithTitle:@"Qwen3-14B-abliterated (llama.cpp)"
                                                 action:@selector(configHarnessModel:) keyEquivalent:@""];
    lc.target = self;
    lc.representedObject = @"qwen3-14b-ablit";
    [harnessSub addItem:lc];
    [harnessItem setSubmenu:harnessSub];
    [menu addItem:harnessItem];

    // 一键生成 WorkBuddy「添加模型」所需字段并写入剪贴板。
    // WorkBuddy 没有把本地模型配置落盘成可写文件，所以用「生成→复制→粘贴」半自动。
    NSMenuItem *wbItem = [[NSMenuItem alloc] initWithTitle:@"📋 复制 WorkBuddy 配置"
                                                     action:nil keyEquivalent:@""];
    NSMenu *wbSub = [[NSMenu alloc] init];
    for (NSString *mid in omlxModels) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:mid
                                                    action:@selector(copyWorkBuddyConfig:)
                                             keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = mid;
        [wbSub addItem:mi];
    }
    NSMenuItem *wbLc = [[NSMenuItem alloc] initWithTitle:@"Qwen3-14B-abliterated (llama.cpp)"
                                                    action:@selector(copyWorkBuddyConfig:)
                                             keyEquivalent:@""];
    wbLc.target = self;
    wbLc.representedObject = @"qwen3-14b-ablit";
    [wbSub addItem:wbLc];
    NSMenuItem *wbL8 = [[NSMenuItem alloc] initWithTitle:@"Qwen3-8B-abliterated (llama.cpp)"
                                                    action:@selector(copyWorkBuddyConfig:)
                                             keyEquivalent:@""];
    wbL8.target = self;
    wbL8.representedObject = @"qwen3-8b-ablit";
    [wbSub addItem:wbL8];
    [wbItem setSubmenu:wbSub];
    [menu addItem:wbItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 DSH Status"
                                                  action:@selector(quitApp:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (void)setBusyFor:(NSTimeInterval)seconds {
    self.busy = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.busy = NO;
        [self refresh];
    });
}

// 点菜单栏子项 → 把该模型设为 DeepSeekHarness 默认模型，弹窗回显 dsh-manager.sh 输出。
- (void)configHarnessModel:(NSMenuItem *)sender {
    NSString *mid = sender.representedObject;
    if (!mid.length) return;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[DSHBundleScript(), @"config-harness", mid];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"no_proxy"] = @"*";
    env[@"http_proxy"] = @"";
    env[@"https_proxy"] = @"";
    env[@"PATH"] = [NSString stringWithFormat:@"%@:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    DSHBundlePythonBin()];
    task.environment = env;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *err = nil;
    [task launchAndReturnError:&err];
    if (err) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"配置失败";
        a.informativeText = [NSString stringWithFormat:@"无法执行 config-harness: %@", err];
        [a runModal];
        return;
    }
    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"已配置 %@ → DeepSeekHarness", mid];
    alert.informativeText = out.length ? out : @"(无输出)";
    [alert runModal];
}

// 点菜单栏子项 → 生成 WorkBuddy「添加模型」所需字段，写入系统剪贴板并弹窗回显。
- (void)copyWorkBuddyConfig:(NSMenuItem *)sender {
    NSString *mid = sender.representedObject;
    if (!mid.length) return;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[DSHBundleScript(), @"config-workbuddy", mid];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"no_proxy"] = @"*";
    env[@"http_proxy"] = @"";
    env[@"https_proxy"] = @"";
    env[@"PATH"] = [NSString stringWithFormat:@"%@:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    DSHBundlePythonBin()];
    task.environment = env;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *err = nil;
    [task launchAndReturnError:&err];
    if (err) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"生成失败";
        a.informativeText = [NSString stringWithFormat:@"无法执行 config-workbuddy: %@", err];
        [a runModal];
        return;
    }
    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!out.length) out = @"(无输出)";
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:out forType:NSPasteboardTypeString];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"已复制 %@ 的 WorkBuddy 配置", mid];
    alert.informativeText = out;
    [alert runModal];
}

- (void)toggleItem:(NSMenuItem *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= kItemCount) return;

    ItemDef def = kItems[idx];
    BOOL running = isPortOpen(def.port);

    if (def.model == NULL) {
        BOOL willStart = !running;
        runManager(@[@"web", running ? @"stop" : @"start"]);
        // 启动 DSH Web 后直接打开浏览器到 :3080 页面
        if (willStart) {
            DSHLog(@"toggleItem: 启动 DSH Web 后打开 %@", kDSHWebURL);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kDSHWebURL]];
            });
        }
    } else {
        runManager(@[running ? @"unload" : @"load", [NSString stringWithUTF8String:def.model]]);
    }
    [self setBusyFor:4.0];
}

- (void)startAll:(id)sender {
    runManager(@[@"start"]);
    [self setBusyFor:6.0];
}

- (void)stopAll:(id)sender {
    runManager(@[@"stop"]);
    [self setBusyFor:4.0];
}

- (void)openWeb:(id)sender {
    // 网页控制台(:8899) 由 dsh-web-control.py 提供（同源页面 + API）。
    // 菜单栏 app 不会自动拉它，所以这里按需启动后端再打开页面。
    if (!isPortOpen(8899)) {
        DSHLog(@"openWeb: 启动网页控制台后端 :8899");
        NSTask *t = [[NSTask alloc] init];
        t.executableURL = [NSURL fileURLWithPath:DSHBundlePython()];
        t.arguments = @[DSHBundleResource(@"dsh-web-control.py")];
        // 日志重定向到 /tmp/dsh-web-control.log
        NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/dsh-web-control.log"];
        if (!log) {
            [@"" writeToFile:@"/tmp/dsh-web-control.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            log = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/dsh-web-control.log"];
        }
        t.standardOutput = log;
        t.standardError = log;
        NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
        env[@"no_proxy"] = @"*";
        env[@"http_proxy"] = @"";
        env[@"https_proxy"] = @"";
        env[@"PATH"] = [NSString stringWithFormat:@"%@:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                        DSHBundlePythonBin()];
        t.environment = env;
        [t launchAndReturnError:nil];
        // 后端稍后就绪，异步打开避免阻塞菜单
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kWebConsoleURL]];
        });
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kWebConsoleURL]];
}

- (void)manualRefresh:(id)sender {
    [self refresh];
}

// 手动触发磁盘扫描：清缓存后重新扫描模型目录，并强制重建菜单以便立刻看到结果。
// 常态 5 秒刷新不做磁盘扫描，避免频繁遍历模型目录。
- (void)rescanModels:(id)sender {
    self.cachedOmlxScan = nil;
    self.cachedModelWeights = nil;
    self.forceRebuild = YES;
    [self refresh];
}

- (void)quitApp:(id)sender {
    [NSApp terminate:nil];
}

// MARK: - NSMenuDelegate（菜单展开时暂停重建）

- (void)menuWillOpen:(NSMenu *)menu { self.menuOpen = YES; }
- (void)menuDidClose:(NSMenu *)menu { self.menuOpen = NO; }

@end

// MARK: - main

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        static AppDelegate *delegate = nil;   // 静态持有，避免被释放
        NSApplication *app = [NSApplication sharedApplication];
        delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
