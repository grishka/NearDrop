//
//  NearbyConnectionManager.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Foundation
import Network
import System

public struct RemoteDeviceInfo{
	public let name:String
	public let type:DeviceType
	public var id:String?
	
	init(name: String, type: DeviceType, id: String? = nil) {
		self.name = name
		self.type = type
		self.id = id
	}
	
	init(info:EndpointInfo){
		self.name=info.name
		self.type=info.deviceType
	}
	
	public enum DeviceType:Int32{
		case unknown=0
		case phone
		case tablet
		case computer
		
		public static func fromRawValue(value:Int) -> DeviceType{
			switch value {
			case 0:
				return .unknown
			case 1:
				return .phone
			case 2:
				return .tablet
			case 3:
				return .computer
			default:
				return .unknown
			}
		}
	}
}


public enum NearbyError:Error{
	case protocolError(_ message:String)
	case requiredFieldMissing
	case ukey2
	case inputOutput(cause:Errno)
	case canceled(reason:CancellationReason)
	
	public enum CancellationReason{
		case userRejected, userCanceled, notEnoughSpace, unsupportedType, timedOut
	}
}

public struct TransferMetadata{
	public let files:[FileMetadata]
	public let id:String
	public let pinCode:String?
	public let textDescription:String?
	
	init(files: [FileMetadata], id: String, pinCode: String?, textDescription: String?=nil){
		self.files = files
		self.id = id
		self.pinCode = pinCode
		self.textDescription = textDescription
	}
}

public struct FileMetadata{
	public let name:String
	public let size:Int64
	public let mimeType:String
}

struct FoundServiceInfo{
	let service:NWBrowser.Result
	var device:RemoteDeviceInfo?
}

struct OutgoingTransferInfo{
	let service:NWBrowser.Result
	let device:RemoteDeviceInfo
	let connection:OutboundNearbyConnection
	let delegate:ShareExtensionDelegate
}

struct EndpointInfo{
	let name:String
	let deviceType:RemoteDeviceInfo.DeviceType
	
	init(name: String, deviceType: RemoteDeviceInfo.DeviceType){
		self.name = name
		self.deviceType = deviceType
	}
	
	init?(data:Data){
		guard data.count>17 else {return nil}
		let deviceNameLength=Int(data[17])
		guard data.count>=deviceNameLength+18 else {return nil}
		guard let deviceName=String(data: data[18..<(18+deviceNameLength)], encoding: .utf8) else {return nil}
		let rawDeviceType:Int=Int(data[0] & 7) >> 1
		self.name=deviceName
		self.deviceType=RemoteDeviceInfo.DeviceType.fromRawValue(value: rawDeviceType)
	}
	
	func serialize()->Data{
		// 1 byte: Version(3 bits)|Visibility(1 bit)|Device Type(3 bits)|Reserved(1 bits)
		// Device types: unknown=0, phone=1, tablet=2, laptop=3
		var endpointInfo:[UInt8]=[UInt8(deviceType.rawValue << 1)]
		// 16 bytes: unknown random bytes
		for _ in 0...15{
			endpointInfo.append(UInt8.random(in: 0...255))
		}
		// Device name in UTF-8 prefixed with 1-byte length
		var nameChars=[UInt8](name.utf8)
		if nameChars.count>255{
			nameChars=[UInt8](nameChars[0..<255])
		}
		endpointInfo.append(UInt8(nameChars.count))
		for ch in nameChars{
			endpointInfo.append(UInt8(ch))
		}
		return Data(endpointInfo)
	}
}

public protocol MainAppDelegate{
	func obtainUserConsent(for transfer:TransferMetadata, from device:RemoteDeviceInfo)
	func incomingTransfer(id:String, didFinishWith error:Error?)
}

public protocol ShareExtensionDelegate:AnyObject{
	func addDevice(device:RemoteDeviceInfo)
	func removeDevice(id:String)
	func connectionWasEstablished(pinCode:String)
	func connectionFailed(with error:Error)
	func transferAccepted()
	func transferProgress(progress:Double)
	func transferFinished()
}

public class NearbyConnectionManager : NSObject, NetServiceDelegate, InboundNearbyConnectionDelegate, OutboundNearbyConnectionDelegate{
	
