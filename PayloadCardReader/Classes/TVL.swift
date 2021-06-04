public class TLV {
    var tags:[UInt64:[UInt8]] = [:]
    var stags:[String:String] = [:]
    var len:Int = 0;
    
    public init() {}
    
    public func parse(data:[UInt8]) {
        len = (Int(data[0])<<0x8) + Int(data[1])
        
        print("len: \(len) \(data[0]) \(data[1])")
        var offset:Int = 2
        self.parse_tags(data: Array(data[...(offset+len)]), offset: &offset)
    }
    
    func parse_tags(data:[UInt8], offset:inout Int) {
        while offset < len {
            let tagId = self.getTag(data, offset: &offset)
            if let tagLen = self.getTagLen(data, offset: &offset) {
                if tagLen == 0 { continue }
                if((tagId[0] & 0x20) != 0x20) {
                    if let tag = arrayToUInt64(tagId) {
                        if (offset+Int(tagLen)-1) >= data.count {
                            break
                        }
                        let val:[UInt8] = Array(data[offset...(offset+Int(tagLen)-1)])
                        self.tags[tag] = val
                        //NSLog("\(tagId.map{$0.toAsciiHex()}.joined()): \(val.map{$0.toAsciiHex()}.joined()) len:\(tagLen)")
                        self.stags[tagId.map{$0.toAsciiHex()}.joined()] = val.map{$0.toAsciiHex()}.joined();
                        offset = (offset+Int(tagLen))
                    }
                } else {
                    //NSLog("\(tagId.map{$0.toAsciiHex()}.joined()) Template len:\(tagLen)")
                }
            }
        }
    }
    
    func getTag(_ data:[UInt8], offset:inout Int) -> [UInt8] {
        var tagArray:[UInt8] = [UInt8]()
        while true {
            tagArray.append(data[offset]);
            offset += 1
            if data[offset-1] == 0x81 {
                tagArray.append(data[offset]);
                offset += 1
            }
            if (data[offset-1] & 0x1F) != 0x1F {
                break
            }
        }
        
        return tagArray;
    }
    
    func getTagLen(_ data:[UInt8], offset:inout Int) -> UInt64? {
        if(data.count == offset){
            return 0x00
        }
        
        let value = data[offset]
        var length:UInt64 = 0
        
        offset += 1
        if value > 0x80 {
            for _ in 0..<(value - 0x80) {
                length = (length<<0x8)+UInt64(data[offset])
                offset += 1
            }
        } else {
            length = UInt64(value)
        }
        
        return length
        /*if((data[offset] & 0x80) == 0x80){
            let lengthCount:UInt8 = data[offset] ^ 0x80;
            if lengthCount <= 1 {
                return 0
            }
            offset += 1
            var end = offset + Int(lengthCount) - 1
            NSLog("count:\(data.count) offset:\(offset) end:\(end)")
            if offset + end >= data.count {
                end = data.count - 1
                NSLog("adjust count:\(data.count) offset:\(offset) end:\(end)")
            }
            
            let lengthBytes:[UInt8] = Array(data[offset...end]);
            offset = end + 1
            return arrayToUInt64(lengthBytes);
        } else {
            let result = data[offset];
            offset += 1
            return UInt64(result);
        }*/
    }
}


func arrayToUInt64(_ data:[UInt8]) -> UInt64?{
    if(data.count > 8){
        return nil;
    }
    let nsdata = NSData(bytes: data.reversed(), length: data.count);
    var temp:UInt64 = 0;
    nsdata.getBytes(&temp, length: MemoryLayout<UInt64>.size);
    return temp;
}

func cleanHex(_ hexStr:String) -> String{
    return hexStr.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).replacingOccurrences(of: " ", with: "")
}

public func isValidHex(_ asciiHex:String) -> Bool{
    let regex = try! NSRegularExpression(pattern: "^[0-9a-f]*$", options: .caseInsensitive)
    
    let found = regex.firstMatch(in: asciiHex, options: [], range: NSMakeRange(0, asciiHex.count))
    if found == nil || found?.range.location == NSNotFound || asciiHex.count % 2 != 0 {
        return false;
    }
    
    return true;
}

extension Int {
    func toByteArray() -> [UInt8]{
        var moo = self;
        var array = withUnsafeBytes(of: &moo) { Array($0) }
        array = array.reversed()
        guard let index = array.index(where: {$0 > 0}) else {
            return Array(array)
        }
        
        if index != array.endIndex-1 {
            return Array(array[index...array.endIndex-1])
        }else{
            return [array.last!]
        }
    }
}

extension UInt64 {
    public func toByteArray() -> [UInt8]{
        var moo = self
        var array = withUnsafeBytes(of: &moo) { Array($0) }
        array = array.reversed()
        
        guard let index = array.index(where: {$0 > 0}) else {
            return Array(array)
        }
        
        if index != array.endIndex-1 {
            return Array(array[index...array.endIndex-1])
        }else{
            return [array.last!]
        }
        
    }
}

extension UInt8 {
    public func toAsciiHex() -> String{
        let temp = self;
        return String(format: "%02X", temp);
    }
    
    func isConstructedTag() -> Bool{
        return ((self & 0x20) == 0x20)
    }
}

extension String{
    public func asciiHexToData() -> [UInt8]?{
        
        let trimmedString = self.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).replacingOccurrences(of: " ", with: "")
        
        if(isValidHex(trimmedString)){
            var data = [UInt8]()
            var index = 0
            while index < trimmedString.count {
                
                let start = trimmedString.index(trimmedString.startIndex, offsetBy: index);
                let finish = trimmedString.index(trimmedString.startIndex,offsetBy: index+1);
                let range = start...finish
                let byteString = trimmedString[range]
                
                let byte = UInt8(byteString.withCString { strtoul($0, nil, 16) })
                data.append(byte)
                
                index = index+2;
            }
            
            return data
        }else{
            return nil
        }
    }
}
