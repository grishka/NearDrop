//
//  ShareViewController.swift
//  ShareExtension
//
//  Created by Grishka on 12.09.2023.
//

import Foundation
import Cocoa
import NearbyShare

class ShareViewController: NSViewController, ShareExtensionDelegate{
	
	private var urls:[URL]=[]
	private var foundDevices:[RemoteDeviceInfo]=[]
	private var chosenDevice:RemoteDeviceInfo?
	private var lastError:Error?
	
	@IBOutlet var filesIcon:NSImageView?
	@IBOutlet var filesLabel:NSTextField?
	@IBOutlet var loadingOverlay:NSStackView?
	@IBOutlet var largeProgress:NSProgressIndicator?
	@IBOutlet var listView:NSCollectionView?
	@IBOutlet var listViewWrapper:NSView?
	@IBOutlet var contentWrap:NSView?
	@IBOutlet var progressView:NSView?
	@IBOutlet var progressDeviceIcon:NSImageView?
	@IBOutlet var progressDeviceName:NSTextField?
	@IBOutlet var progressProgressBar:NSProgressIndicator?
	@IBOutlet var progressState:NSTextField?
	@IBOutlet var progressDeviceIconWrap:NSView?
	@IBOutlet var progressDeviceSecondaryIcon:NSImageView?
	
	override var nibName: NSNib.Name? {
		return NSNib.Name("ShareViewController")
	}

	override func loadView() {
		super.loadView()
	
		// Insert code here to customize the view
		let item = self.extensionContext!.inputItems[0] as! NSExtensionItem
			if let attachments = item.attachments {
			for attachment in attachments as NSArray{
				let provider=attachment as! NSItemProvider
				provider.loadItem(forTypeIdentifier: kUTTypeURL as String) { data, err in
					if let url=URL(dataRepresentation: data as! Data, relativeTo: nil, isAbsolute: false){
						self.urls.append(url)
						if self.urls.count==attachments.count{
							DispatchQueue.main.async {
								self.urlsReady()
							}
						}
					}
				}
			}
		} else {
			let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
			self.extensionContext!.cancelRequest(withError: cancelError)
			return
		}
		
		contentWrap!.addSubview(listViewWrapper!)
		contentWrap!.addSubview(loadingOverlay!)
		contentWrap!.addSubview(progressView!)
		progressView!.isHidden=true
		
		listViewWrapper!.translatesAutoresizingMaskIntoConstraints=false
		loadingOverlay!.translatesAutoresizingMaskIntoConstraints=false
		progressView!.translatesAutoresizingMaskIntoConstraints=false
		NSLayoutConstraint.activate([
			NSLayoutConstraint(item: listViewWrapper!, attribute: .width, relatedBy: .equal, toItem: contentWrap, attribute: .width, multiplier: 1, constant: 0),
			NSLayoutConstraint(item: listViewWrapper!, attribute: .height, relatedBy: .equal, toItem: contentWrap, attribute: .height, multiplier: 1, constant: 0),
			
			NSLayoutConstraint(item: loadingOverlay!, attribute: .width, relatedBy: .equal, toItem: contentWrap, attribute: .width, multiplier: 1, constant: 0),
			NSLayoutConstraint(item: loadingOverlay!, attribute: .centerY, relatedBy: .equal, toItem: contentWrap, attribute: .centerY, multiplier: 1, constant: 0),
			
			NSLayoutConstraint(item: progressView!, attribute: .width, relatedBy: .equal, toItem: contentWrap, attribute: .width, multiplier: 1, constant: 0),
			NSLayoutConstraint(item: progressView!, attribute: .centerY, relatedBy: .equal, toItem: contentWrap, attribute: .centerY, multiplier: 1, constant: 0)
		])
		
		largeProgress!.startAnimation(nil)
		let flowLayout=NSCollectionViewFlowLayout()
		flowLayout.itemSize=NSSize(width: 75, height: 90)
		flowLayout.sectionInset=NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
		flowLayout.minimumInteritemSpacing=10
		flowLayout.minimumLineSpacing=10
		listView!.collectionViewLayout=flowLayout
		listView!.dataSource=self
		
		progressDeviceIconWrap!.wantsLayer=true
		progressDeviceIconWrap!.layer!.masksToBounds=false
	}
	
	override func viewDidLoad(){
		super.viewDidLoad()
		NearbyConnectionManager.shared.startDeviceDiscovery()
		NearbyConnectionManager.shared.addShareExtensionDelegate(self)
	}
	
	override func viewWillDisappear() {
		if chosenDevice==nil{
			NearbyConnectionManager.shared.stopDeviceDiscovery()
		}
		NearbyConnectionManager.shared.removeShareExtensionDelegate(self)
	}

	@IBAction func cancel(_ sender: AnyObject?) {
		if let device=chosenDevice{
			NearbyConnectionManager.shared.cancelOutgoingTransfer(id: device.id!)
		}
		let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
		self.extensionContext!.cancelRequest(withError: cancelError)
	}
	