	private var tcpListener:NWListener?;
    private var listenerStatus:Bool = false
	public let endpointID:[UInt8]=generateEndpointID()
	private var mdnsService:NetService?
	private var activeConnections:[String:InboundNearbyConnection]=[:]
	private var foundServices:[String:FoundServiceInfo]=[:]
	private var shareExtensionDelegates:[ShareExtensionDelegate]=[]
	private var outgoingTransfers:[String:OutgoingTransferInfo]=[:]
	public var mainAppDelegate:(any MainAppDelegate)?
	private var discoveryRefCount=0
	
	private var browser:NWBrowser?
	
	public static let shared=NearbyConnectionManager()
	
	override init() {
		super.init()
	}
	
	public func becomeVisible(){
        setTCPListener()
		startTCPListener()
	}
    
    public func becomeInvisible(){
        stopTCPListener()
    }
    
    public func getVisibilityStatus() -> Bool {
             return listenerStatus
    }

    private func setTCPListener() {
             tcpListener=try! NWListener(using: NWParameters(tls: .none))
    }
	
	private func startTCPListener(){
		tcpListener?.stateUpdateHandler={(state:NWListener.State) in
			if case .ready = state {
				self.initMDNS()
			}
		}
		tcpListener?.newConnectionHandler={(connection:NWConnection) in
			let id=UUID().uuidString
			let conn=InboundNearbyConnection(connection: connection, id: id)
			self.activeConnections[id]=conn
			conn.delegate=self
			conn.start()
		}
		tcpListener?.start(queue: .global(qos: .utility))
        listenerStatus = true
	}
    
