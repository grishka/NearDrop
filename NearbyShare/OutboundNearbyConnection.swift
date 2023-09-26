//
//  OutboundNearbyConnection.swift
//  NearbyShare
//
//  Created by Grishka on 23.09.2023.
//

import Foundation
import Network
import CryptoKit
import CommonCrypto
import System
import UniformTypeIdentifiers

import SwiftECC
import BigInt

class OutboundNearbyConnection:NearbyConnection{
	private var currentState:State = .initial
	private let urlsToSend:[URL]
	private var ukeyClientFinishMsgData:Data?
	private var queue:[OutgoingFileTransfer]=[]
	private var currentTransfer:OutgoingFileTransfer?
	public var delegate:OutboundNearbyConnectionDelegate?
	private var totalBytesToSend:Int64=0
	private var totalBytesSent:Int64=0
	private var cancelled:Bool=false
	private var textPayloadID:Int64=0
	
	enum State{
		case initial, sentUkeyClientInit, sentUkeyClientFinish, sentPairedKeyEncryption, sentPairedKeyResult, sentIntroduction, sendingFiles
	}
	
	init(connection: NWConnection, id: String, urlsToSend:[URL]){
		self.urlsToSend=urlsToSend
		super.init(connection: connection, id: id)
		if urlsToSend.count==1 && !urlsToSend[0].isFileURL{
			textPayloadID=Int64.random(in: Int64.min...Int64.max)
		}
	}
	
	deinit {
		if let transfer=currentTransfer, let handle=transfer.handle{
			try? handle.close()
		}
		for transfer in queue{
			if let handle=transfer.handle{
				try? handle.close()
			}
		}
	}
	
	public func cancel(){
		cancelled=true
		if encryptionDone{
			var cancel=Sharing_Nearby_Frame()
			cancel.version = .v1
			cancel.v1=Sharing_Nearby_V1Frame()
			cancel.v1.type = .cancel
			try? sendTransferSetupFrame(cancel)
		}
		try? sendDisconnectionAndDisconnect()
	}
	
	override func connectionReady() {
		super.connectionReady()
		do{
			try sendConnectionRequest()
			try sendUkey2ClientInit()
		}catch{
			lastError=error
			protocolError()
		}
	}
	
	override func isServer() -> Bool {
		return false
	}
	
	override func processReceivedFrame(frameData: Data) {
		do{
			#if DEBUG
			print("received \(frameData), state is \(currentState)")
			#endif
			switch currentState {
			case .initial:
				protocolError()
			case .sentUkeyClientInit:
				try processUkey2ServerInit(frame: try Securegcm_Ukey2Message(serializedData: frameData), raw: frameData)
			case .sentUkeyClientFinish:
				try processConnectionResponse(frame: try Location_Nearby_Connections_OfflineFrame(serializedData: frameData))
			default:
				let smsg=try Securemessage_SecureMessage(serializedData: frameData)
				try decryptAndProcessReceivedSecureMessage(smsg)
			}
		}catch{
			if case NearbyError.ukey2=error{
			}else if currentState == .sentUkeyClientInit{
				sendUkey2Alert(type: .badMessage)
			}
			lastError=error
			protocolError()
		}
	}
	