	private func urlsReady(){
		for url in urls{
			if url.isFileURL{
				let isDirectory=UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
				if FileManager.default.fileExists(atPath: url.path, isDirectory: isDirectory) && isDirectory.pointee.boolValue{
					print("Canceling share request because URL \(url) is a directory")
					let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
					self.extensionContext!.cancelRequest(withError: cancelError)
					return
				}
			}
		}
		if urls.count==1{
			if urls[0].isFileURL{
				filesLabel!.stringValue=urls[0].lastPathComponent
				filesIcon!.image=NSWorkspace.shared.icon(forFile: urls[0].path)
			}else if urls[0].scheme=="http" || urls[0].scheme=="https"{
				filesLabel!.stringValue=urls[0].absoluteString
				filesIcon!.image=NSImage(named: NSImage.networkName)
			}
		}else{
			filesLabel!.stringValue=String.localizedStringWithFormat(NSLocalizedString("NFiles", value: "%d files", comment: ""), urls.count)
			filesIcon!.image=NSImage(named: NSImage.multipleDocumentsName)
		}
	}
	
	func addDevice(device: RemoteDeviceInfo) {
		if foundDevices.isEmpty{
			loadingOverlay?.animator().isHidden=true
		}
		foundDevices.append(device)
		listView?.animator().insertItems(at: [[0, foundDevices.count-1]])
	}
	
	func removeDevice(id: String){
		if chosenDevice != nil{
			return
		}
		for i in foundDevices.indices{
			if foundDevices[i].id==id{
				foundDevices.remove(at: i)
				listView?.animator().deleteItems(at: [[0, i]])
				break
			}
		}
		if foundDevices.isEmpty{
			loadingOverlay?.animator().isHidden=false
		}
	}
	
	func connectionWasEstablished(pinCode: String) {
		progressState?.stringValue=String(format:NSLocalizedString("PinCode", value: "PIN: %@", comment: ""), arguments: [pinCode])
		progressProgressBar?.isIndeterminate=false
		progressProgressBar?.maxValue=1000
		progressProgressBar?.doubleValue=0
	}
	
	func connectionFailed(with error: Error) {
		progressProgressBar?.isIndeterminate=false
		progressProgressBar?.maxValue=1000
		progressProgressBar?.doubleValue=0
		lastError=error
		if let ne=(error as? NearbyError), case let .canceled(reason)=ne{
			switch reason{
			case .userRejected:
				progressState?.stringValue=NSLocalizedString("TransferDeclined", value: "Declined", comment: "")
			case .userCanceled:
				progressState?.stringValue=NSLocalizedString("TransferCanceled", value: "Canceled", comment: "")
			case .notEnoughSpace:
				progressState?.stringValue=NSLocalizedString("NotEnoughSpace", value: "Not enough disk space", comment: "")
			case .unsupportedType:
				progressState?.stringValue=NSLocalizedString("UnsupportedType", value: "Attachment type not supported", comment: "")
			case .timedOut:
				progressState?.stringValue=NSLocalizedString("TransferTimedOut", value: "Timed out", comment: "")
			}
			progressDeviceSecondaryIcon?.isHidden=false
			dismissDelayed()
		}else{
			let alert=NSAlert(error: error)
			alert.beginSheetModal(for: view.window!) { resp in
				self.extensionContext!.cancelRequest(withError: error)
			}
		}
	}
	
	func transferAccepted() {
		progressState?.stringValue=NSLocalizedString("Sending", value: "Sending...", comment: "")
	}
	
	func transferProgress(progress: Double) {
		progressProgressBar!.doubleValue=progress*progressProgressBar!.maxValue
	}
	
	func transferFinished() {
		progressState?.stringValue=NSLocalizedString("TransferFinished", value: "Transfer finished", comment: "")
		dismissDelayed()
	}
	
	func selectDevice(device:RemoteDeviceInfo){
		NearbyConnectionManager.shared.stopDeviceDiscovery()
		listViewWrapper?.animator().isHidden=true
		progressView?.animator().isHidden=false
		progressDeviceName?.stringValue=device.name
		progressDeviceIcon?.image=imageForDeviceType(type: device.type)
		progressProgressBar?.startAnimation(nil)
		progressState?.stringValue=NSLocalizedString("Connecting", value: "Connecting...", comment: "")
		chosenDevice=device
		NearbyConnectionManager.shared.startOutgoingTransfer(deviceID: device.id!, delegate: self, urls: urls)
	}
	
	private func dismissDelayed(){
		DispatchQueue.main.asyncAfter(deadline: .now()+2.0){
			if let error=self.lastError{
				self.extensionContext!.cancelRequest(withError: error)
			}else{
				self.extensionContext!.completeRequest(returningItems: nil, completionHandler: nil)
			}
		}
	}
}

fileprivate func imageForDeviceType(type:RemoteDeviceInfo.DeviceType)->NSImage{
	let imageName:String
	switch type{
	case .tablet:
		imageName="com.apple.ipad"
	case .computer:
		imageName="com.apple.macbookpro-13-unibody"
	default: // also .phone
		imageName="com.apple.iphone"
	}
	return NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(imageName).icns")!
}

extension ShareViewController:NSCollectionViewDataSource{
	func numberOfSections(in collectionView: NSCollectionView) -> Int {
		return 1
	}
	
	func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
		return foundDevices.count
	}
	
	func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
		let item=collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "DeviceListCell"), for: indexPath)
		guard let collectionViewItem = item as? DeviceListCell else {return item}
		let device=foundDevices[indexPath[1]]
		collectionViewItem.textField?.stringValue=device.name
		collectionViewItem.imageView?.image=imageForDeviceType(type: device.type)
		// TODO maybe there's a better way to handle clicks on collection view items? I'm still new to Apple's way of doing UIs so I may do dumb shit occasionally
		collectionViewItem.clickHandler={
			self.selectDevice(device: device)
		}
		return collectionViewItem
	}
}