    private func stopTCPListener() {
             tcpListener?.cancel()
             tcpListener = nil
             self.mdnsService?.stop()
             listenerStatus = false
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
		let endpointInfo=EndpointInfo(name: Host.current().localizedName!, deviceType: .computer)
		
		let port:Int32=Int32((tcpListener?.port!.rawValue)!)
		mdnsService=NetService(domain: "", type: "_FC9F5ED42C8A._tcp.", name: name, port: port)
		mdnsService?.delegate=self
		mdnsService?.setTXTRecord(NetService.data(fromTXTRecord: [
			"n": endpointInfo.serialize().urlSafeBase64EncodedString().data(using: .utf8)!
		]))
		mdnsService?.publish()
	}
	
	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
		guard let delegate=mainAppDelegate else {return}
		delegate.obtainUserConsent(for: transfer, from: device)
	}
	
	func connectionWasTerminated(connection:InboundNearbyConnection, error:Error?){
		guard let delegate=mainAppDelegate else {return}
		delegate.incomingTransfer(id: connection.id, didFinishWith: error)
		activeConnections.removeValue(forKey: connection.id)
	}
	
	public func submitUserConsent(transferID:String, accept:Bool){
		guard let conn=activeConnections[transferID] else {return}
		conn.submitUserConsent(accepted: accept)
	}
	
	public func startDeviceDiscovery(){
		if discoveryRefCount==0{
			foundServices.removeAll()
			if browser==nil{
				browser=NWBrowser(for: .bonjourWithTXTRecord(type: "_FC9F5ED42C8A._tcp.", domain: nil), using: .tcp)
				browser?.browseResultsChangedHandler={newResults, changes in
					for change in changes{
						switch change{
						case let .added(res):
							self.maybeAddFoundDevice(service: res)
						case let .removed(res):
							self.maybeRemoveFoundDevice(service: res)
						default:
							break
						}
					}
				}
			}
			browser?.start(queue: .main)
		}
		discoveryRefCount+=1
	}
	
	public func stopDeviceDiscovery(){
		discoveryRefCount-=1
		assert(discoveryRefCount>=0)
		if discoveryRefCount==0{
			browser?.cancel()
			browser=nil
		}
	}
	
	public func addShareExtensionDelegate(_ delegate:ShareExtensionDelegate){
		shareExtensionDelegates.append(delegate)
		for service in foundServices.values{
			guard let device=service.device else {continue}
			delegate.addDevice(device: device)
		}
	}
	
	public func removeShareExtensionDelegate(_ delegate:ShareExtensionDelegate){
		shareExtensionDelegates.removeAll(where: {$0===delegate})
	}
	
	public func cancelOutgoingTransfer(id:String){
		guard let transfer=outgoingTransfers[id] else {return}
		transfer.connection.cancel()
	}
	
	private func endpointID(for service:NWBrowser.Result)->String?{
		guard case let NWEndpoint.service(name: serviceName, type: _, domain: _, interface: _)=service.endpoint else {return nil}
		guard let nameData=Data.dataFromUrlSafeBase64(serviceName) else {return nil}
		guard nameData.count>=10 else {return nil}
		let pcp=nameData[0]
		guard pcp==0x23 else {return nil}
		let endpointID=String(data: nameData.subdata(in: 1..<5), encoding: .ascii)!
		let serviceIDHash=nameData.subdata(in: 5..<8)
		guard serviceIDHash==Data([0xFC, 0x9F, 0x5E]) else {return nil}
		return endpointID
	}
	
	private func maybeAddFoundDevice(service:NWBrowser.Result){
		#if DEBUG
		print("found service \(service)")
		#endif
		for interface in service.interfaces{
			if case .loopback=interface.type{
				#if DEBUG
				print("ignoring localhost service")
				#endif
				return
			}
		}
		guard let endpointID=endpointID(for: service) else {return}
		#if DEBUG
		print("service name is valid, endpoint ID \(endpointID)")
		#endif
		var foundService=FoundServiceInfo(service: service)
		
		guard case let NWBrowser.Result.Metadata.bonjour(txtRecord)=service.metadata else {return}
		guard let endpointInfoEncoded=txtRecord.dictionary["n"] else {return}
		guard let endpointInfo=Data.dataFromUrlSafeBase64(endpointInfoEncoded) else {return}
		guard endpointInfo.count>=19 else {return}
		let deviceType=RemoteDeviceInfo.DeviceType.fromRawValue(value: (Int(endpointInfo[0]) >> 1) & 7)
		let deviceNameLength=Int(endpointInfo[17])
		guard endpointInfo.count>=deviceNameLength+17 else {return}
		guard let deviceName=String(data: endpointInfo.subdata(in: 18..<(18+deviceNameLength)), encoding: .utf8) else {return}
		
		let deviceInfo=RemoteDeviceInfo(name: deviceName, type: deviceType, id: endpointID)
		foundService.device=deviceInfo
		foundServices[endpointID]=foundService
		for delegate in shareExtensionDelegates{
			delegate.addDevice(device: deviceInfo)
		}
	}
	
	private func maybeRemoveFoundDevice(service:NWBrowser.Result){
		guard let endpointID=endpointID(for: service) else {return}
		guard let _=foundServices.removeValue(forKey: endpointID) else {return}
		for delegate in shareExtensionDelegates {
			delegate.removeDevice(id: endpointID)
		}
	}
	
	public func startOutgoingTransfer(deviceID:String, delegate:ShareExtensionDelegate, urls:[URL]){
		guard let info=foundServices[deviceID] else {return}
		let tcp=NWProtocolTCP.Options.init()
		tcp.noDelay=true
		let nwconn=NWConnection(to: info.service.endpoint, using: NWParameters(tls: .none, tcp: tcp))
		let conn=OutboundNearbyConnection(connection: nwconn, id: deviceID, urlsToSend: urls)
		conn.delegate=self
		let transfer=OutgoingTransferInfo(service: info.service, device: info.device!, connection: conn, delegate: delegate)
		outgoingTransfers[deviceID]=transfer
		conn.start()
	}
	
	func outboundConnectionWasEstablished(connection: OutboundNearbyConnection) {
		guard let transfer=outgoingTransfers[connection.id] else {return}
		DispatchQueue.main.async {
			transfer.delegate.connectionWasEstablished(pinCode: connection.pinCode!)
		}
	}
	
	func outboundConnectionTransferAccepted(connection: OutboundNearbyConnection) {
		guard let transfer=outgoingTransfers[connection.id] else {return}
		DispatchQueue.main.async {
			transfer.delegate.transferAccepted()
		}
	}
	
	func outboundConnection(connection: OutboundNearbyConnection, transferProgress: Double) {
		guard let transfer=outgoingTransfers[connection.id] else {return}
		DispatchQueue.main.async {
			transfer.delegate.transferProgress(progress: transferProgress)
		}
	}
	
	func outboundConnection(connection: OutboundNearbyConnection, failedWithError: Error) {
		guard let transfer=outgoingTransfers[connection.id] else {return}
		DispatchQueue.main.async {
			transfer.delegate.connectionFailed(with: failedWithError)
		}
		outgoingTransfers.removeValue(forKey: connection.id)
	}
	
	func outboundConnectionTransferFinished(connection: OutboundNearbyConnection) {
		guard let transfer=outgoingTransfers[connection.id] else {return}
		DispatchQueue.main.async {
			transfer.delegate.transferFinished()
		}
		outgoingTransfers.removeValue(forKey: connection.id)
	}
}

