//
//  SleepManager.swift
//  NearbyShare
//
//  Created by Mika on 15.10.23.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

class SleepManager{
	public static let shared=SleepManager()
	private var assertionID: IOPMAssertionID=0

	public func disableSleep(){
		if(assertionID != 0){
			return
		}

		IOPMAssertionCreateWithName(
			kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
			IOPMAssertionLevel(kIOPMAssertionLevelOn),
			"Data transfer over NearDrop" as CFString,
			&assertionID
		)
	}

	public func enableSleep(){
		if(assertionID == 0 || NearbyConnectionManager.shared.getActiveConnectionsCount() != 0){
			return
		}

		IOPMAssertionRelease(assertionID)
		assertionID = 0
	}

	private init(){}
}
