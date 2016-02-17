//
//  PinIOModuleManager.swift
//  Bluefruit Connect
//
//  Created by Antonio García on 16/02/16.
//  Copyright © 2016 Adafruit. All rights reserved.
//

import Foundation

protocol PinIOModuleManagerDelegate {
    func onPinIODidEndPinQuery(isDefaultConfigurationAssumed: Bool)
    func onPinIODidReceivePinState()
}

class PinIOModuleManager: NSObject {
    
    // Constants
    private let SYSEX_START: UInt8 = 0xF0
    private let SYSEX_END: UInt8 = 0xF7
    private let CAPABILITY_QUERY_TIMEOUT = 5.0
    
    private let DEFAULT_CELL_COUNT = 20
    private let LAST_DIGITAL_PIN = 8
    private let FIRST_ANALOG_PIN = 14
    
    
    private let DIGITAL_PIN_SECTION = 0
    private let ANALOG_PIN_SECTION = 1
    private let FIRST_DIGITAL_PIN = 3
    private let LAST_ANALOG_PIN = 19
    private let PORT_COUNT = 3
    
    // Types
    enum UartStatus {
        case SendData           // Default mode
        case QueryCapabilities
        case QueryAnalogMapping
    }
    
    class PinData {
        enum Mode: UInt8 {
            case Unknown = 255
            case Input = 0          // Don't chage the values (these are the bytes defined by firmata spec)
            case Output = 1
            
            case Analog = 2
            case PWM = 3
            case Servo = 4
        }
        
        enum DigitalValue: Int{
            case Low = 0
            case High = 1
        }
        
        var digitalPinId: Int = -1
        var analogPinId: Int = -1
        
        var isDigital: Bool
        var isAnalog: Bool
        var isPWM: Bool
        
        var mode = Mode.Input
        var digitalValue =  DigitalValue.Low
        var analogValue: Int = 0
        
        init(digitalPinId: Int, isDigital: Bool, isAnalog: Bool, isPWM: Bool) {
            self.digitalPinId = digitalPinId
            self.isDigital = isDigital
            self.isAnalog = isAnalog
            self.isPWM = isPWM
        }
    }

    // Data
    private var uartStatus = UartStatus.SendData
    private var queryCapabilitiesTimer : NSTimer?
    
    var pins = [PinData]()
    private var portMasks = [UInt8](count: 3, repeatedValue: 0)

    var delegate: PinIOModuleManagerDelegate?
    
    var digitalPinCount: Int {
        return pins.filter{$0.isDigital}.count
    }

    var analogPinCount: Int {
        return pins.filter{$0.isAnalog}.count
    }
 
    override init() {
        super.init()

    }
    
    deinit {
        cancelQueryCapabilitiesTimer()
    }

    func isQueryingCapabilities() -> Bool {
        return uartStatus != .SendData
    }
    
    
    func start() {
        let notificationCenter =  NSNotificationCenter.defaultCenter()
        notificationCenter.addObserver(self, selector: "didReceiveData:", name: UartManager.UartNotifications.DidReceiveData.rawValue, object: nil)
    }
    
    func stop() {
        let notificationCenter =  NSNotificationCenter.defaultCenter()
        notificationCenter.removeObserver(self, name: UartManager.UartNotifications.DidReceiveData.rawValue, object: nil)

        // Cancel pending queries
        cancelQueryCapabilitiesTimer()
        
    }

    // MARK: Notifications
    func didReceiveData(notification: NSNotification) {
        if let dataChunk = notification.userInfo?["dataChunk"] as? UartDataChunk {
            switch uartStatus {
            case .QueryCapabilities:
                receivedQueryCapabilities(dataChunk.data)
            case .QueryAnalogMapping:
                receivedAnalogMapping(dataChunk.data)
            default:
                receivedPinState(dataChunk.data)
                break
            }
        }
    }
    
