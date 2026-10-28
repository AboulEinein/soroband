// Measures the cost of per-app, internet-only byte counting via the private NetworkStatistics framework.
// Build: clang -fobjc-arc -framework Foundation nstat-probe.m -o nstat-probe
// Run:   ./nstat-probe <seconds> <query interval seconds>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <netinet/in.h>
#import <sys/resource.h>

typedef void *NStatManagerRef;
typedef void *NStatSourceRef;

static NStatManagerRef (*NStatManagerCreate)(CFAllocatorRef, dispatch_queue_t, void (^)(NStatSourceRef, void *));
static int (*NStatManagerAddAllTCPWithFilter)(NStatManagerRef, int, int);
static int (*NStatManagerAddAllUDPWithFilter)(NStatManagerRef, int, int);
static void (*NStatSourceSetDescriptionBlock)(NStatSourceRef, void (^)(CFDictionaryRef));
static void (*NStatSourceSetCountsBlock)(NStatSourceRef, void (^)(CFDictionaryRef));
static void (*NStatSourceSetRemovedBlock)(NStatSourceRef, void (^)(void));
static void (*NStatManagerQueryAllSourcesDescriptions)(NStatManagerRef, void (^)(void));
static void (*NStatManagerQueryAllSources)(NStatManagerRef, void (^)(void));
static CFStringRef *kRx, *kTx, *kPID, *kName, *kRemote;

static BOOL isLocal(NSData *addr) {
    if (addr.length < sizeof(struct sockaddr)) return YES;
    const struct sockaddr *sa = addr.bytes;
    if (sa->sa_family == AF_INET) {
        uint32_t ip = ntohl(((const struct sockaddr_in *)sa)->sin_addr.s_addr);
        uint8_t a = ip >> 24, b = (ip >> 16) & 0xff;
        return ip == 0 || a == 10 || a == 127 || (a == 172 && (b & 0xf0) == 16) || (a == 192 && b == 168)
            || (a == 169 && b == 254) || a >= 224;
    }
    if (sa->sa_family == AF_INET6) {
        const struct in6_addr *ip6 = &((const struct sockaddr_in6 *)sa)->sin6_addr;
        if (IN6_IS_ADDR_V4MAPPED(ip6)) return NO;
        return IN6_IS_ADDR_UNSPECIFIED(ip6) || IN6_IS_ADDR_LOOPBACK(ip6) || IN6_IS_ADDR_LINKLOCAL(ip6)
            || IN6_IS_ADDR_MULTICAST(ip6) || (ip6->s6_addr[0] & 0xfe) == 0xfc;
    }
    return YES;
}

@interface Flow : NSObject
@property NSString *process;
@property BOOL local;
@property uint64_t rx, tx;
@end
@implementation Flow
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        int seconds = argc > 1 ? atoi(argv[1]) : 30;
        int interval = argc > 2 ? atoi(argv[2]) : 5;
        void *h = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY);
        if (!h) { fprintf(stderr, "dlopen failed\n"); return 1; }
#define SYM(name) name = dlsym(h, #name); if (!name) { fprintf(stderr, "missing " #name "\n"); return 1; }
        SYM(NStatManagerCreate) SYM(NStatManagerAddAllTCPWithFilter) SYM(NStatManagerAddAllUDPWithFilter)
        SYM(NStatSourceSetDescriptionBlock) SYM(NStatSourceSetCountsBlock) SYM(NStatSourceSetRemovedBlock)
        SYM(NStatManagerQueryAllSourcesDescriptions) SYM(NStatManagerQueryAllSources)
        kRx = dlsym(h, "kNStatSrcKeyRxBytes"); kTx = dlsym(h, "kNStatSrcKeyTxBytes");
        kPID = dlsym(h, "kNStatSrcKeyPID"); kName = dlsym(h, "kNStatSrcKeyProcessName"); kRemote = dlsym(h, "kNStatSrcKeyRemote");

        dispatch_queue_t q = dispatch_queue_create("nstat", DISPATCH_QUEUE_SERIAL);
        NSMutableDictionary<NSString *, NSNumber *> *internet = [NSMutableDictionary new], *local = [NSMutableDictionary new];
        __block uint64_t flows = 0;

        void (^account)(Flow *, uint64_t, uint64_t) = ^(Flow *f, uint64_t rx, uint64_t tx) {
            uint64_t delta = (rx - MIN(rx, f.rx)) + (tx - MIN(tx, f.tx));
            f.rx = rx; f.tx = tx;
            if (!f.process || !delta) return;
            NSMutableDictionary<NSString *, NSNumber *> *bucket = f.local ? local : internet;
            bucket[f.process] = @(bucket[f.process].unsignedLongLongValue + delta);
        };

        NStatManagerRef mgr = NStatManagerCreate(kCFAllocatorDefault, q, ^(NStatSourceRef src, void *unused) {
            flows++;
            Flow *f = [Flow new];
            NStatSourceSetDescriptionBlock(src, ^(CFDictionaryRef d) {
                NSDictionary *desc = (__bridge NSDictionary *)d;
                f.process = desc[(__bridge NSString *)*kName] ?: [desc[(__bridge NSString *)*kPID] stringValue];
                f.local = isLocal(desc[(__bridge NSString *)*kRemote]);
            });
            NStatSourceSetCountsBlock(src, ^(CFDictionaryRef c) {
                NSDictionary *counts = (__bridge NSDictionary *)c;
                account(f, [counts[(__bridge NSString *)*kRx] unsignedLongLongValue], [counts[(__bridge NSString *)*kTx] unsignedLongLongValue]);
            });
            NStatSourceSetRemovedBlock(src, ^{});
        });
        NStatManagerAddAllTCPWithFilter(mgr, 0, 0);
        NStatManagerAddAllUDPWithFilter(mgr, 0, 0);
        NStatManagerQueryAllSourcesDescriptions(mgr, ^{});

        // First query records baselines; only bytes after it are counted.
        NStatManagerQueryAllSources(mgr, ^{});
        dispatch_sync(q, ^{ [internet removeAllObjects]; [local removeAllObjects]; });

        for (int t = 0; t < seconds; t += interval) {
            [NSThread sleepForTimeInterval:interval];
            NStatManagerQueryAllSourcesDescriptions(mgr, ^{});
            NStatManagerQueryAllSources(mgr, ^{});
        }
        [NSThread sleepForTimeInterval:0.5];

        dispatch_sync(q, ^{
            struct rusage ru; getrusage(RUSAGE_SELF, &ru);
            double cpu = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
            printf("window %ds, query every %ds, flows seen %llu\n", seconds, interval, flows);
            printf("cpu %.3fs (%.3f%% avg), max rss %.1f MB\n", cpu, cpu / seconds * 100, ru.ru_maxrss / 1048576.0);
            for (NSDictionary<NSString *, NSNumber *> *bucket in @[internet, local]) {
                printf(bucket == internet ? "\ninternet bytes by process:\n" : "\nlocal (excluded) bytes by process:\n");
                NSArray *keys = [bucket keysSortedByValueUsingComparator:^(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
                for (NSString *k in [keys subarrayWithRange:NSMakeRange(0, MIN(8, keys.count))])
                    printf("  %-28s %10llu\n", k.UTF8String, bucket[k].unsignedLongLongValue);
            }
        });
    }
    return 0;
}
