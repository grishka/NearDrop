//
//  NearbyConnection.swift
//  NearDrop
//
//  Created by Grishka on 09.04.2023.
//

import Foundation
import Network
import CommonCrypto
import CryptoKit
import System

import SwiftECC
import BigInt

class NearbyConnection{
	internal static let SANE_FRAME_LENGTH=5*1024*1024
	private static let dispatchQueue=DispatchQueue(label: "me.grishka.NearDrop.queue", qos: .utility) // FIFO (non-concurrent) queue to avoid those exciting concurrency bugs
	
	internal let connection:NWConnection
	internal var remoteDeviceInfo:RemoteDeviceInfo?
	private var payloadBuffers:[Int64:NSMutableData]=[:]
	internal var encryptionDone:Bool=false
	internal var transferredFiles:[Int64:InternalFileInfo]=[:]
	public let id:String
	internal var lastError:Error?
	private var connectionClosed:Bool=false
	
	// UKEY2-related state
	internal var publicKey:ECPublicKey?
	internal var privateKey:ECPrivateKey?
	internal var ukeyClientInitMsgData:Data?
	internal var ukeyServerInitMsgData:Data?
	
	// SecureMessage encryption keys
	internal var decryptKey:[UInt8]?
	internal var encryptKey:[UInt8]?
	internal var recvHmacKey:SymmetricKey?
	internal var sendHmacKey:SymmetricKey?
	
	// SecureMessage sequence numbers
	private var serverSeq:Int32=0
	private var clientSeq:Int32=0
	
	private(set) var pinCode:String?
	
	init(connection:NWConnection, id:String) {
		self.connection=connection
		self.id=id
	}
	
	func start(){
		connection.stateUpdateHandler={state in
			if case .ready = state {
				self.connectionReady()
				self.receiveFrameAsync()
				SleepManager.shared.disableSleep()
			} else if case .failed(let err) = state {
				self.lastError=err
				print("Error opening socket: \(err)")
				self.handleConnectionClosure()
				SleepManager.shared.enableSleep()
			}
		}
		//connection.start(queue: .global(qos: .utility))
		connection.start(queue: NearbyConnection.dispatchQueue)
	}
	
	func connectionReady(){}
	
	internal func handleConnectionClosure(){
		print("Connection closed")
	}
	
	internal func protocolError(){
		disconnect()
	}
	
	internal func processReceivedFrame(frameData:Data){
		fatalError()
	}
	
	internal func processTransferSetupFrame(_ frame:Sharing_Nearby_Frame) throws{
		fatalError()
	}
	
	internal func isServer() -> Bool{
		fatalError()
	}
	
	internal func processFileChunk(frame:Location_Nearby_Connections_PayloadTransferFrame) throws{
		protocolError()
	}
	
	internal func processBytesPayload(payload:Data, id:Int64)throws ->Bool{
		return false
	}
	
	private func receiveFrameAsync(){
		connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { content, contentContext, isComplete, error in
			if self.connectionClosed{
				return
			}
			if isComplete{
				self.handleConnectionClosure()
				return
			}
			if !(error==nil){
				self.lastError=error
				self.protocolError()
				return
			}
			guard let content=content else {
				assertionFailure()
				return
			}
			let frameLength:UInt32=UInt32(content[0]) << 24 | UInt32(content[1]) << 16 | UInt32(content[2]) << 8 | UInt32(content[3])
			guard frameLength<NearbyConnection.SANE_FRAME_LENGTH else {
				self.lastError=NearbyError.protocolError("Unexpected packet length")
				self.protocolError()
				return
			}
			self.receiveFrameAsync(length: frameLength)
		}
	}
	
	private func receiveFrameAsync(length:UInt32){
		connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { content, contentContext, isComplete, error in
			if self.connectionClosed{
				return
			}
			if isComplete{
				self.handleConnectionClosure()
				return
			}
			guard let content=content else {
				self.protocolError()
				return
			}
			self.processReceivedFrame(frameData: content)
			self.receiveFrameAsync()
		}
	}
	
