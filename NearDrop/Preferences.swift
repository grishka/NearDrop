//
//  Preferences.swift
//  NearDrop
//
//  Created by Ikroop Singh Kalsi on 10/05/23.
//

enum Preferences {
	@UserDefault(key: "openLinks", defaultValue: true)
	static var openLinksInBrowser: Bool
	
	@UserDefault(key: "copyWithoutConsent", defaultValue: true)
	static var copyToClipboardWithoutConsent: Bool
}