    // MARK: - Query Capabilities
    func reset() {
        uartStatus == .SendData
        pins = []
        
        // Reset Firmata
        let bytes:[UInt8] = [0xff]
        let data = NSData(bytes: bytes, length: bytes.count)
        UartManager.sharedInstance.sendData(data)
    }
    
    private var queryCapabilitiesDataBuffer = [UInt8]()
    func queryCapabilities() {
        DLog("queryCapabilities")
        
        // Set status
        pins = []
        self.uartStatus = .QueryCapabilities
        self.queryCapabilitiesDataBuffer.removeAll()
        
        // Query Capabilities
        let bytes:[UInt8] = [self.SYSEX_START, 0x6B, self.SYSEX_END]
        let data = NSData(bytes: bytes, length: bytes.count)
        
        UartManager.sharedInstance.sendData(data)
        self.queryCapabilitiesTimer = NSTimer.scheduledTimerWithTimeInterval(self.CAPABILITY_QUERY_TIMEOUT, target: self, selector: "cancelQueryCapabilities", userInfo: nil, repeats: false)
    }
    
    private func receivedQueryCapabilities(data: NSData) {
        cancelQueryCapabilitiesTimer()

        // Read received packet
        var dataBytes = [UInt8](count: data.length, repeatedValue: 0)
        data.getBytes(&dataBytes, length: data.length)

        for byte in dataBytes {
            queryCapabilitiesDataBuffer.append(byte)
            if byte == SYSEX_END {
                DLog("Finished receiving Capabilities")
                queryAnalogMapping()
                break
            }
        }
    }
 
    private func cancelQueryCapabilitiesTimer() {
        queryCapabilitiesTimer?.invalidate()
        queryCapabilitiesTimer = nil
    }

    // MARK: - Query AnalogMapping
    private var queryAnalogMappingDataBuffer = [UInt8]()
    
    private func queryAnalogMapping() {
        DLog("queryAnalogMapping")
        
        // Set status
        self.uartStatus = .QueryAnalogMapping
        self.queryAnalogMappingDataBuffer.removeAll()
        
        // Query Analog Mapping
        let bytes:[UInt8] = [self.SYSEX_START, 0x69, self.SYSEX_END]
        let data = NSData(bytes: bytes, length: bytes.count)
        UartManager.sharedInstance.sendData(data)
    }
    
    private func receivedAnalogMapping(data: NSData) {
        // Read received packet
        var dataBytes = [UInt8](count: data.length, repeatedValue: 0)
        data.getBytes(&dataBytes, length: data.length)
        
        for byte in dataBytes {
            queryAnalogMappingDataBuffer.append(byte)
            if byte == SYSEX_END {
                DLog("Finished receiving Analog Mapping")
                endPinQuery(false)
                break
            }
        }
    }
    
    func endPinQuery(abortQuery: Bool) {
        
        cancelQueryCapabilitiesTimer()
        uartStatus = .SendData
        
        var isDefaultConfigurationAssumed: Bool
        if !abortQuery && queryCapabilitiesDataBuffer.count > 0 && queryAnalogMappingDataBuffer.count > 0 {
            parseCapabilities(queryCapabilitiesDataBuffer)
            parseAnalogMappingData(queryAnalogMappingDataBuffer)
            isDefaultConfigurationAssumed = false
        }
        else {
            initializeDefaultPins()
            isDefaultConfigurationAssumed = true
        }
        enableReadReports()
        
        // Clean received data
        queryCapabilitiesDataBuffer.removeAll()
        queryAnalogMappingDataBuffer.removeAll()
        
        // Refresh
        delegate?.onPinIODidEndPinQuery(isDefaultConfigurationAssumed)
    }
    
