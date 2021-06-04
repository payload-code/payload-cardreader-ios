//
//  PayloadCardReader.swift
//  PayloadCardReader
//
//  Copyright © 2021 Payload. All rights reserved.
//

import Foundation
import Network
import PayloadAPI

@objc public protocol PayloadCardReaderManagerDelegate: AnyObject {
    @objc optional func detected(_ reader: Payload.CardReader)
    @objc optional func connected(_ reader: Payload.CardReader)
    @objc optional func disconnected(_ reader: Payload.CardReader)
    @objc optional func connectionError(_ reader:Payload.CardReader,_ error:Payload.CardReader.Error)
    #if PL_DEBUG_EVT
    @objc optional func evt(_ evt:String)
    #endif
}


enum DelegateEvt {
    case detected
    case connected
    case disconnected
    case card_removed
    case connectionError
}

extension Payload {
    
    @objc public class CardReader:NSObject, PayloadCardReaderProto {
        
        var device:CBPeripheral?;
        var manager:Manager;
        var checkout:Checkout?;
        var cryptogram:String?;
        var swipe_timeout:DispatchWorkItem?;
        var pl_reader:Reader?;
        var emv_started:Bool = false;
        var emv_is_quickchip:Bool = false;
        var cmdResponse:String?;
        let timelimit:Int = 60;
        let type:UInt32;
        var arqc_received:Bool = false;
        var trans_response_received:Bool = false;
        @objc public let conn_type:String;
        @objc public var serial_no:String?;
        
        /* OPTIONS */
        @objc public static var device_sleep_timeout = 0;
        @objc public static var default_source:[String]?;
        @objc public static var emv_default_quickchip = false
        @objc public static var auto_connect = false
        
        @objc public enum Error: Int, RawRepresentable {
            case CardReaderNotPaired
            case Unknown
            
            public typealias RawValue = String
            public var rawValue: RawValue {
                switch self {
                case .CardReaderNotPaired:
                    return "CardReaderNotPaired"
                default:
                    return "Unknown"
                }
            }
            
            public init?(rawValue: RawValue) {
                switch rawValue {
                case "CardReaderNotPaired":
                    self = .CardReaderNotPaired
                default:
                    self = .Unknown
                }
            }
        }
        
        @objc public init(_ manager:Manager,_ device:CBPeripheral?,_ type:UInt32) {
            self.conn_type = self.device == nil ? "usb" : "bluethooth";
            self.device = device;
            self.manager = manager;
            self.type = type;
        }
        
        @objc public func getBatteryLevel()->Int {
            return self.manager.lib.getBatteryLevel()
        }
        
        func onConnected() {
            self.serial_no = self.manager.lib.getDeviceSerial();
            self.getPlCardReader()
            
            if self.type == MAGTEKTDYNAMO || self.type == MAGTEKKDYNAMO {
                self.sendDateTimeCommand()
                // Set sleep timeout to 30 mins and power off to 60
                self.sendCommandSync("5902"+String(format:"%02d", Payload.CardReader.device_sleep_timeout)+"00")
                //self.sendCommandSync("A00100")
                //self.sendCommandSync("15")
            }
        }
        
        func onDisconnected() {
        }
        
        @objc public func disconnect() {
            if self == Payload.connected_reader as? CardReader {
                self.manager.disconnect()
            }
        }
        
        
        @objc public func isTransactionStarted() -> Bool {
            return self.checkout != nil && self.checkout!.isTransactionStarted()
        }
        
        @objc public func isTransactionProcessing() -> Bool {
            return self.checkout != nil && self.checkout!.isTransactionProcessing()
        }
        
