**NearDrop** is a partial implementation of [Google's Nearby Share](https://blog.google/products/android/nearby-share/) for macOS.

[Protocol documentation](/PROTOCOL.md) is available separately.

The app lives in your menu bar and saves files to your downloads folder. It's that simple, really.

## Limitations

* **Receive only**. For now. I haven't yet figured out how to make Android turn on the MDNS service and/or show the "a device nearby is sharing" notification.
* **Wi-Fi LAN only**. Your Android device and your Mac need to be on the same network for this app to work. Google's implementation supports multiple mediums, including Wi-Fi Direct, Wi-Fi hotspot, Bluetooth, some kind of 5G peer-to-peer connection, and even a WebRTC-based protocol that goes over the internet through Google servers. Wi-Fi direct isn't supported on macOS (Apple has their own, incompatible, AWDL thing, used in AirDrop). Bluetooth needs further reverse engineering.
* **Visible to everyone on your network at all times** while the app is running. Limited visibility (contacts etc) requires talking to Google servers, and becoming temporarily visible requires listening for whatever triggers the "device nearby is sharing" notification.

## Installation

Download the latest build from the releases section, unzip, move to your applications folder. When running for the first time, right-click the app and select "Open", then confirm running an app from unidentified developer.

If you want the app to start on boot, add it manually to login objects in System Preferences.

## FAQ

#### Why is the app not notarized?

Because I don't want to pay Apple $99 a year for the privilege of developing macOS apps and oppose their idea of security.

#### Why is this not on the app store?

Because I don't want to pay Apple $99 a year for the privilege of developing macOS apps. I also don't want to have to go through the review process.

#### Why not the other way around, i.e. AirDrop on Android?

While I am an Android developer, and I have looked into this, this is nigh-impossible. AirDrop uses [AWDL](https://stackoverflow.com/questions/19587701/what-is-awdl-apple-wireless-direct-link-and-how-does-it-work), Apple's own proprietary take on peer-to-peer Wi-Fi. This works on top of 802.11 itself, the low-level Wi-Fi protocol, and thus can not be implemented without messing around with the Wi-Fi adapter drivers and raw packets and all that. It might be possible on Android, but it would at the very least require root and possibly a custom kernel. There is [an open-source implementation of AWDL and AirDrop for Linux](https://owlink.org/code/).
