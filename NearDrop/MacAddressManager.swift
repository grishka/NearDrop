import Foundation

class MacAddressManager {
    
    var interval: TimeInterval = 30 // seconds
    
    var addresses: [String : String] = [:] // IP : MAC
    
    private var timer: Timer? = nil
    private let updateQueue = DispatchQueue(label: "arpUpdateQueue")
    
    static let shared = MacAddressManager()
    
    func startUpdating() {
        self.stopUpdating()
        self.update()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: { timer in
            self.update()
        })
    }
    
    func stopUpdating() {
        timer?.invalidate()
        timer = nil
    }
    
    func update() {
        self.updateQueue.async {
            let task = Process()
            task.launchPath = "/usr/sbin/arp"
            task.arguments = ["-a"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.launch()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    let components = line.components(separatedBy: " ")
                    if components.count >= 4 {
                        let ip = components[1]
                        let mac = components[3]
                        if ip != "(incomplete)" && mac != "(incomplete)" {
                            let stripped = ip.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                            self.addresses[stripped] = mac
                        }
                    }
                }
            }
            print(self.addresses)
        }
    }
    
}
