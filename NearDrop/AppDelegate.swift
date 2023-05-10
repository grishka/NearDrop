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
		let copyToClipboardItem = menu.addItem(withTitle: NSLocalizedString("CopyToClipboardWithoutConsent", value: "Copy to clipboard without consent", comment: ""), action: #selector(toggleOption(_:)), keyEquivalent: "")
		copyToClipboardItem.state = Preferences.copyToClipboardWithoutConsent ? .on : .off
		copyToClipboardItem.tag = .copyToClipboard
		let openLinksItem = menu.addItem(withTitle: NSLocalizedString("OpenLinksInBrowser", value: "Open links in default browser", comment: ""), action: #selector(toggleOption(_:)), keyEquivalent: "")
		openLinksItem.state = Preferences.openLinksInBrowser ? .on : .off
		openLinksItem.tag = .openLinks
		menu.addItem(NSMenuItem.separator())
		menu.addItem(withTitle: NSLocalizedString("Quit", value: "Quit NearDrop", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
		statusItem=NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem?.button?.image=NSImage(named: "MenuBarIcon")
		statusItem?.menu=menu
		
		let nc=UNUserNotificationCenter.current()
		nc.requestAuthorization(options: [.alert, .sound]) { granted, err in
			if !granted{
				DispatchQueue.main.async {
					self.showNotificationsDeniedAlert()
				}
			}
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
	
	func showNotificationsDeniedAlert(){
		let alert=NSAlert()
		alert.alertStyle = .critical
		alert.messageText=NSLocalizedString("NotificationsDenied.Title", value: "Notification Permission Required", comment: "")
		alert.informativeText=NSLocalizedString("NotificationsDenied.Message", value: "NearDrop needs to be able to display notifications for incoming file transfers. Please allow notifications in System Settings.", comment: "")
		alert.addButton(withTitle: NSLocalizedString("NotificationsDenied.OpenSettings", value: "Open settings", comment: ""))
		alert.addButton(withTitle: NSLocalizedString("Quit", value: "Quit NearDrop", comment: ""))
		let result=alert.runModal()
		if result==NSApplication.ModalResponse.alertFirstButtonReturn{
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
		}else if result==NSApplication.ModalResponse.alertSecondButtonReturn{
			NSApplication.shared.terminate(nil)
		}
	}
	
	@objc func toggleOption(_ sender: NSMenuItem) {
		let shouldBeOn = sender.state != .on
		sender.state = shouldBeOn ? .on : .off
		switch sender.tag {
		case .copyToClipboard:
			Preferences.copyToClipboardWithoutConsent = shouldBeOn
		case .openLinks:
			Preferences.openLinksInBrowser = shouldBeOn
		default:
			print("Unhandled toggle menu action")
		}
	}
}

// MARK: - Menu item tags
fileprivate extension Int {
	static let copyToClipboard = 1
	static let openLinks = 2
}
