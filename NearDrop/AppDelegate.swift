//
//  AppDelegate.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Cocoa
import UserNotifications

@main
class AppDelegate: NSObject, NSApplicationDelegate{

    private var connectionManager:NearbyConnectionManager?
	private var statusItem:NSStatusItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
		let menu=NSMenu()
		menu.addItem(withTitle: NSLocalizedString("VisibleToEveryone", value: "Visible to everyone", comment: ""), action: nil, keyEquivalent: "")
		menu.addItem(withTitle: String(format: NSLocalizedString("DeviceName", value: "Device name: %@", comment: ""), arguments: [Host.current().localizedName!]), action: nil, keyEquivalent: "")
		menu.addItem(NSMenuItem.separator())
		menu.addItem(withTitle: NSLocalizedString("Quit", value: "Quit NearDrop", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
		statusItem=NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem?.button?.image=NSImage(named: "MenuBarIcon")
		statusItem?.menu=menu
		
		let nc=UNUserNotificationCenter.current()
		nc.requestAuthorization(options: [.alert, .sound]) { granted, err in
		}
		let incomingTransfersCategory=NDNotificationCenterHackery.hackedNotificationCategory()
		let errorsCategory=UNNotificationCategory(identifier: "ERRORS", actions: [], intentIdentifiers: [])
		nc.setNotificationCategories([incomingTransfersCategory, errorsCategory])
        connectionManager=NearbyConnectionManager()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
		UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

