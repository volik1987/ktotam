// Иконка «Кто там»: плашка ADE (как ~/Documents/ade_icons/mkicon) + значок Face ID в правом верхнем углу.
// mkicon_ktotam <logo.svg> <подпись> <out.icns>
#import <Cocoa/Cocoa.h>

static NSBitmapImageRep *Render(NSImage *logo, NSString *label, int px) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGFloat s = px / 1024.0;

    // Подложка по сетке иконок macOS: 824×824 с отступом 100, скругление ~185.
    NSRect plate = NSMakeRect(100 * s, 100 * s, 824 * s, 824 * s);
    NSShadow *sh = [NSShadow new];
    sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
    sh.shadowBlurRadius = 18 * s; sh.shadowOffset = NSMakeSize(0, -8 * s);
    [NSGraphicsContext saveGraphicsState];
    [sh set];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:plate xRadius:185 * s yRadius:185 * s];
    [[NSColor whiteColor] setFill]; [path fill];
    [NSGraphicsContext restoreGraphicsState];
    [[[NSGradient alloc] initWithStartingColor:[NSColor whiteColor]
                                  endingColor:[NSColor colorWithCalibratedWhite:0.92 alpha:1]] drawInBezierPath:path angle:-90];

    // Зелёная полоса снизу в цвет буквы D.
    NSColor *green = [NSColor colorWithCalibratedRed:0x8F/255.0 green:0xC6/255.0 blue:0x26/255.0 alpha:1];
    [NSGraphicsContext saveGraphicsState];
    [path addClip];
    [green setFill];
    NSRectFill(NSMakeRect(100 * s, 100 * s, 824 * s, 70 * s));
    [NSGraphicsContext restoreGraphicsState];

    // Логотип.
    CGFloat lw = 600 * s, lh = lw * logo.size.height / logo.size.width;
    lw = 560 * s; lh = lw * logo.size.height / logo.size.width;
    [logo drawInRect:NSMakeRect(150 * s, 500 * s, lw, lh)];

    // Подпись: шрифт подбирается по ширине.
    CGFloat fs = 150 * s;
    NSDictionary *attrs;
    NSSize ts;
    do {
        attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:fs weight:NSFontWeightBold],
                  NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0x12/255.0 green:0x12/255.0 blue:0x13/255.0 alpha:1]};
        ts = [label sizeWithAttributes:attrs];
        fs -= 4 * s;
    } while (ts.width > 680 * s);
    [label drawAtPoint:NSMakePoint((px - ts.width) / 2, 330 * s - ts.height / 2) withAttributes:attrs];

    // Значок: зелёный круг с белым лицом в рамке распознавания.
    NSPoint c = NSMakePoint(838 * s, 838 * s);
    CGFloat r = 150 * s;
    NSRect br = NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r);
    NSShadow *bs = [NSShadow new];
    bs.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
    bs.shadowBlurRadius = 16 * s; bs.shadowOffset = NSMakeSize(0, -6 * s);
    [NSGraphicsContext saveGraphicsState];
    [bs set];
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(br, -14 * s, -14 * s)] fill];
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:br];
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0xA8/255.0 green:0xD8/255.0 blue:0x4A/255.0 alpha:1]
                                  endingColor:[NSColor colorWithCalibratedRed:0x5E/255.0 green:0x9A/255.0 blue:0x12/255.0 alpha:1]]
        drawInBezierPath:circle angle:-90];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:170 * s weight:NSFontWeightSemibold];
    cfg = [cfg configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[NSColor whiteColor]]];
    NSImage *sym = [[NSImage imageWithSystemSymbolName:@"faceid" accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    if (sym) {
        NSSize ss = sym.size;
        CGFloat k = 190 * s / MAX(ss.width, ss.height);
        NSRect dr = NSMakeRect(c.x - ss.width * k / 2, c.y - ss.height * k / 2, ss.width * k, ss.height * k);
        [sym drawInRect:dr];
    }

    [NSGraphicsContext restoreGraphicsState];
    return rep;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: mkicon logo.svg label out.icns\n"); return 1; }
        NSImage *logo = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
        if (!logo) { fprintf(stderr, "не удалось загрузить логотип\n"); return 1; }
        NSString *label = @(argv[2]);
        NSString *out = @(argv[3]);
        NSString *set = [[out stringByDeletingPathExtension] stringByAppendingPathExtension:@"iconset"];
        [NSFileManager.defaultManager createDirectoryAtPath:set withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSNumber *n in @[@16, @32, @128, @256, @512]) {
            int b = n.intValue;
            for (int scale = 1; scale <= 2; scale++) {
                NSString *name = scale == 1 ? [NSString stringWithFormat:@"icon_%dx%d.png", b, b]
                                            : [NSString stringWithFormat:@"icon_%dx%d@2x.png", b, b];
                NSData *png = [Render(logo, label, b * scale) representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [png writeToFile:[set stringByAppendingPathComponent:name] atomically:YES];
            }
        }
        NSTask *t = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/iconutil"]
                      arguments:@[@"-c", @"icns", set, @"-o", out] error:nil terminationHandler:nil];
        [t waitUntilExit];
        return t.terminationStatus;
    }
}