	override func processTransferSetupFrame(_ frame: Sharing_Nearby_Frame) throws {
		if frame.hasV1 && frame.v1.hasType, case .cancel = frame.v1.type {
			print("Transfer canceled")
			try sendDisconnectionAndDisconnect()
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .userCanceled))
			return
		}
		print(frame)
		switch currentState{
		case .sentPairedKeyEncryption:
			try processPairedKeyEncryption(frame: frame)
		case .sentPairedKeyResult:
			try processPairedKeyResult(frame: frame)
		case .sentIntroduction:
			try processConsent(frame: frame)
		case .sendingFiles:
			break
		default:
			assertionFailure("Unexpected state \(currentState)")
		}
	}
	
	override func protocolError() {
		super.protocolError()
		delegate?.outboundConnection(connection: self, failedWithError: lastError!)
	}
	
	private func sendConnectionRequest() throws {
		var frame=Location_Nearby_Connections_OfflineFrame()
		frame.version = .v1
		frame.v1=Location_Nearby_Connections_V1Frame()
		frame.v1.type = .connectionRequest
		frame.v1.connectionRequest=Location_Nearby_Connections_ConnectionRequestFrame()
		frame.v1.connectionRequest.endpointID=String(bytes: NearbyConnectionManager.shared.endpointID, encoding: .ascii)!
		frame.v1.connectionRequest.endpointName=Host.current().localizedName!
		let endpointInfo=EndpointInfo(name: Host.current().localizedName!, deviceType: .computer)
		frame.v1.connectionRequest.endpointInfo=endpointInfo.serialize()
		frame.v1.connectionRequest.mediums=[.wifiLan]
		sendFrameAsync(try frame.serializedData())
	}
	
	private func sendUkey2ClientInit() throws {
		let domain=Domain.instance(curve: .EC256r1)
		let (pubKey, privKey)=domain.makeKeyPair()
		publicKey=pubKey
		privateKey=privKey
		
		var finishFrame=Securegcm_Ukey2Message()
		finishFrame.messageType = .clientFinish
		var finish=Securegcm_Ukey2ClientFinished()
		var pkey=Securemessage_GenericPublicKey()
		pkey.type = .ecP256
		pkey.ecP256PublicKey=Securemessage_EcP256PublicKey()
		pkey.ecP256PublicKey.x=Data(pubKey.w.x.asSignedBytes())
		pkey.ecP256PublicKey.y=Data(pubKey.w.y.asSignedBytes())
		finish.publicKey=try pkey.serializedData()
		finishFrame.messageData=try finish.serializedData()
		ukeyClientFinishMsgData=try finishFrame.serializedData()
		
		var frame=Securegcm_Ukey2Message()
		frame.messageType = .clientInit
		
		var clientInit=Securegcm_Ukey2ClientInit()
		clientInit.version=1
		clientInit.random=Data.randomData(length: 32)
		clientInit.nextProtocol="AES_256_CBC-HMAC_SHA256"
		var sha=SHA512()
		sha.update(data: ukeyClientFinishMsgData!)
		var commitment=Securegcm_Ukey2ClientInit.CipherCommitment()
		commitment.commitment=Data(sha.finalize())
		commitment.handshakeCipher = .p256Sha512
		clientInit.cipherCommitments.append(commitment)
		frame.messageData=try clientInit.serializedData()
		
		ukeyClientInitMsgData=try frame.serializedData()
		sendFrameAsync(ukeyClientInitMsgData!)
		currentState = .sentUkeyClientInit
	}
	
	private func processUkey2ServerInit(frame:Securegcm_Ukey2Message, raw:Data) throws{
		ukeyServerInitMsgData=raw
		guard frame.messageType == .serverInit else{
			sendUkey2Alert(type: .badMessageType)
			throw NearbyError.ukey2
		}
		let serverInit=try Securegcm_Ukey2ServerInit(serializedData: frame.messageData)
		guard serverInit.version==1 else{
			sendUkey2Alert(type: .badVersion)
			throw NearbyError.ukey2
		}
		guard serverInit.random.count==32 else{
			sendUkey2Alert(type: .badRandom)
			throw NearbyError.ukey2
		}
		guard serverInit.handshakeCipher == .p256Sha512 else{
			sendUkey2Alert(type: .badHandshakeCipher)
			throw NearbyError.ukey2
		}
		
		let serverKey=try Securemessage_GenericPublicKey(serializedData: serverInit.publicKey)
		try finalizeKeyExchange(peerKey: serverKey)
		sendFrameAsync(ukeyClientFinishMsgData!)
		currentState = .sentUkeyClientFinish
		
		var resp=Location_Nearby_Connections_OfflineFrame()
		resp.version = .v1
		resp.v1=Location_Nearby_Connections_V1Frame()
		resp.v1.type = .connectionResponse
		resp.v1.connectionResponse=Location_Nearby_Connections_ConnectionResponseFrame()
		resp.v1.connectionResponse.response = .accept
		resp.v1.connectionResponse.status=0
		resp.v1.connectionResponse.osInfo=Location_Nearby_Connections_OsInfo()
		resp.v1.connectionResponse.osInfo.type = .apple
		sendFrameAsync(try resp.serializedData())
		
		encryptionDone=true
		delegate?.outboundConnectionWasEstablished(connection: self)
	}
	
	private func processConnectionResponse(frame:Location_Nearby_Connections_OfflineFrame) throws{
		#if DEBUG
		print("connection response: \(frame)")
		#endif
		guard frame.version == .v1 else {throw NearbyError.protocolError("Unexpected offline frame version \(frame.version)")}
		guard frame.v1.type == .connectionResponse else {throw NearbyError.protocolError("Unexpected frame type \(frame.v1.type)")}
		guard frame.v1.connectionResponse.response == .accept else {throw NearbyError.protocolError("Connection was rejected by recipient")}
		
		var pairedEncryption=Sharing_Nearby_Frame()
		pairedEncryption.version = .v1
		pairedEncryption.v1=Sharing_Nearby_V1Frame()
		pairedEncryption.v1.type = .pairedKeyEncryption
		pairedEncryption.v1.pairedKeyEncryption=Sharing_Nearby_PairedKeyEncryptionFrame()
		pairedEncryption.v1.pairedKeyEncryption.secretIDHash=Data.randomData(length: 6)
		pairedEncryption.v1.pairedKeyEncryption.signedData=Data.randomData(length: 72)
		try sendTransferSetupFrame(pairedEncryption)
		
		currentState = .sentPairedKeyEncryption
	}
	
	private func processPairedKeyEncryption(frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasPairedKeyEncryption else { throw NearbyError.requiredFieldMissing }
		var pairedResult=Sharing_Nearby_Frame()
		pairedResult.version = .v1
		pairedResult.v1=Sharing_Nearby_V1Frame()
		pairedResult.v1.type = .pairedKeyResult
		pairedResult.v1.pairedKeyResult=Sharing_Nearby_PairedKeyResultFrame()
		pairedResult.v1.pairedKeyResult.status = .unable
		try sendTransferSetupFrame(pairedResult)
		currentState = .sentPairedKeyResult
	}
	
	private func processPairedKeyResult(frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasPairedKeyResult else { throw NearbyError.requiredFieldMissing }
		
		var introduction=Sharing_Nearby_Frame()
		introduction.version = .v1
		introduction.v1.type = .introduction
		if urlsToSend.count==1 && !urlsToSend[0].isFileURL{
			var meta=Sharing_Nearby_TextMetadata()
			meta.type = .url
			meta.textTitle=urlsToSend[0].host ?? "URL"
			meta.size=Int64(urlsToSend[0].absoluteString.utf8.count)
			meta.payloadID=textPayloadID
			introduction.v1.introduction.textMetadata.append(meta)
		}else{
			for url in urlsToSend{
				guard url.isFileURL else {continue}
				var meta=Sharing_Nearby_FileMetadata()
				meta.name=OutboundNearbyConnection.sanitizeFileName(name: url.lastPathComponent)
				let attrs=try FileManager.default.attributesOfItem(atPath: url.path)
				meta.size=(attrs[FileAttributeKey.size] as! NSNumber).int64Value
				let typeID=try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
				meta.mimeType="application/octet-stream"
				if let typeID=typeID{
					let type=UTType(typeID)
					if let type=type, let mimeType=type.preferredMIMEType{
						meta.mimeType=mimeType
					}
				}
				if meta.mimeType.starts(with: "image/"){
					meta.type = .image
				}else if meta.mimeType.starts(with: "video/"){
					meta.type = .video
				}else if(meta.mimeType.starts(with: "audio/")){
					meta.type = .audio
				}else if(url.pathExtension.lowercased()=="apk"){
					meta.type = .app
				}else{
					meta.type = .unknown
				}
				meta.payloadID=Int64.random(in: Int64.min...Int64.max)
				queue.append(OutgoingFileTransfer(url: url, payloadID: meta.payloadID, handle: try FileHandle(forReadingFrom: url), totalBytes: meta.size, currentOffset: 0))
				introduction.v1.introduction.fileMetadata.append(meta)
				totalBytesToSend+=meta.size
			}
		}
		#if DEBUG
		print("sent introduction: \(introduction)")
		#endif
		try sendTransferSetupFrame(introduction)
		
		currentState = .sentIntroduction
	}
	
	private func processConsent(frame:Sharing_Nearby_Frame) throws{
		guard frame.version == .v1, frame.v1.type == .response else {throw NearbyError.requiredFieldMissing}
		switch frame.v1.connectionResponse.status{
		case .accept:
			currentState = .sendingFiles
			delegate?.outboundConnectionTransferAccepted(connection: self)
			if urlsToSend.count==1 && !urlsToSend[0].isFileURL{
				try sendURL()
			}else{
				try sendNextFileChunk()
			}
		case .reject, .unknown:
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .userRejected))
			try sendDisconnectionAndDisconnect()
		case .notEnoughSpace:
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .notEnoughSpace))
			try sendDisconnectionAndDisconnect()
		case .timedOut:
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .timedOut))
			try sendDisconnectionAndDisconnect()
		case .unsupportedAttachmentType:
			delegate?.outboundConnection(connection: self, failedWithError: NearbyError.canceled(reason: .unsupportedType))
			try sendDisconnectionAndDisconnect()
		}
	}
	
	private func sendURL() throws{
		try sendBytesPayload(data: Data(urlsToSend[0].absoluteString.utf8), id: textPayloadID)
		delegate?.outboundConnectionTransferFinished(connection: self)
		try sendDisconnectionAndDisconnect()
	}
	
	private func sendNextFileChunk() throws{
		if cancelled{
			return
		}
		if currentTransfer==nil || currentTransfer?.currentOffset==currentTransfer?.totalBytes{
			if currentTransfer != nil && currentTransfer?.handle != nil{
				try currentTransfer?.handle?.close()
			}
			if queue.isEmpty{
				#if DEBUG
				print("Disconnecting because all files have been transferred")
				#endif
				try sendDisconnectionAndDisconnect()
				delegate?.outboundConnectionTransferFinished(connection: self)
				return
			}
			currentTransfer=queue.removeFirst()
		}
		
		guard let fileBuffer=try currentTransfer!.handle!.read(upToCount: 512*1024) else{
			throw NearbyError.inputOutput(cause: Errno.ioError)
		}
		
		var transfer=Location_Nearby_Connections_PayloadTransferFrame()
		transfer.packetType = .data
		transfer.payloadChunk.offset=currentTransfer!.currentOffset
		transfer.payloadChunk.flags=0
		transfer.payloadChunk.body=fileBuffer
		transfer.payloadHeader.id=currentTransfer!.payloadID
		transfer.payloadHeader.type = .file
		transfer.payloadHeader.totalSize=Int64(currentTransfer!.totalBytes)
		transfer.payloadHeader.isSensitive=false
		currentTransfer!.currentOffset+=Int64(fileBuffer.count)
		
		var wrapper=Location_Nearby_Connections_OfflineFrame()
		wrapper.version = .v1
		wrapper.v1=Location_Nearby_Connections_V1Frame()
		wrapper.v1.type = .payloadTransfer
		wrapper.v1.payloadTransfer=transfer
		try encryptAndSendOfflineFrame(wrapper, completion: {
			do{
				try self.sendNextFileChunk()
			}catch{
				self.lastError=error
				self.protocolError()
			}
		})
		#if DEBUG
		print("sent file chunk, current transfer: \(String(describing: currentTransfer))")
		#endif
		totalBytesSent+=Int64(fileBuffer.count)
		delegate?.outboundConnection(connection: self, transferProgress: Double(totalBytesSent)/Double(totalBytesToSend))
		
		if currentTransfer!.currentOffset==currentTransfer!.totalBytes{
			// Signal end of file (yes, all this for one bit)
			var transfer=Location_Nearby_Connections_PayloadTransferFrame()
			transfer.packetType = .data
			transfer.payloadChunk.offset=currentTransfer!.currentOffset
			transfer.payloadChunk.flags=1 // <- this one here
			transfer.payloadHeader.id=currentTransfer!.payloadID
			transfer.payloadHeader.type = .file
			transfer.payloadHeader.totalSize=Int64(currentTransfer!.totalBytes)
			transfer.payloadHeader.isSensitive=false
			
			var wrapper=Location_Nearby_Connections_OfflineFrame()
			wrapper.version = .v1
			wrapper.v1=Location_Nearby_Connections_V1Frame()
			wrapper.v1.type = .payloadTransfer
			wrapper.v1.payloadTransfer=transfer
			try encryptAndSendOfflineFrame(wrapper)
			#if DEBUG
			print("sent EOF, current transfer: \(String(describing: currentTransfer))")
			#endif
		}
	}
	
	private static func sanitizeFileName(name:String)->String{
		return name.replacingOccurrences(of: "[\\/\\\\?%\\*:\\|\"<>=]", with: "_", options: .regularExpression)
	}
}

fileprivate struct OutgoingFileTransfer{
	let url:URL
	let payloadID:Int64
	let handle:FileHandle?
	let totalBytes:Int64
	var currentOffset:Int64
}

protocol OutboundNearbyConnectionDelegate{
	func outboundConnectionWasEstablished(connection:OutboundNearbyConnection)
	func outboundConnection(connection:OutboundNearbyConnection, transferProgress:Double)
	func outboundConnectionTransferAccepted(connection:OutboundNearbyConnection)
	func outboundConnection(connection:OutboundNearbyConnection, failedWithError:Error)
	func outboundConnectionTransferFinished(connection:OutboundNearbyConnection)
}
