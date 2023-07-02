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
    let menu=NSMenu()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
		
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
        menu.addItem(withTitle: NSLocalizedString("VisibleToEveryone", value: "Visible to everyone", comment: ""), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: String(format: NSLocalizedString("DeviceName", value: "Device name: %@", comment: ""), arguments: [Host.current().localizedName!]), action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: NSLocalizedString("Enable", value: "Enable", comment: ""),
                     action: #selector(enableNearDrop)  , keyEquivalent: "").target = self
        menu.addItem(withTitle: NSLocalizedString("Disable", value: "Disable", comment: ""), action: #selector(disableNearDrop), keyEquivalent: "").target = self
        menu.addItem(withTitle: NSLocalizedString("Quit", value: "Quit NearDrop", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem=NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image=NSImage(named: "MenuBarIcon")
        statusItem?.menu=menu
        setMenuItemState()
    }
    
    func setMenuItemState() {
        if connectionManager!.getListenerStatus() {
            menu.item(at: 3)?.isHidden = true
            menu.item(at: 4)?.isHidden = false
        } else {
            menu.item(at: 3)?.isHidden = false
            menu.item(at: 4)?.isHidden = true
        }
    }
    @objc
    func enableNearDrop() {
        connectionManager?.restartTCPListener()
        setMenuItemState()
    }
    @objc
    func disableNearDrop() {
        connectionManager?.stopTCPListener()
        setMenuItemState()
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
}