    private func parseCapabilities(cababilitiesData : [UInt8]) {
        // Separate pin data
        var pinsBytes = [[UInt8]]()
        var currentPin = [UInt8]()
        for i in 2..<cababilitiesData.count-1 {         // Skip 2 header bytes and end byte
            let dataByte = cababilitiesData[i]
            if dataByte != 0x7f {
                currentPin.append(dataByte)
            }
            else {  // Finished current pin
                pinsBytes.append(currentPin)
                currentPin = []
            }
        }
        
        // Extract pin info
        self.pins = []
        var pinNumber = 0
        for pinBytes in pinsBytes {
            var isInput = false, isOutput = false, isAnalog = false, isPWM = false
            
            if pinBytes.count > 0 {     // if is available
                var i = 0
                while i<pinBytes.count {
                    let byte = pinBytes[i]
                    switch byte {
                    case 0x00:
                        isInput = true
                        i++     // skip resolution byte
                    case 0x01:
                        isOutput = true
                        i++     // skip resolution byte
                    case 0x02:
                        isAnalog = true
                        i++     // skip resolution byte
                    case 0x03:
                        isPWM = true
                        i++     // skip resolution byte
                    case 0x04:
                        // Servo
                        i++ //skip resolution byte
                    case 0x06:
                        // I2C
                        i++     // skip resolution byte
                    default:
                        break
                    }
                    i++
                }
                
                let pinData = PinData(digitalPinId: pinNumber, isDigital: isInput && isOutput, isAnalog: isAnalog, isPWM: isPWM)
                self.pins.append(pinData)
            }
            
            pinNumber++
        }
    }
    
    private func parseAnalogMappingData(analogData : [UInt8]) {
        
        var pinNumber = 0
        for i in 2..<analogData.count-1 {         // Skip 2 header bytes and end byte
            let dataByte = analogData[i]
            if dataByte != 0x7f {
                if let indexOfPinNumber = indexOfPinWithDigitalId(pinNumber) {
                    pins[indexOfPinNumber].analogPinId = Int(dataByte)
                }
            }
            pinNumber++
        }
    }
    
    private func indexOfPinWithDigitalId(digitalPinId: Int) -> Int? {
        return pins.indexOf { (pin) -> Bool in
            pin.digitalPinId == digitalPinId
        }
    }
    
    private func indexOfPinWithAnalogId(analogPinId: Int) -> Int? {
        return pins.indexOf { (pin) -> Bool in
            pin.analogPinId == analogPinId
        }
    }
    
    // MARK: - Pin Management
    private func initializeDefaultPins() {
        pins.removeAll()
        
        for i in 0..<DEFAULT_CELL_COUNT {
            var pin: PinData!
            if ((i == 3) || (i == 5) || (i == 6)) {     // PWM pins
                pin = PinData(digitalPinId: i,isDigital: true, isAnalog: false, isPWM: false)
            }
            else if (i >= FIRST_DIGITAL_PIN && i <= LAST_DIGITAL_PIN) {    // Digital pin
                pin = PinData(digitalPinId: i, isDigital: true, isAnalog: false, isPWM: false)
            }
            else if (i >= FIRST_ANALOG_PIN && i <= LAST_ANALOG_PIN) {     // Analog pin
                pin = PinData(digitalPinId: i, isDigital: true, isAnalog: true, isPWM: false)
                pin.analogPinId = i-FIRST_ANALOG_PIN
            }
            
            if let pin = pin {
                pins.append(pin)
            }
        }
    }
    
    
    private func enableReadReports() {
        
        //Enable Read Reports by port
        let ports:[UInt8] = [0,1,2]
        for port in ports {
            let data0:UInt8 = 0xD0 + port        //start port 0 digital reporting (0xD0 + port#)
            let data1:UInt8 = 1                  //enable
            let bytes:[UInt8] = [data0, data1]
            let data = NSData(bytes: bytes, length: 2)
            UartManager.sharedInstance.sendData(data)
        }
        
        //Set all pin modes active
        for pin in pins {
            // Write pin mode
            setControlMode(pin, mode: pin.mode)
        }
    }
    