	internal func sendFrameAsync(_ frame:Data, completion:(()->Void)?=nil){
		if connectionClosed{
			return
		}
		var lengthPrefixedData=Data(capacity: frame.count+4)
		let length:Int=frame.count
		lengthPrefixedData.append(contentsOf: [
			UInt8(truncatingIfNeeded: length >> 24),
			UInt8(truncatingIfNeeded: length >> 16),
			UInt8(truncatingIfNeeded: length >> 8),
			UInt8(truncatingIfNeeded: length)
		])
		lengthPrefixedData.append(frame)
		connection.send(content: lengthPrefixedData, completion: .contentProcessed({ error in
			if let completion=completion{
				completion()
			}
		}))
	}
	
	internal func encryptAndSendOfflineFrame(_ frame:Location_Nearby_Connections_OfflineFrame, completion:(()->Void)?=nil) throws{
		var d2dMsg=Securegcm_DeviceToDeviceMessage()
		serverSeq+=1
		d2dMsg.sequenceNumber=serverSeq
		d2dMsg.message=try frame.serializedData()
		
		let serializedMsg=[UInt8](try d2dMsg.serializedData())
		let iv=Data.randomData(length: 16)
		var encryptedData=Data(count: serializedMsg.count+16)
		var encryptedLength:size_t=0
		encryptedData.withUnsafeMutableBytes({
			let status=CCCrypt(
				CCOperation(kCCEncrypt),
				CCAlgorithm(kCCAlgorithmAES128),
				CCOptions(kCCOptionPKCS7Padding),
				encryptKey, kCCKeySizeAES256,
				[UInt8](iv),
				serializedMsg, serializedMsg.count,
				$0.baseAddress, $0.count,
				&encryptedLength
			)
			guard status==kCCSuccess else { fatalError("CCCrypt error: \(status)") }
		})
		
		var hb=Securemessage_HeaderAndBody()
		hb.body=encryptedData.prefix(encryptedLength)
		hb.header=Securemessage_Header()
		hb.header.encryptionScheme = .aes256Cbc
		hb.header.signatureScheme = .hmacSha256
		hb.header.iv=iv
		var md=Securegcm_GcmMetadata()
		md.type = .deviceToDeviceMessage
		md.version=1
		hb.header.publicMetadata=try md.serializedData()
		
		var smsg=Securemessage_SecureMessage()
		smsg.headerAndBody=try hb.serializedData()
		smsg.signature=Data(HMAC<SHA256>.authenticationCode(for: smsg.headerAndBody, using: sendHmacKey!))
		sendFrameAsync(try smsg.serializedData(), completion: completion)
	}
	
	internal func sendTransferSetupFrame(_ frame:Sharing_Nearby_Frame) throws{
		try sendBytesPayload(data: try frame.serializedData(), id: Int64.random(in: Int64.min...Int64.max))
	}
	
	internal func sendBytesPayload(data:Data, id:Int64) throws{
		var transfer=Location_Nearby_Connections_PayloadTransferFrame()
		transfer.packetType = .data
		transfer.payloadChunk.offset=0
		transfer.payloadChunk.flags=0
		transfer.payloadChunk.body=data
		transfer.payloadHeader.id=id
		transfer.payloadHeader.type = .bytes
		transfer.payloadHeader.totalSize=Int64(transfer.payloadChunk.body.count)
		transfer.payloadHeader.isSensitive=false
		
		var wrapper=Location_Nearby_Connections_OfflineFrame()
		wrapper.version = .v1
		wrapper.v1=Location_Nearby_Connections_V1Frame()
		wrapper.v1.type = .payloadTransfer
		wrapper.v1.payloadTransfer=transfer
		try encryptAndSendOfflineFrame(wrapper)
		
		transfer.payloadChunk.flags=1 // .lastChunk
		transfer.payloadChunk.offset=Int64(transfer.payloadChunk.body.count)
		transfer.payloadChunk.clearBody()
		wrapper.v1.payloadTransfer=transfer
		try encryptAndSendOfflineFrame(wrapper)
	}
	
