//
//  NearbyConnectionManager.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Foundation
import Network
import UserNotifications

class NearbyConnectionManager : NSObject, NetServiceDelegate, InboundNearbyConnectionDelegate, UNUserNotificationCenterDelegate{
	
    private var tcpListener:NWListener;
	private let endpointID:[UInt8]=generateEndpointID()
	private var mdnsService:NetService?
	private var activeConnections:[String:InboundNearbyConnection]=[:]
    
	override init() {
        tcpListener=try! NWListener(using: NWParameters(tls: .none))
		super.init()
		UNUserNotificationCenter.current().delegate=self
		startTCPListener()
    }
	
	private func startTCPListener(){
        tcpListener.stateUpdateHandler={(state:NWListener.State) in
			if case .ready = state {
				self.initMDNS()
			}
        }
        tcpListener.newConnectionHandler={(connection:NWConnection) in
			let id=UUID().uuidString
			let conn=InboundNearbyConnection(connection: connection, id: id)
			self.activeConnections[id]=conn
			conn.delegate=self
			conn.start()
        }
        tcpListener.start(queue: .global(qos: .utility))
	}
	
	private static func generateEndpointID()->[UInt8]{
		var id:[UInt8]=[]
		let alphabet="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".compactMap {UInt8($0.asciiValue!)}
		for _ in 0...3{
			id.append(alphabet[Int.random(in: 0..<alphabet.count)])
		}
		return id
	}
	
	private func initMDNS(){
		let nameBytes:[UInt8]=[
			0x23, // PCP
			endpointID[0], endpointID[1], endpointID[2], endpointID[3],
			0xFC, 0x9F, 0x5E, // Service ID hash
			0, 0
		]
		let name=Data(nameBytes).urlSafeBase64EncodedString()
		// 1 byte: Version(3 bits)|Visibility(1 bit)|Device Type(3 bits)|Reserved(1 bits)
		// Device types: unknown=0, phone=1, tablet=2, laptop=3
		var endpointInfo:[UInt8]=[3 << 1]
		// 16 bytes: unknown random bytes
		for _ in 0...15{
			endpointInfo.append(UInt8.random(in: 0...255))
		}
		// Device name in UTF-8 prefixed with 1-byte length
		let hostName=Host.current().localizedName!
		let hostNameChars=hostName.utf8
		endpointInfo.append(UInt8(hostNameChars.count))
		for (i, ch) in hostNameChars.enumerated(){
			guard i<256 else {break}
			endpointInfo.append(UInt8(ch))
		}
		
		let port:Int32=Int32(tcpListener.port!.rawValue)
		mdnsService=NetService(domain: "", type: "_FC9F5ED42C8A._tcp.", name: name, port: port)
		mdnsService?.delegate=self
		mdnsService?.includesPeerToPeer=true
		mdnsService?.setTXTRecord(NetService.data(fromTXTRecord: [
			"n": Data(endpointInfo).urlSafeBase64EncodedString().data(using: .utf8)!
		]))
		mdnsService?.publish()
	}
	
	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
		let notificationContent=UNMutableNotificationContent()
		notificationContent.title="NearDrop"
		notificationContent.subtitle=String(format:NSLocalizedString("PinCode", value: "PIN: %@", comment: ""), arguments: [connection.pinCode!])
		let fileStr:String
		if transfer.files.count==1{
			fileStr=transfer.files[0].name
		}else{
			fileStr=String.localizedStringWithFormat(NSLocalizedString("NFiles", value: "%d files", comment: ""), transfer.files.count)
		}
		notificationContent.body=String(format: NSLocalizedString("DeviceSendingFiles", value: "%1$@ is sending you %2$@", comment: ""), arguments: [device.name, fileStr])
		notificationContent.sound = .default
		notificationContent.categoryIdentifier="INCOMING_TRANSFERS"
		notificationContent.userInfo=["transferID": connection.id]
		NDNotificationCenterHackery.removeDefaultAction(notificationContent)
		let notificationReq=UNNotificationRequest(identifier: "transfer_"+connection.id, content: notificationContent, trigger: nil)
		UNUserNotificationCenter.current().add(notificationReq)
	}
	
	func connectionWasTerminated(connection:InboundNearbyConnection, error:Error?){
		activeConnections.removeValue(forKey: connection.id)
		if let error=error{
			let notificationContent=UNMutableNotificationContent()
			notificationContent.title=String(format: NSLocalizedString("TransferError", value: "Failed to receive files from %@", comment: ""), arguments: [connection.remoteDeviceInfo!.name])
			if let ne=(error as? NearbyError){
				switch ne{
				case .inputOutput(let er):
					notificationContent.body=er.localizedDescription
				case .protocolError(_):
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .requiredFieldMissing:
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .ukey2:
					notificationContent.body=NSLocalizedString("Error.Crypto", value: "Encryption error", comment: "")
				}
			}else{
				notificationContent.body=error.localizedDescription
			}
			notificationContent.categoryIdentifier="ERRORS"
			UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transferError_"+connection.id, content: notificationContent, trigger: nil))
		}
		UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_"+connection.id])
	}
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		activeConnections[response.notification.request.content.userInfo["transferID"]! as! String]?.submitUserConsent(accepted: response.actionIdentifier=="ACCEPT")
		completionHandler()
	}
}