    func setControlMode(pin: PinData, mode: PinData.Mode) {
        let previousMode = pin.mode
        
        // Store
        pin.mode = mode
        
        DLog("pin \(pin.digitalPinId): mode: \(pin.mode.rawValue)")
        
        // Write pin mode
        let bytes:[UInt8] = [0xf4, UInt8(pin.digitalPinId), mode.rawValue]
        let data = NSData(bytes: bytes, length: bytes.count)
        UartManager.sharedInstance.sendData(data)
        
        // Update reporting for Analog pins
        if mode == .Analog {
            setAnalogValueReporting(pin, enabled: true)
        }
        else if previousMode == .Analog {
            setAnalogValueReporting(pin, enabled: false)
        }
    }
    
    func setAnalogValueReporting(pin: PinData, enabled: Bool) {
        // Write pin mode
        let bytes:[UInt8] = [0xC0 + UInt8(pin.analogPinId), UInt8(enabled ?1:0)]
        let data = NSData(bytes: bytes, length: bytes.count)
        UartManager.sharedInstance.sendData(data)
    }
    
    func setDigitalValue(pin: PinData, value: PinData.DigitalValue) {
        // Store
        pin.digitalValue = value
        
        // Write value
        let port = UInt8(pin.digitalPinId / 8)
        let data0 = 0x90+port
        
        let pinIndex = UInt8(pin.digitalPinId) - (port*8)
        var newMask = UInt8(value.rawValue * Int(powf(2, Float(pinIndex))))
        portMasks[Int(port)] &= ~(1 << pinIndex)    //prep the saved mask by zeroing this pin's corresponding bit
        newMask |= portMasks[Int(port)]             //merge with saved port state
        portMasks[Int(port)] = newMask
        var data1 = newMask<<1; data1 >>= 1         //remove MSB
        let data2 = newMask >> 7                    //use data1's MSB as data2's LSB
        
        
        let bytes:[UInt8] = [data0, data1, data2]
        let data = NSData(bytes: bytes, length: bytes.count)
        UartManager.sharedInstance.sendData(data)
    }
    
    private func setAnalogValue(pin: PinData, value: Int) {
        guard pin.mode == .Analog else {
            DLog("Error setting analog value to pin: \(pin.digitalPinId)")
            return
        }
        
        pin.analogValue = value
    }
    
    private var lastSentAnalogValueTime : NSTimeInterval = 0
    func setPMWValue(pin: PinData, value: Int) -> Bool {
        
        // Limit the amount of messages sent over Uart
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastSentAnalogValueTime >= 0.05 else {
            DLog("Won't send: Too many slider messages")
            return false
        }
        lastSentAnalogValueTime = currentTime
        
        // Store
        pin.analogValue = value
        
        // Send
        let data0 = 0xe0 + UInt8(pin.digitalPinId)
        let data1 = UInt8(value & 0x7f)         //only 7 bottom bits
        let data2 = UInt8(value >> 7)           //top bit in second byte
        
        let bytes:[UInt8] = [data0, data1, data2]
        let data = NSData(bytes: bytes, length: bytes.count)
        UartManager.sharedInstance.sendData(data)
        
        return true
    }