	internal func decryptAndProcessReceivedSecureMessage(_ smsg:Securemessage_SecureMessage) throws{
		guard smsg.hasSignature, smsg.hasHeaderAndBody else { throw NearbyError.requiredFieldMissing("secureMessage.signature|headerAndBody") }
		let hmac=Data(HMAC<SHA256>.authenticationCode(for: smsg.headerAndBody, using: recvHmacKey!))
		guard hmac==smsg.signature else { throw NearbyError.protocolError("hmac!=signature") }
		let headerAndBody=try Securemessage_HeaderAndBody(serializedData: smsg.headerAndBody)
		var decryptedData=Data(count: headerAndBody.body.count)
		
		var decryptedLength:Int=0
		decryptedData.withUnsafeMutableBytes({
			let status=CCCrypt(
				CCOperation(kCCDecrypt),
				CCAlgorithm(kCCAlgorithmAES128),
				CCOptions(kCCOptionPKCS7Padding),
				decryptKey, kCCKeySizeAES256,
				[UInt8](headerAndBody.header.iv),
				[UInt8](headerAndBody.body), headerAndBody.body.count,
				$0.baseAddress, $0.count,
				&decryptedLength
			)
			guard status==kCCSuccess else { fatalError("CCCrypt error: \(status)") }
		})
		decryptedData=decryptedData.prefix(decryptedLength)
		let d2dMsg=try Securegcm_DeviceToDeviceMessage(serializedData: decryptedData)
		guard d2dMsg.hasMessage, d2dMsg.hasSequenceNumber else { throw NearbyError.requiredFieldMissing("d2dMessage.message|sequenceNumber") }
		clientSeq+=1
		guard d2dMsg.sequenceNumber==clientSeq else { throw NearbyError.protocolError("Wrong sequence number. Expected \(clientSeq), got \(d2dMsg.sequenceNumber)") }
		let offlineFrame=try Location_Nearby_Connections_OfflineFrame(serializedData: d2dMsg.message)
		
		if offlineFrame.hasV1 && offlineFrame.v1.hasType, case .payloadTransfer = offlineFrame.v1.type {
			guard offlineFrame.v1.hasPayloadTransfer else { throw NearbyError.requiredFieldMissing("offlineFrame.v1.payloadTransfer") }
			let payloadTransfer=offlineFrame.v1.payloadTransfer
			let header=payloadTransfer.payloadHeader;
			let chunk=payloadTransfer.payloadChunk;
			guard header.hasType, header.hasID else { throw NearbyError.requiredFieldMissing("payloadHeader.type|id") }
			guard payloadTransfer.hasPayloadChunk, chunk.hasOffset, chunk.hasFlags else { throw NearbyError.requiredFieldMissing("payloadTransfer.payloadChunk|offset|flags") }
			if case .bytes = header.type{
				let payloadID=header.id
				if header.totalSize>InboundNearbyConnection.SANE_FRAME_LENGTH{
					payloadBuffers.removeValue(forKey: payloadID)
					throw NearbyError.protocolError("Payload too large (\(header.totalSize) bytes)")
				}
				if payloadBuffers[payloadID]==nil {
					payloadBuffers[payloadID]=NSMutableData(capacity: Int(header.totalSize))
				}
				let buffer=payloadBuffers[payloadID]!
				guard chunk.offset==buffer.count else {
					payloadBuffers.removeValue(forKey: payloadID)
					throw NearbyError.protocolError("Unexpected chunk offset \(chunk.offset), expected \(buffer.count)")
				}
				if chunk.hasBody {
					buffer.append(chunk.body)
				}
				if (chunk.flags & 1)==1 {
					payloadBuffers.removeValue(forKey: payloadID)
					if !(try processBytesPayload(payload: Data(buffer), id: payloadID)){
						let innerFrame=try Sharing_Nearby_Frame(serializedData: buffer as Data)
						try processTransferSetupFrame(innerFrame)
					}
				}
			}else if case .file = header.type{
				try processFileChunk(frame: payloadTransfer)
			}
		}else if offlineFrame.hasV1 && offlineFrame.v1.hasType, case .keepAlive = offlineFrame.v1.type{
			#if DEBUG
			print("Sent keep-alive")
			#endif
			sendKeepAlive(ack: true)
		}else{
			print("Unhandled offline frame encrypted: \(offlineFrame)")
		}
	}
	
