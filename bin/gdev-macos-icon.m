// Copyright (C) 2026 Giacomo Picchiarelli
// SPDX-License-Identifier: GPL-3.0-or-later

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <emacs-module.h>
#include <stdlib.h>

int plugin_is_GPL_compatible;

static NSString *const application_name = @"GDev-Emacs";
static Ivar dialog_heading;
static IMP resize_emacs_dialog;

static void
resize_localized_emacs_dialog(id panel, SEL selector)
{
    NSTextField *heading = object_getIvar(panel, dialog_heading);
    if ([heading isKindOfClass:NSTextField.class]) {
        NSString *label = heading.stringValue;
        if ([label isEqualToString:@"Question"])
            heading.stringValue = @"Conferma";
        else if ([label isEqualToString:@"Information"])
            heading.stringValue = @"Informazione";
    }
    ((void (*)(id, SEL))resize_emacs_dialog)(panel, selector);
}

static void
localize_emacs_dialog_heading(void)
{
    // Il pannello di Emacs imposta il titolo in inglese prima del layout.
    // Interveniamo solo su questa classe, prima che misuri il testo.
    Class panel = NSClassFromString(@"EmacsDialogPanel");
    if (panel == Nil || resize_emacs_dialog != NULL)
        return;
    Ivar heading = class_getInstanceVariable(panel, "command");
    Method resize = class_getInstanceMethod(panel, NSSelectorFromString(@"resizeBoundsPriorToDisplay"));
    if (heading == NULL || ivar_getTypeEncoding(heading)[0] != '@'
        || resize == NULL || method_getNumberOfArguments(resize) != 2
        || method_getTypeEncoding(resize)[0] != 'v')
        return;
    dialog_heading = heading;
    resize_emacs_dialog = method_setImplementation(resize, (IMP)resize_localized_emacs_dialog);
}

@interface GDevAboutPanel : NSObject
+ (void)show:(id)sender;
@end

@implementation GDevAboutPanel
+ (void)show:(id)sender
{
    (void)sender;
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName: application_name,
        NSAboutPanelOptionApplicationIcon: NSApp.applicationIconImage,
    }];
}
@end

static void
set_application_name(void)
{
    // Emacs conserva il nome iniziale per i dialoghi e per il menu dell'app.
    NSString * __unsafe_unretained *emacs_name =
        (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "ns_app_name");
    NSProcessInfo.processInfo.processName = application_name;
    if (emacs_name == NULL)
        return;

    NSMenu *menu = NSApp.mainMenu;
    NSMenuItem *application_item = menu.numberOfItems > 0 ? [menu itemAtIndex:0] : nil;
    if ([application_item.title isEqualToString:*emacs_name]
        || [application_item.title isEqualToString:application_name]) {
        application_item.title = application_name;
        application_item.submenu.title = application_name;
        for (NSMenuItem *item in application_item.submenu.itemArray) {
            SEL action = item.action;
            // Emacs scrive «Preferences...»: la guida e il menu di GDev dicono Impostazioni.
            if ([item.title hasPrefix:@"Preferences"])
                item.title = @"Impostazioni…";
            if (action == @selector(orderFrontStandardAboutPanel:)
                || action == @selector(hide:) || action == @selector(terminate:)) {
                if (![item.title containsString:application_name])
                    item.title = [item.title stringByReplacingOccurrencesOfString:@"Emacs"
                                                                       withString:application_name];
                if (action == @selector(orderFrontStandardAboutPanel:)) {
                    item.target = [GDevAboutPanel class];
                    item.action = @selector(show:);
                }
            }
        }
    }
    *emacs_name = application_name;
}

static emacs_value
set_application_icon(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs;
    (void)data;
    emacs_value failure = env->intern(env, "nil");
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[0], NULL, &size))
        return failure;

    char *path = malloc(size);
    if (path == NULL)
        return failure;
    BOOL installed = NO;
    @autoreleasepool {
        if (env->copy_string_contents(env, args[0], path, &size)) {
            NSString *filename = [NSString stringWithUTF8String:path];
            NSImage *image = filename ? [[NSImage alloc] initWithContentsOfFile:filename] : nil;
            if (NSApp && image.isValid) {
                // EmacsDialogPanel cerca per nome l'icona, oltre agli avvisi AppKit.
                [[NSImage imageNamed:NSImageNameApplicationIcon] setName:nil];
                installed = [image setName:NSImageNameApplicationIcon];
                NSApp.applicationIconImage = image;
                set_application_name();
            }
        }
    }
    free(path);
    return installed ? env->intern(env, "t") : failure;
}

int
emacs_module_init(struct emacs_runtime *runtime)
{
    emacs_env *env = runtime->get_environment(runtime);
    emacs_value arguments[] = {
        env->intern(env, "gdev-macos--set-application-icon"),
        env->make_function(env, 1, 1, set_application_icon,
                           "Applica il nome e l'icona ICON di GDev-Emacs al processo grafico.", NULL)
    };
    env->funcall(env, env->intern(env, "fset"), 2, arguments);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return 1;
    localize_emacs_dialog_heading();
    return 0;
}