    private func receivedPinState(data: NSData) {
        
        /* pin state response
        * -------------------------------
        * 0  START_SYSEX (0xF0) (MIDI System Exclusive)
        * 1  pin state response (0x6E)
        * 2  pin (0 to 127)
        * 3  pin mode (the currently configured mode)
        * 4  pin state, bits 0-6
        * 5  (optional) pin state, bits 7-13
        * 6  (optional) pin state, bits 14-20
        ...  additional optional bytes, as many as needed
        * N  END_SYSEX (0xF7)
        */

        // Read received packet
        var dataBytes = [UInt8](count: data.length, repeatedValue: 0)
        data.getBytes(&dataBytes, length: data.length)
        
        if dataBytes.count >= 5 && dataBytes[0] == SYSEX_START && dataBytes[1] == 0x6e {
            let pinDigitalId = Int(dataBytes[2])
            let pinMode = PinData.Mode(rawValue: dataBytes[3])
            let pinState = Int(dataBytes[4])
            
            if let index = indexOfPinWithDigitalId(pinDigitalId), pinMode = pinMode {
                let pin = pins[index]
                setControlMode(pin, mode: pinMode)
                if (pinMode == .Analog || pinMode == .PWM || pinMode == .Servo) && dataBytes.count >= 6 {
                    let analogValue = pinState + Int(dataBytes[5])<<7
                    setAnalogValue(pin, value: analogValue)
                }
                else {
                    if let digitalValue = PinData.DigitalValue(rawValue: pinState) {
                        setDigitalValue(pin, value: digitalValue)
                    }
                    else {
                        DLog("Error parsing received pinstate: unkown digital value")
                    }
                }
            }
            else {
                DLog("Received PinState for unknown digital pin: \(pinDigitalId)")
            }
        }
        else {
            // Each pin state message is 3 bytes long
            for var i=0; i<dataBytes.count; i+=3 {
                if i+2 < dataBytes.count        // Check that current message length is at least 3 bytes
                {
                    if ((dataBytes[i] >= 0x90) && (dataBytes[i] <= 0x9F)) {       //Digital Reporting (per port)
                        let port = Int(dataBytes[i]) - 0x90
                        var pinStates = Int(dataBytes[i+1])
                        pinStates |= Int(dataBytes[i+2]) << 7    //PORT 0: use LSB of third byte for pin7, PORT 1: pins 14 & 15
                        updateForPinStates(pinStates, port: port)
                    }
                    else if ((dataBytes[i] >= 0xE0) && (dataBytes[i] <= 0xEF)) {       //Analog Reporting (per pin)
                        let analogPinId = Int(dataBytes[i]) - 0xE0
                        let value = Int(dataBytes[i+1]) + (Int(dataBytes[i+2])<<7)
                        
                        if let index = indexOfPinWithAnalogId(analogPinId) {
                            let pin = pins[index]
                            pin.analogValue = value
                        }
                        else {
                            DLog("Error parsing received pinstate: unkown analog pin")
                        }
                    }
                }
                else {
                    DLog("warning: pin state message length less than 3 bytes")
                }
            }
            
            // Refresh UI
            delegate?.onPinIODidReceivePinState()
        }
    }
    
    
    private func updateForPinStates(pinStates:Int, port:Int) {
        let offset = 8 * port
        
        // Iterate through all pins
        for var i = 0; i <= 7; i++ {
            var state = pinStates
            let mask = 1 << i
            state = state & mask
            state = state >> i
            
            let digitalId = i + offset
            
            if let index = indexOfPinWithDigitalId(digitalId), digitalValue = PinData.DigitalValue(rawValue: state) {
                let pin = pins[index]
                pin.digitalValue = digitalValue
            }
            else {
                DLog("Error parsing received pinstate for unkown digital pin: \(digitalId) DigitalValue: \(state)")
            }
        }
    }

    // MARK: - Utils
    static func stringForPinMode(mode: PinIOModuleManager.PinData.Mode)-> String {
        var modeString: String
        
        switch mode {
        case .Input:
            modeString = "Input"
        case .Output:
            modeString = "Output"
        case .Analog:
            modeString = "Analog"
        case .PWM:
            modeString = "PWM"
        case .Servo:
            modeString = "Servo"
        default:
            modeString = "NOT FOUND"
        }
        
        return modeString
    }
    
    static func stringForPinDigitalValue(digitalValue: PinIOModuleManager.PinData.DigitalValue)-> String {
        var valueString: String
        
        switch digitalValue {
        case .Low:
            valueString = "Low"
        case .High:
            valueString = "High"
        }
        return valueString
    }
}