// SPDX-License-Identifier: GPL-3.0-or-later
// Renders and reads PDF pages for the GDev reader using macOS PDFKit.

#import <PDFKit/PDFKit.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int fail(int status, NSString *message)
{
    fprintf(stderr, "%s\n", message.UTF8String);
    return status;
}

static int printJSON(id value)
{
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length)
        return fail(1, @"Impossibile scrivere la risposta del lettore PDF.");
    return 0;
}

static int render(PDFDocument *document, NSString *output, NSInteger number, NSInteger edge)
{
    NSUInteger index = (NSUInteger)MIN(MAX(1, number), (NSInteger)document.pageCount) - 1;
    PDFPage *page = [document pageAtIndex:index];
    NSSize bounds = [page boundsForBox:kPDFDisplayBoxCropBox].size;
    if (!page || !isfinite(bounds.width) || !isfinite(bounds.height)
        || bounds.width <= 0 || bounds.height <= 0)
        return fail(1, @"La pagina PDF ha dimensioni non valide.");

    NSImage *thumbnail = [page thumbnailOfSize:NSMakeSize(edge, edge) forBox:kPDFDisplayBoxCropBox];
    // Obtain actual pixels from the raster PDFKit made, independent of the display scale.
    CGImageRef image = [thumbnail CGImageForProposedRect:NULL context:nil hints:nil];
    NSBitmapImageRep *bitmap = image ? [[NSBitmapImageRep alloc] initWithCGImage:image] : nil;
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:output options:NSDataWritingAtomic error:nil])
        return fail(1, @"Impossibile salvare l'immagine della pagina PDF.");

    return printJSON(@{ @"pages": @(document.pageCount), @"page": @(index + 1),
                        @"width": @(bitmap.pixelsWide), @"height": @(bitmap.pixelsHigh) });
}

static int writeText(PDFDocument *document, NSInteger page)
{
    if (page < 0 || (NSUInteger)page > document.pageCount)
        return fail(2, @"Numero di pagina PDF non valido.");
    if (!document.allowsCopying)
        return fail(1, @"Il documento PDF disabilita la copia del testo.");

    NSUInteger first = page ? (NSUInteger)page - 1 : 0;
    NSUInteger end = page ? (NSUInteger)page : document.pageCount;
    for (NSUInteger index = first; index < end; index++) {
        @autoreleasepool {
            NSString *text = [document pageAtIndex:index].string;
            NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
            if ((index > first && fputc('\f', stdout) == EOF)
                || (data.length && fwrite(data.bytes, 1, data.length, stdout) != data.length))
                return fail(1, @"Impossibile scrivere il testo del PDF.");
        }
    }
    return 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3)
            return fail(2, @"Uso: gdev-pdf render|text FILE ARGOMENTI");

        NSString *path = [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:argv[2] length:strlen(argv[2])];
        PDFDocument *document = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
        if (!document)
            return fail(1, @"Impossibile aprire il documento PDF.");

        if (document.isLocked) {
            NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            NSString *password = [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding];
            if (password.length == 0 || ![document unlockWithPassword:password])
                return fail(4, @"Il documento PDF richiede una password valida.");
        }
        if (!document.pageCount)
            return fail(1, @"Il documento PDF non contiene pagine leggibili.");

        NSString *operation = [NSString stringWithUTF8String:argv[1]];
        if ([operation isEqualToString:@"render"] && argc == 6) {
            NSString *output = [[NSFileManager defaultManager]
                stringWithFileSystemRepresentation:argv[5] length:strlen(argv[5])];
            NSInteger page = [[NSString stringWithUTF8String:argv[3]] integerValue];
            NSInteger edge = [[NSString stringWithUTF8String:argv[4]] integerValue];
            if (edge < 1 || edge > 2048)
                return fail(2, @"Dimensione dell'immagine PDF non valida.");
            return render(document, output, page, edge);
        }
        if ([operation isEqualToString:@"text"] && argc == 4)
            return writeText(document, [[NSString stringWithUTF8String:argv[3]] integerValue]);
        return fail(2, @"Operazione PDF non valida.");
    }
}
