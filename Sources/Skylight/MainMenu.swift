import AppKit
import SkylightBrowser

/// The menu bar. Browser commands go to the app delegate; editing commands (copy, paste, undo)
/// go to the first responder, so they reach the page or a text field.
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Skylight", [
            item("About Skylight", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: nil),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: target),
            .separator(),
            item("Copy Claude Code Connection Command", #selector(AppDelegate.copyAgentCommand(_:)), "", target: target),
            item("Show Packages Folder", #selector(AppDelegate.showPackages(_:)), "", target: target),
            .separator(),
            item("Hide Skylight", #selector(NSApplication.hide(_:)), "h", target: nil),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: nil),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", target: nil),
            .separator(),
            item("Quit Skylight", #selector(NSApplication.terminate(_:)), "q", target: nil),
        ]))

        main.addItem(submenu("File", [
            item("New Tab", #selector(AppDelegate.newTab(_:)), "t", target: target),
            item("Open Location…", #selector(AppDelegate.openLocation(_:)), "l", target: target),
            item("Reopen Closed Tab", #selector(AppDelegate.reopenTab(_:)), "t", [.command, .shift], target: target),
            .separator(),
            item("New Space", #selector(AppDelegate.newSpace(_:)), "n", [.command, .shift], target: target),
            item("New Folder", #selector(AppDelegate.newFolder(_:)), "n", [.command, .option], target: target),
            .separator(),
            submenu("Import From", Browser.ImportSource.allCases.filter(\.isAvailable).map { source in
                let item = item(source.rawValue, #selector(AppDelegate.importFrom(_:)), "", target: target)
                item.representedObject = source.rawValue
                return item
            } + [.separator(), item("Passwords from CSV…", #selector(AppDelegate.importPasswordsCSV(_:)), "", target: target)]),
            .separator(),
            item("Close Tab", #selector(AppDelegate.closeTab(_:)), "w", target: target),
            item("Close Window", #selector(AppDelegate.close(_:)), "w", [.command, .shift], target: target),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", target: nil),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], target: nil),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", target: nil),
            item("Copy", #selector(NSText.copy(_:)), "c", target: nil),
            item("Paste", #selector(NSText.paste(_:)), "v", target: nil),
            item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil),
            .separator(),
            item("Copy Link", #selector(AppDelegate.copyURL(_:)), "c", [.command, .shift], target: target),
        ]))

        main.addItem(submenu("View", [
            item("Toggle Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "s", target: target),
            .separator(),
            item("Reload Page", #selector(AppDelegate.reload(_:)), "r", target: target),
            item("Stop", #selector(AppDelegate.stopLoading(_:)), ".", target: target),
            .separator(),
            item("Boost This Site", #selector(AppDelegate.boostSite(_:)), "b", [.command, .shift], target: target),
            item("Picture in Picture", #selector(AppDelegate.pictureInPicture(_:)), "p", [.command, .option], target: target),
            item("Developer Tools", #selector(AppDelegate.developerTools(_:)), "i", [.command, .option], target: target),
        ]))

        main.addItem(submenu("History", [
            item("Back", #selector(AppDelegate.goBack(_:)), "[", target: target),
            item("Forward", #selector(AppDelegate.goForward(_:)), "]", target: target),
        ]))

        var spaceItems: [NSMenuItem] = [
            item("Next Tab", #selector(AppDelegate.nextTab(_:)), "\t", [.control], target: target),
            item("Previous Tab", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift], target: target),
            item("Pin Tab", #selector(AppDelegate.togglePin(_:)), "d", target: target),
            item("Add to Favorites", #selector(AppDelegate.toggleFavorite(_:)), "d", [.command, .shift], target: target),
            item("Clear Today", #selector(AppDelegate.clearToday(_:)), "k", [.command, .shift], target: target),
            .separator(),
            item("New Tab in Split View", #selector(AppDelegate.newSplitTab(_:)), "n", [.command, .control], target: target),
            item("Focus Next Pane", #selector(AppDelegate.nextPane(_:)), "]", [.command, .control], target: target),
            item("Focus Previous Pane", #selector(AppDelegate.previousPane(_:)), "[", [.command, .control], target: target),
            item("Rotate Split", #selector(AppDelegate.rotateSplit(_:)), "r", [.command, .control], target: target),
            item("Separate Split", #selector(AppDelegate.separateSplit(_:)), "", target: target),
            .separator(),
            item("Next Space", #selector(AppDelegate.nextSpace(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option], target: target),
            item("Previous Space", #selector(AppDelegate.previousSpace(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option], target: target),
        ]
        for n in 1...9 {
            let space = item("Space \(n)", #selector(AppDelegate.switchToSpace(_:)), "\(n)", [.control], target: target)
            space.tag = n - 1
            spaceItems.append(space)
        }
        main.addItem(submenu("Tabs", spaceItems))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), "", target: nil),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }
}