        @objc public func connect() {
            self.manager.stopMonitor();
            if self.manager.connected_reader != nil {
                self.manager.disconnect()
            }
            
            self.manager.setLib(Int(self.type));
            
            let delayTime = DispatchTime.now() + Double(Int64(0.1 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
            DispatchQueue.main.asyncAfter(deadline: delayTime) {
                self.manager.connected_reader = self;
                Payload.connected_reader = self;
                if self.device != nil {
                    self.manager.lib.setAddress(self.device!.identifier.uuidString);
                }
                self.manager.lib.openDevice();
            }
        }
        
        @objc public var name: String {
            get { return self.device?.name! ?? "iDynamo 6" }
        }
        
        func getPlCardReader() {
            Payload.all(Payload.Reader.filter_by(["serial_num": self.serial_no]), {(_ obj: Any) in
                let readers = obj as? [Payload.Reader]
                
                if readers?.count ?? 0 > 0 {
                    self.pl_reader = readers![0]
                } else {
                    Payload.create(Payload.Reader([
                        "type": "mgtk_edynamo",
                        "serial_num": self.serial_no,
                        "name": self.device?.name
                        ]), {(_ obj: Any) in
                            let reader = obj as? Payload.Reader
                            self.pl_reader = reader
                    })
                }
            })
        }
        
        @objc public func beginTransaction(_ payment:Transaction, delegate: PayloadTransactionDelegate) throws {
            let checkout = Checkout(payment, reader:self, delegate: delegate)
            try checkout.beginTransaction()
        }
            
        @objc public func beginTransaction(_ checkout:Payload.Checkout) throws {
            
            if self.checkout != nil {
                throw Payload.Errors.TransactionAlreadyStarted("Payment already started, cancel first")
            }
            
            self.checkout = checkout;
            
            if ( self.checkout!.payment.source == nil
                || self.checkout!.payment.source == "emv"
                || self.checkout!.payment.source == "emv_quickchip"
                || self.checkout!.payment.source == "nfc" ) {
                self.startCardReaderTransaction()
            } else if ( self.checkout!.payment.source == "swipe" ) {
                if ( self.manager.lib.getDeviceType() == MAGTEKTDYNAMO ) {
                    self.startCardReaderTransaction()
                } else {
                    self.startSwipe()
                }
            } else {
                self.checkout!.transactionFinished(payment: self.checkout!.payment, error: Payload.PayloadError("\(self.checkout!.payment.source!) not supported"))
                //throws Error("Invalid payment source")
            }
        }
        
        func cryptogramReady(cryptogram:String) {
            self.cryptogram = cryptogram
            
            self.checkout?.payment["cryptogram"] = cryptogram
            self.arqc_received = true;
            
            if ( self.pl_reader != nil ) {
                self.checkout?.payment["reader_id"] = self.pl_reader?.id
            }
            
            let tlv = TLV()
            if let data = cryptogram.asciiHexToData() {
                tlv.parse(data: data)
                
                if tlv.stags["DFDF52"] == nil {
                    if self.checkout?.payment != nil {
                        self.checkout?.transactionFinished(payment: self.checkout!.payment, error: Payload.Errors.ErrorReadingCard("Issue reading card, try again"))
                    }
                    return
                }
                
                self.manager.evt("[Card Type] \(tlv.stags["DFDF52"]!)")
                
                switch tlv.stags["DFDF52"]! {
                case "01":
                    self.manager.evt("SWIPE: \(tlv.stags["DFDF52"]!)")
                    self.checkout?.payment.source = "swipe"
                case "05":
                    if self.emv_is_quickchip {
                        self.checkout?.payment.source = "emv_quickchip"
                    } else {
                        self.checkout?.payment.source = "emv"
                    }
                case "06":
                    self.checkout?.payment.source = "nfc"
                case "07":
                    self.checkout?.payment.source = "swipe"
                default:
                    self.checkout?.payment.source = nil
                }
                
            }
            
            /*if self.emv_is_quickchip {
                self.checkout?.payment.source = "emv_quickchip"
            } else {
                self.checkout?.payment.source = "emv"
            }*/
            
            self.checkout?.transactionReady()
        }
        
        func swipeReady(_ cardDataObj: MTCardData!) {
            if self.checkout == nil { return }
            
            if ( self.pl_reader != nil ) {
                self.checkout?.payment["reader_id"] = self.pl_reader?.id
            }
            
            self.checkout?.payment.source = "swipe"
            self.checkout?.payment.payment_method = [
                "type": "card",
                "account_holder": cardDataObj.cardName,
                "card": [
                    "track1": cardDataObj.encryptedTrack1,
                    "track2": cardDataObj.encryptedTrack2,
                    "ksn": cardDataObj.deviceKSN,
                    "device_sn": cardDataObj.deviceSerialNumber,
                    "magne_print": cardDataObj.encryptedMagneprint,
                    "magne_print_status": cardDataObj.magneprintStatus,
                    "card_number": cardDataObj.cardPAN,
                    "expiry": cardDataObj.cardExpDate,
                ]
            ]
            
            self.checkout?.transactionReady()
        }
        
        public func transactionFinished(payment:Payload.Transaction) {
            if !self.arqc_received || self.trans_response_received {
                self.checkout?.transactionFinished(payment: payment)
            } else if self.arqc_received {
                self.emvFinished(payment: payment)
            }
        }
        
        func emvFinished(payment:Transaction) {
            if (payment.source == "emv" || payment.source == "swipe" || payment.source == "nfc") && self.emv_started {
                let tlv = TLV()
                if let data = self.cryptogram!.asciiHexToData() {
                    tlv.parse(data: data)
                    
                    //DispatchQueue.main.async{
                    self.manager.evt("[Send Response to Chip]")
                    
                    let response:Data = self.buildAcquirerResponse(
                        tlv.stags["DFDF25"]!.dataFromHexString()!,
                        encryptionType: tlv.stags["DFDF55"]!.dataFromHexString()!,
                        ksn: tlv.stags["DFDF54"]!.dataFromHexString()!,
                        approved: payment.status == "processed" || payment.status == "authorized"
                    )
                    
                    self.manager.evt("[EMV Acquirer Response]\n\(response.hexadecimalString)")
                    
                    self.manager.lib.setAcquirerResponse(UnsafeMutablePointer<UInt8> (mutating: (response as NSData).bytes.bindMemory(to: UInt8.self, capacity: response.count)), length: Int32( response.count))
                    
                    //}
                }
            }
        }

        func deviceTransactionResult(_ data:Data) {
            self.trans_response_received = true
            let tlv = TLV()
            tlv.parse(data: data.subdata(in: 1..<data.count).toArray(type: UInt8.self))
            let result = tlv.stags["DFDF1A"]!
            let aid = tlv.stags["9F06"]
            self.manager.evt("[TX Result] \(result)")
            
            if self.checkout != nil {
                if aid != nil {
                    self.manager.evt("[AID] \(aid!)")
                    self.checkout!.payment["aid"] = aid
                }
                switch(result) {
                case "00":
                    if !self.checkout!.isTransactionProcessing() {
                        if !self.emv_is_quickchip {
                            self.checkout!.transactionFinished(payment: self.checkout!.payment)
                        }
                    }
                    break
                case "01":
                    if self.checkout!.isTransactionProcessing() {
                        if !self.emv_is_quickchip {
                            self.checkout!.transactionTimeout()
                        }
                    } else {
                        self.checkout!.transactionFinished(payment: self.checkout!.payment)
                    }
                    break
                case "22":
                    self.checkout!.transactionTimeout()
                    break
                case "02":
                    self.checkout!.transactionFinished(payment: self.checkout!.payment, error: Payload.Errors.ErrorReadingCard("Issue reading card, try again"))
                    break
                case "FF":
                    self.checkout!.transactionFinished(payment: self.checkout!.payment, error: Payload.Errors.ErrorReadingCard("Issue reading card, try again"))
                    break
                default:
                    break
                }
            }
        }
        
        func deviceTransactionStatus(_ data:Data) {
            let dataString = data.hexadecimalString
            let evt = dataString.prefix(2)
            
            if self.checkout != nil {
                switch(evt) {
                case "01":
                    self.checkout!.delegateEvt(TxDelegateEvt.card_present, self.checkout!.payment)
                    break
                case "08":
                    self.checkout!.delegateEvt(TxDelegateEvt.card_removed, self.checkout!.payment)
                    break
                default:
                    break
                }
            }
        }
        
        @objc public func cancelTransaction(force:Bool=false) throws {
            try Payload.cancelTransaction()
        }
        
        @objc public func clearPayment() {
            self.checkout = nil
            self.cryptogram = nil
            if self.emv_started {
                self.manager.lib.cancelTransaction()
            }
            self.emv_started = false
            self.trans_response_received = false
            self.arqc_received = false
            self.swipe_timeout?.cancel()
        }

        @objc func startCardReaderTransaction() {
            
            /*if self.payment?.source == "emv_quickchip" {
             self.transactionFinished(payment: self.payment!, error: Payload.PayloadError("Quickchip not supported"))
             return
             }*/
            
            if let amount_float = self.checkout?.payment.amount {
                
                var cardType:UInt8 = 0;
                
                if self.checkout?.payment.source == nil {
                    if CardReader.default_source != nil {
                        for source in CardReader.default_source! {
                            if source == "swipe" {
                                cardType |= 0x01
                            } else if source == "emv" {
                                cardType |= 0x02
                            } else if source == "nfc" && (self.manager.lib.getDeviceType() == MAGTEKTDYNAMO || self.manager.lib.getDeviceType() == MAGTEKKDYNAMO) {
                                cardType |= 0x04
                            }
                        }
                    } else {
                        if self.manager.lib.getDeviceType() == MAGTEKEDYNAMO {
                            cardType = 0x01 | 0x02
                        } else if self.manager.lib.getDeviceType() == MAGTEKTDYNAMO || self.manager.lib.getDeviceType() == MAGTEKKDYNAMO {
                            cardType = 0x01 | 0x02 | 0x04
                        }
                    }
                } else if self.checkout?.payment.source == "swipe" {
                    cardType = 0x01
                } else if self.checkout?.payment.source == "emv" {
                    cardType = 0x02
                } else if self.checkout?.payment.source == "emv_quickchip" {
                    cardType = 0x02
                } else if self.checkout?.payment.source == "nfc" {
                    cardType = 0x04
                }
                //var amount_data = String(Int(amount_float*100)).dataFromHexString()
                //var amount:[UInt8] = [0x00, 0x00, 0x00, 0x00, 0x15, 0x00];
                
                var amount_data = String(format: "%012d", Int(amount_float*100)).dataFromHexString()
                var amount = [UInt8](repeating:0, count:amount_data!.count)
                amount_data!.copyBytes(to: &amount, count: amount_data!.count)
                
                //var arr : [UInt32] = [0x3c,4,123,4,5,2];
                let timeLimit:UInt8 = UInt8(timelimit);//0x3c;
                //let cardType:UInt8 = 0x02;
                
                var option:UInt8;
                if self.checkout?.payment.source == "emv_quickchip" {
                    option = 0x80;
                } else if self.checkout?.payment.source == nil
                && CardReader.emv_default_quickchip {
                    option = 0x80;
                }/* else if ( !Payload.offline_manager!.network_connectivity ) {
                    option = 0x80;
                }*/ else {
                    option = 0x00;
                }

                var transactionType:UInt8 = 0x00;
                if self.checkout?.payment["type"] as? String == "refund" {
                    transactionType = 0x20;
                }
                
                var cashBack:[UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
                var currencyCode:[UInt8] = [0x08, 0x40];
                let reportingOption:UInt8 = 0x02;
                
                self.emv_started = true
                self.emv_is_quickchip = option == 0x80

                var ret = self.manager.lib.startTransaction(
                    timeLimit,
                    cardType: cardType,
                    option: option,
                    amount: &amount,
                    transactionType: transactionType,
                    cashBack: &cashBack,
                    currencyCode: &currencyCode,
                    reportingOption: reportingOption
                )
            } else {
                self.checkout?.transactionFinished(payment: self.checkout!.payment, error: Payload.PayloadError("Invalid Amount"))
            }
        }
        
        func sendDateTimeCommand() {
            let date = Date()
            let calendar = Calendar.current
            let bytes:[UInt8] = [
                UInt8(calendar.component(.month, from: date)),
                UInt8(calendar.component(.day, from: date)),
                UInt8(calendar.component(.hour, from: date)),
                UInt8(calendar.component(.minute, from: date)),
                UInt8(calendar.component(.second, from: date)),
                UInt8(0),
                UInt8(calendar.component(.year, from: date)-2008)
            ]
            let dt_s = Data(bytes).hexEncodedString()
            
            let cmd = "49220000030C001C0000000000000000000000000000000000" + dt_s + "00000000";

            self.sendCommandSync(cmd)
        }
        
        func startSwipe() {
            self.swipe_timeout = DispatchWorkItem {
                self.checkout?.transactionTimeout()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(self.timelimit), execute: self.swipe_timeout!)
        }
        
        func buildAcquirerResponse(_ deviceSN: Data,  encryptionType: Data,ksn: Data, approved: Bool) ->Data {
            let response  = NSMutableData();
            var lenSN = 0;
            if (deviceSN.count > 0) {
                lenSN = deviceSN.count;
            }
            
            let snTagByte:[UInt8] = [0xDF, 0xdf, 0x25, UInt8(lenSN)];
            let snTag = Data(fromArray: snTagByte)
            
            var encryptLen:UInt8 = 0;
            _ = Data(bytes: &encryptLen, count: MemoryLayout.size(ofValue: encryptionType.count))
            
            let encryptionTypeTagByte:[UInt8] = [0xDF, 0xDF, 0x55, 0x01];
            let encryptionTypeTag =  Data(fromArray: encryptionTypeTagByte)
            
            var ksnLen:UInt8 = 0;
            _ = Data(bytes: &ksnLen, count: MemoryLayout.size(ofValue: encryptionType.count))
            let ksnTagByte:[UInt8] = [0xDF, 0xDF, 0x54, 0x0a];
            let ksnTag = Data(fromArray: ksnTagByte)
            
            let containerByte:[UInt8] = [0xFA, 0x06, 0x70, 0x04];
            let container = Data(fromArray: containerByte)
            
            let approvedARCByte:[UInt8] = [0x8A, 0x02, 0x30,0x30];
            let approvedARC = Data(fromArray: approvedARCByte)
            //
            let declinedARCByte:[UInt8] = [0x8A, 0x02, 0x30,0x35];
            let declinedARC = Data(fromArray: declinedARCByte)
            
            //let macPadding:[UInt8] = [0x00, 0x00,0x00,0x00,0x00,0x00,0x01,0x23, 0x45, 0x67];
            let macPadding:[UInt8] = [0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00, 0x00];
            
            var lenTLV = ksnTag.count + ksn.count + encryptionTypeTag.count + encryptionType.count + snTag.count + lenSN + container.count + approvedARC.count;
            
            var len = lenTLV + macPadding.count + 8;//2 + snTag.count + lenSN + container.count + approvedARC.count ;
            
            //len += encryptionTypeTag.count + encryptionType.count + ksnTag.count + ksn.count;
            
            var len1 = (UInt8)((len >> 8) & 0xff);
            var len2 = (UInt8)(len & 0xff);
            
            var tempByte = 0xf9;
            response.append(&len1, length: 1)
            response.append(&len2, length: 1)
            response.append(&tempByte, length: 1)
            
            var tempLen = encryptionTypeTag.count + encryptionType.count + ksnTag.count + ksn.count +  snTag.count + lenSN;
            response.append(&lenTLV, length: 1);
            response.append(ksnTag);
            response.append(ksn);
            response.append(encryptionTypeTag);
            response.append(encryptionType);
            response.append(snTag);
            response.append(deviceSN);
            response.append(container);
            if ( approved ) {
                response.append(approvedARC);
            } else {
                response.append(declinedARC);
            }
            
            response.append(Data(fromArray: macPadding))
            
            return response as Data;
        }
        /*
        #if PL_DEBUG_EVT
        @objc public func sendCommand(_ cmd: String) -> String? {
            return self.sendCommandSync(cmd)
        }
        #endif
        */
        @objc func sendCommandSync(_ cmd: String) -> String? {
            self.cmdResponse = nil;
            self.manager.evt("[Send Command] "+cmd)
            self.manager.lib.sendcommand(withLength: cmd);
            
            var counter:Int = 0;
            
            while (self.cmdResponse == nil && counter <= 20) {
                RunLoop.current.run(until: NSDate().addingTimeInterval(0.2) as Date);
                counter+=1;
            }
            
            return self.cmdResponse
        }
        
        @objc public class Manager : NSObject, MTSCRAEventDelegate {
            var lib: MTSCRA!;
            var deviceList:NSMutableArray!;
            var connected_reader:CardReader?;
            var scanning = false;
            @objc public var readers: [String: CardReader] = [:]
            
            public var delegate: PayloadCardReaderManagerDelegate?;
            
            public override convenience init() {
                self.init(nil)
            }
            
            @objc public init(_ delegate:PayloadCardReaderManagerDelegate?) {
                self.delegate = delegate
                super.init();
                
                self.lib = MTSCRA();
                
                self.setLib(MAGTEKEDYNAMO)

                self.deviceList = NSMutableArray();
                
            }
            
            @objc public func monitor() throws {
                /*if(self.lib.isDeviceOpened())
                 {
                 self.lib.closeDevice();
                 
                 return;
                 
                 }*/
                
                if self.connected_reader != nil {
                    throw Payload.Errors.CardReaderAlreadyConnected("Monitor cannot be started while a reader is connected")
                }
                
                if self.scanning || self.connected_reader != nil {
                    return
                }
                self.evt("[Start Monitor]")
                self.scanning = true
                
                self.readers = [:]

                let delayTime = DispatchTime.now() + Double(Int64(0.1 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
                DispatchQueue.main.asyncAfter(deadline: delayTime) {
                    self.switchScan(true)
                }
            }
            
            func setLib(_ type:Int) {
                if ( self.lib.getDeviceType() != type) {
                    #if (!arch(i386) && !arch(x86_64))
                    self.lib.delegate = nil
                    #endif
                    self.lib.setDeviceType(UInt32(type))
                    if type == MAGTEKKDYNAMO {
                        self.lib.setDeviceProtocolString("com.magtek.idynamo")
                    }
                    #if (!arch(i386) && !arch(x86_64))
                    // Workaround for simulator issues
                    self.lib?.delegate = self;
                    #endif
                }
            }
            
            func switchScan(_ first_run:Bool=false) {
                if !self.scanning { return }
                
                #if (!arch(i386) && !arch(x86_64))
                if !first_run {
                    
                    self.lib?.stopScanningForPeripherals()

                    if self.lib.getDeviceType() == MAGTEKEDYNAMO {
                        self.setLib(MAGTEKTDYNAMO)
                    } else if self.lib.getDeviceType() == MAGTEKKDYNAMO {
                        self.setLib(MAGTEKEDYNAMO)
                    } else {
                        self.setLib(MAGTEKKDYNAMO)
                    }
                    
                }
                
                if self.lib.getDeviceType() == MAGTEKKDYNAMO {
                    self.lib.openDevice()
                } else {
                    self.lib.closeDevice()
                    let delayTime1 = DispatchTime.now() + 0.1
                    DispatchQueue.main.asyncAfter(deadline: delayTime1) {
                       self.lib?.startScanningForPeripherals()
                    }
                }

                let delayTime = DispatchTime.now() + 1
                DispatchQueue.main.asyncAfter(deadline: delayTime) {
                    self.switchScan(false)
                }

                //self.lib?.scan
                #endif
            }
            
            @objc public func stopMonitor() {
                self.evt("[stopMonitor] scanning: \(self.scanning)")
                if self.scanning {
                    self.lib?.stopScanningForPeripherals()
                }
                self.scanning = false
            }
            
            public func bleReaderDidDiscoverPeripheral() {
                deviceList = lib?.getDiscoveredPeripherals();
                self.evt("[bleReaderDidDiscoverPeripheral] num devices: \(deviceList.count)")
                if deviceList.count == 0 {
                    return
                }
                let type = self.lib.getDeviceType();
                let per = (deviceList?.object(at: 0) as! CBPeripheral);
                
                if ( self.readers[per.identifier.uuidString] != nil ) {
                    return;
                }
                
                let dev = CardReader(self, per, UInt32(type) );
                self.readers[dev.device!.identifier.uuidString] = dev;
                
                self.delegateEvt(DelegateEvt.detected, dev);
                
                if CardReader.auto_connect {
                    dev.connect()
                }
            }
            
            @objc public func connectedCardReader() -> CardReader? {
                return self.connected_reader;
            }
            
            func evt(_ str:String) {
                #if PL_DEBUG_EVT
                NSLog(str)
                DispatchQueue.main.async {
                    self.delegate?.evt?(str)
                }
                #endif
            }
            
            public func onDeviceConnectionDidChange(_ deviceType: UInt, connected: Bool, instance: Any?) {
                self.evt("[onDeviceConnectionDidChange] isDeviceOpened: \((instance as! MTSCRA).isDeviceOpened()) connected: \(connected)")
                if((instance as! MTSCRA).isDeviceOpened() && connected) {
                    
                    if self.lib.getDeviceType() == MAGTEKKDYNAMO {
                        if self.scanning {
                            if self.readers["usb"] == nil {
                                let dev = CardReader(self, nil, UInt32(MAGTEKKDYNAMO) );
                                self.readers["usb"] = dev;
                                self.delegateEvt(DelegateEvt.detected, dev);
                            }
                            self.lib.closeDevice()
                            return
                        }
                        
                        else if self.connected_reader == nil {
                            self.lib.closeDevice()
                            return
                        }
                    }
                    
                    let dispatchQueue = DispatchQueue(label: "QueueIdentification", qos: .background)
                    dispatchQueue.async{
                        var response:Bool = false
                        for _ in 0...10 {
                            if self.connected_reader == nil {
                                break
                            }
                            
                            self.evt("[Connection Test] send sync")
                            if (self.connected_reader?.sendCommandSync("000103")) != nil {
                                self.connected_reader?.onConnected()
                                
                                let reader = self.connected_reader!
                                DispatchQueue.main.async {
                                    self.delegateEvt(DelegateEvt.connected, reader);
                                }
                                response = true
                                break
                            }
                        }
                        
                        if !response && self.connected_reader != nil {
                            self.evt("[Connection Test] failed to connect")
                            self.readerNotPaired()
                        }
                    }
                    
                    //self.sendCommandSync("480101");
                    
                } else {
                    if self.connected_reader != nil {
                        self.connected_reader?.onDisconnected()
                        self.delegateEvt(DelegateEvt.disconnected, self.connected_reader!);
                        self.connected_reader = nil;
                        Payload.connected_reader = nil;
                        
                    }
                }
            }
            
            @objc public func disconnect() {
                self.evt("[Disconnect] isDeviceOpened: \(self.lib.isDeviceOpened())")
                if(self.lib.isDeviceOpened()) {
                    self.lib.closeDevice();
                }
            }
            
            func delegateEvt(_ evt:DelegateEvt,_ args:Any...) {
                self.evt("[CardReaderDelegateEvt] \(evt)")
                
                DispatchQueue.main.async {
                    switch(evt){
                    case DelegateEvt.disconnected:
                        self.evt("[CardReaderDelegateEvt] fire:disconnected exists:\(self.delegate?.disconnected != nil)")
                        self.delegate?.disconnected?(args[0] as! Payload.CardReader)
                        break
                    case DelegateEvt.connected:
                        self.evt("[CardReaderDelegateEvt] fire:connected exists:\(self.delegate?.connected != nil)")
                        self.delegate?.connected?(args[0] as! Payload.CardReader)
                        break
                    case DelegateEvt.connectionError:
                        self.evt("[CardReaderDelegateEvt] fire:connectionError exists:\(self.delegate?.connectionError != nil)")
                        self.delegate?.connectionError?(args[0] as! Payload.CardReader, args[1] as! Payload.CardReader.Error)
                        break
                    case DelegateEvt.detected:
                        self.evt("[CardReaderDelegateEvt] fire:detected exists:\(self.delegate?.detected != nil)")
                        self.delegate?.detected?(args[0] as! Payload.CardReader)
                        break
                    
                    default:
                        self.evt("[CardReaderDelegateEvt] unknown event")
                        break
                    }
                }
            }
            
            public func readerNotPaired() {
                self.evt("[readerNotPaired]")
                if self.connected_reader != nil {
                    self.delegateEvt(DelegateEvt.connectionError, self.connected_reader!, Payload.CardReader.Error.CardReaderNotPaired);
                    self.connected_reader = nil;
                    Payload.connected_reader = nil;
                    self.disconnect()
                }
            }
            
            public func onARQCReceived(_ data: Data!) {
                let dataString = data.hexEncodedString(options: .upperCase);
                
                self.evt("[onARQCReceived] \(dataString)")
                
                self.connected_reader?.cryptogramReady(cryptogram:dataString)
                
            }
            
            public func onDataReceived(_ cardDataObj: MTCardData!, instance: Any?) {
                self.evt("[onDataReceived]")
                self.connected_reader?.swipeReady(cardDataObj)
            }
            
            public func onDeviceResponse(_ data: Data!) {
                self.connected_reader?.cmdResponse = data.hexadecimalString as String;
                self.evt("[Device Response] \(data.hexadecimalString as String)")
                
                if data.hexadecimalString as String == "0900"
                    && self.connected_reader?.checkout != nil {
                    self.connected_reader?.checkout?.transactionFinished(payment: (self.connected_reader?.checkout!.payment)!, error: Payload.Errors.BatteryTooLow("The reader's battery is too low"))
                }
            }
            
            public func onDeviceExtendedResponse(_ data:String) {
                self.connected_reader?.cmdResponse = data
                self.evt("[Device Extended Response] \(data)")
                //MTSCRAEventDelegate.onDeviceExtendedResponse
            }
            
            public func onUserSelectionRequest(_ data: Data!) {
                let dataString = data.hexadecimalString;
                self.evt("[User Selection Request] \(dataString)")
                self.lib.setUserSelectionResult(0, selection: 0)
            }
            
            public func onTransactionResult(_ data: Data!) {
                let dataString = data.hexadecimalString;
                self.evt("[Transaction Response]\n\(dataString)")
                self.connected_reader?.deviceTransactionResult(data)
            }
            
            public func onTransactionStatus(_ data: Data!) {
                let dataString = data.hexadecimalString;
                self.evt("[Transaction Status] \(dataString)")
                
                self.connected_reader?.deviceTransactionStatus(data)
            }
            
            public func onEMVCommandResult(_ data: Data!) {
                let dataString = data.hexadecimalString;
                
                if data[0] == 0x03 {
                    self.connected_reader?.checkout!.transactionFinished(payment: (self.connected_reader?.checkout!.payment)!, error: Payload.Errors.ErrorReadingCard("Issue with reader, try again"))
                }
                
                self.evt("[EMV Command Result]\n\(dataString)")
            }
            
            public func onDisplayMessageRequest(_ data: Data!) {
                let dataString = data.hexadecimalString;
                self.evt("[Display Message Request] \(dataString.stringFromHexString)")
                
                if dataString.stringFromHexString == "USE CHIP READER" {
                    self.connected_reader?.checkout!.transactionFinished(payment: (self.connected_reader?.checkout!.payment)!, error: Payload.Errors.UseChipReader("Please try again using the chip reader"))
                }
            }
        }
    }

}

