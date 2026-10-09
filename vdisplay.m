// Adds virtual displays, as the reporter's Mac has them: a 2x built-in screen as the main one and
// a 1x external one beside it. They last as long as this process.
// Build: clang -fobjc-arc -framework Foundation -framework CoreGraphics vdisplay.m -o vdisplay
// Run:   vdisplay 1512x982@2 3440x1440@1
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSMutableArray *displays = [NSMutableArray array];
        CGDirectDisplayID real = CGMainDisplayID();
        for (int i = 1; i < argc; i++) {
            unsigned w = 0, h = 0, scale = 1;
            sscanf(argv[i], "%ux%u@%u", &w, &h, &scale);
            CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
            d.queue = dispatch_get_main_queue();
            d.name = [NSString stringWithFormat:@"Repro %d", i];
            d.maxPixelsWide = w * scale;
            d.maxPixelsHigh = h * scale;
            d.sizeInMillimeters = CGSizeMake(w * 0.2, h * 0.2);
            d.productID = 0x1230 + i;
            d.vendorID = 0x3456;
            d.serialNum = i;
            d.terminationHandler = ^(id a, id b) {
              NSLog(@"virtual display terminated");
            };
            CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
            CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
            s.hiDPI = scale > 1;
            s.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60] ];
            BOOL ok = [display applySettings:s];
            printf("virtual display %u: %ux%u@%u applied %d\n", display.displayID, w, h, scale, ok);
            if (display) [displays addObject:display];
        }
        sleep(2);
        CGDisplayConfigRef config;
        CGBeginDisplayConfiguration(&config);
        int x = 0;
        for (CGVirtualDisplay *display in displays) {
            CGConfigureDisplayOrigin(config, display.displayID, x, 0);
            x += (int)CGDisplayBounds(display.displayID).size.width;
        }
        CGConfigureDisplayOrigin(config, real, x, 0);
        CGError e = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        sleep(2);
        uint32_t count = 0;
        CGDirectDisplayID ids[8];
        CGGetActiveDisplayList(8, ids, &count);
        printf("arranged (%d); main %u; displays:", e, CGMainDisplayID());
        for (uint32_t i = 0; i < count; i++) {
            CGRect b = CGDisplayBounds(ids[i]);
            printf(" %u %.0f,%.0f %.0fx%.0f px %zux%zu;", ids[i], b.origin.x, b.origin.y, b.size.width, b.size.height,
                   CGDisplayPixelsWide(ids[i]), CGDisplayPixelsHigh(ids[i]));
        }
        printf("\n");
        fflush(stdout);
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