	internal static func pinCodeFromAuthKey(_ key:SymmetricKey) -> String{
		var hash:Int=0
		var multiplier:Int=1
		let keyBytes:[UInt8]=key.withUnsafeBytes({
			return [UInt8]($0)
		})
		
		for _byte in keyBytes {
			let byte=Int(Int8(bitPattern: _byte))
			hash=(hash+byte*multiplier)%9973
			multiplier=(multiplier*31)%9973
		}
		
		return String(format: "%04d", abs(hash))
	}
	
	internal static func hkdfExtract(salt:Data, ikm:Data) -> Data{
		return HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt)).withUnsafeBytes({return Data(bytes: $0.baseAddress!, count: $0.count)})
	}
	
	internal static func hkdfExpand(prk:Data, info:Data, length:Int) -> Data{
		var okm=Data()
		var t=Data()
		var i=0
		while okm.count<length{
			i=i+1
			let toDigest=t+info+Data([UInt8(truncatingIfNeeded: i)])
			t=HMAC<SHA256>.authenticationCode(for: toDigest, using: SymmetricKey(data: prk)).withUnsafeBytes({return Data(bytes: $0.baseAddress!, count: $0.count)})
			okm=okm+t
		}
		return okm.subdata(in: 0..<length)
	}
	
	internal static func hkdf(inputKeyMaterial:SymmetricKey, salt:Data, info:Data, outputByteCount:Int) -> SymmetricKey{
		if #available(macOS 11.0, *){
			return HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKeyMaterial, salt: salt, info: info, outputByteCount: outputByteCount)
		}else{
			return SymmetricKey(data: hkdfExpand(prk: hkdfExtract(salt: salt, ikm: inputKeyMaterial.withUnsafeBytes({return Data(bytes: $0.baseAddress!, count: $0.count)})), info: info, length: outputByteCount))
		}
	}
	
	internal func finalizeKeyExchange(peerKey:Securemessage_GenericPublicKey) throws{
		guard peerKey.hasEcP256PublicKey else { throw NearbyError.requiredFieldMissing("peerKey.ecP256PublicKey") }
		
		let domain=Domain.instance(curve: .EC256r1)
		var clientX=peerKey.ecP256PublicKey.x
		var clientY=peerKey.ecP256PublicKey.y
		if clientX.count>32{
			clientX=clientX.suffix(32)
		}
		if clientY.count>32{
			clientY=clientY.suffix(32)
		}
		let key=try ECPublicKey(domain: domain, w: Point(BInt(magnitude: [UInt8](clientX)), BInt(magnitude: [UInt8](clientY))))
		
		let dhs=(try privateKey?.domain.multiplyPoint(key.w, privateKey!.s).x.asMagnitudeBytes())!
		var sha=SHA256()
		sha.update(data: dhs)
		let derivedSecretKey=Data(sha.finalize())
		
		var ukeyInfo=Data()
		ukeyInfo.append(ukeyClientInitMsgData!)
		ukeyInfo.append(ukeyServerInitMsgData!)
		let authString=NearbyConnection.hkdf(inputKeyMaterial: SymmetricKey(data: derivedSecretKey), salt: "UKEY2 v1 auth".data(using: .utf8)!, info: ukeyInfo, outputByteCount: 32)
		let nextSecret=NearbyConnection.hkdf(inputKeyMaterial: SymmetricKey(data: derivedSecretKey), salt: "UKEY2 v1 next".data(using: .utf8)!, info: ukeyInfo, outputByteCount: 32)
		
		pinCode=NearbyConnection.pinCodeFromAuthKey(authString)
		
		let salt:Data=Data([0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83, 0x46, 0xCA, 0x1C,
							0xEE, 0x8D, 0x39, 0x09, 0xB9, 0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D,
							0x4A, 0xB3, 0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10])
		
		let d2dClientKey=NearbyConnection.hkdf(inputKeyMaterial: nextSecret, salt: salt, info: "client".data(using: .utf8)!, outputByteCount: 32)
		let d2dServerKey=NearbyConnection.hkdf(inputKeyMaterial: nextSecret, salt: salt, info: "server".data(using: .utf8)!, outputByteCount: 32)
		
		sha=SHA256()
		sha.update(data: "SecureMessage".data(using: .utf8)!)
		let smsgSalt=Data(sha.finalize())
		
		let clientKey=NearbyConnection.hkdf(inputKeyMaterial: d2dClientKey, salt: smsgSalt, info: "ENC:2".data(using: .utf8)!, outputByteCount: 32).withUnsafeBytes({return [UInt8]($0)})
		let clientHmacKey=NearbyConnection.hkdf(inputKeyMaterial: d2dClientKey, salt: smsgSalt, info: "SIG:1".data(using: .utf8)!, outputByteCount: 32)
		let serverKey=NearbyConnection.hkdf(inputKeyMaterial: d2dServerKey, salt: smsgSalt, info: "ENC:2".data(using: .utf8)!, outputByteCount: 32).withUnsafeBytes({return [UInt8]($0)})
		let serverHmacKey=NearbyConnection.hkdf(inputKeyMaterial: d2dServerKey, salt: smsgSalt, info: "SIG:1".data(using: .utf8)!, outputByteCount: 32)
		
		if isServer(){
			decryptKey=clientKey
			recvHmacKey=clientHmacKey
			encryptKey=serverKey
			sendHmacKey=serverHmacKey
		}else{
			decryptKey=serverKey
			recvHmacKey=serverHmacKey
			encryptKey=clientKey
			sendHmacKey=clientHmacKey
		}
	}
	
	internal func disconnect(){
		connection.send(content: nil, isComplete: true, completion: .contentProcessed({ error in
			self.handleConnectionClosure()
		}))
		connectionClosed=true
	}
	
	internal func sendDisconnectionAndDisconnect() throws{
		var offlineFrame=Location_Nearby_Connections_OfflineFrame()
		offlineFrame.version = .v1
		offlineFrame.v1.type = .disconnection
		offlineFrame.v1.disconnection=Location_Nearby_Connections_DisconnectionFrame()
		
		if encryptionDone{
			try encryptAndSendOfflineFrame(offlineFrame)
		}else{
			sendFrameAsync(try offlineFrame.serializedData())
		}
		disconnect()
	}
	
	internal func sendUkey2Alert(type:Securegcm_Ukey2Alert.AlertType){
		var alert=Securegcm_Ukey2Alert()
		alert.type=type
		var msg=Securegcm_Ukey2Message()
		msg.messageType = .alert
		msg.messageData = try! alert.serializedData()
		sendFrameAsync(try! msg.serializedData())
		disconnect()
	}
	
	internal func sendKeepAlive(ack:Bool){
		var offlineFrame=Location_Nearby_Connections_OfflineFrame()
		offlineFrame.version = .v1
		offlineFrame.v1.type = .keepAlive
		offlineFrame.v1.keepAlive.ack=ack
		
		do{
			if encryptionDone{
				try encryptAndSendOfflineFrame(offlineFrame)
			}else{
				sendFrameAsync(try offlineFrame.serializedData())
			}
		}catch{
			print("Error sending KEEP_ALIVE: \(error)")
		}
	}
}

struct InternalFileInfo{
	let meta:FileMetadata
	let payloadID:Int64
	let destinationURL:URL
	var bytesTransferred:Int64=0
	var fileHandle:FileHandle?
	var progress:Progress?
	var created:Bool=false
}
