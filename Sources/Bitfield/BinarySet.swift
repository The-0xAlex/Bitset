import Foundation

private extension Int64 {
  func toUInt64() -> UInt64 { UInt64(bitPattern: self) }
  func toInt() -> Int { Int(truncatingIfNeeded: self) }
}

private extension UInt64 {
  func toInt64() -> Int64 { Int64(bitPattern: self) }
  func toInt() -> Int { Int(truncatingIfNeeded: self) }
}

/// An efficient algebraic container for set-algebra with non-negative integers.
///
///  * Assumes 64bit architecture
///  * Endianness of function returns is documented where relevant
public final class Bitfield: Sequence, Equatable, CustomStringConvertible,
                              Hashable, ExpressibleByArrayLiteral {
  static let wordSize = 8
  var capacity = 8
  var wordcount = 0 // Accumulator
  var data: UnsafeMutablePointer<UInt64>
  
  public init() {
    data = UnsafeMutablePointer<UInt64>.allocate(capacity:capacity)
    wordcount = 0
  }
  
  /// Copy constructor
  public init(_ other: Bitfield) {
    capacity = other.wordcount
    wordcount = other.wordcount
    data = UnsafeMutablePointer<UInt64>.allocate(capacity:capacity)
    for i in 0..<capacity {
      data[i] = other.data[i]
    }
  }
  
  deinit {
    data.deallocate()
  }
  
  /// Create Bitfield containing the list of integers, all values must be
  /// non-negative adding the value i to the Bitfield will cause the use
  /// of least (i+8)/8 bytes.
  public init(_ allints: [Int]) {
    var mymax = 0
    for i in allints { mymax = mymax < i ? i : mymax }
    wordcount = (mymax+63)/64 + 1
    capacity = wordcount
    data = UnsafeMutablePointer<UInt64>.allocate(capacity:wordcount)
    for k in 0..<wordcount {
      data[k] = 0
    }
    addMany(allints)
  }
  
  /// Init with array literal.
  ///
  /// - Complexity: O(n) where n is count of input array.
  public init(arrayLiteral elements: Int...) {
    var max = 0
    for i in elements { max = max < i ? i : max }
    wordcount = (max + 63) / 64 + 1
    capacity = wordcount
    data = UnsafeMutablePointer<UInt64>.allocate(capacity: wordcount)
    for k in 0..<wordcount {
      data[k] = 0
    }
    for i in elements { add(i) }
  }
  
  /// Load an uncompressed bitmap from a byte buffer, in ascending order.
  ///
  /// The expected format is equivalent to that of an array of 64-bit unsigned
  /// integers stored *little endian*, except that zero bytes at the end are
  /// omitted.  This function is compatible with the toData() function.
  ///
  /// - Warning: Expects 64-bit internal representation.
  public init(bytes: Data) {
    assert(Bitfield.wordSize == 8)
    let byteCount = bytes.count
    guard (byteCount != 0) else {
      data = UnsafeMutablePointer<UInt64>.allocate(capacity:capacity)
      return
    }
    capacity = (byteCount - 1) / Bitfield.wordSize + 1
    wordcount = capacity
    data = UnsafeMutablePointer<UInt64>.allocate(capacity:capacity)
    
    // Intentionally outlined
    func iterate<T>(_ pointer: T, _ f: (T, Int, Int) -> UInt64) -> Int {
      var remaining = byteCount
      var offset = 0
      for w in 0..<capacity {
        if remaining < Bitfield.wordSize { break }
        // Copy entire word - assumes data is aligned to word boundary
        let next = offset + Bitfield.wordSize
        var word: UInt64 = f(pointer, offset, w)
        word = CFSwapInt64LittleToHost(word)
        remaining -= Bitfield.wordSize
        offset = next
        data[w] = word
      }
      return remaining
    }
    var remaining = byteCount
    if remaining > Bitfield.wordSize {
#if swift(>=5.0)
      remaining = bytes.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Int in
        iterate(pointer) { (pointer, offset, _) in
          pointer.load(fromByteOffset: offset, as: UInt64.self)
        }
      }
#else
      remaining = bytes.withUnsafeBytes { // deprecated
        (pointer: UnsafePointer<UInt64>) -> Int in
        iterate(pointer) { ($0 + $2).pointee
        }
      }
#endif
    }
    if remaining > 0 {
      /// Copy last word fragment.
      /// Manual byte copy seems to be approx 50% faster than `copyBytes` with
      /// `withUnsafeMutableBytes` on Apple M1 Max (Firestorm isolated).  13 July 2022
      var word: UInt64 = 0
      let offset = byteCount - remaining
      for b in 0..<remaining {
        let byte = UInt64(clamping: bytes[offset + b])
        word = word | (byte << (b * 8))
      }
      data[capacity-1] = word
    }
    // TODO: (Alex) shrink bitmap according to MSB
  }
  
  /// Store as uncompressed bitmap as a byte buffer in ascending order, with
  /// a bytes size that captures the most significant bit, or an empty instance
  /// if no bits are present
  ///
  /// The format is equivalent to that of an array of 64-bit unsigned integers
  /// stored in *little endian* except that zero bytes at the end are omitted.
  /// This function is compatible with the init(bytes: Data) constructor.
  ///
  /// - Warning: This function assumes 64bit internal representation.
  public func toData() -> Data {
    assert(Bitfield.wordSize == 8)
    let heighestWord = self.heighestWord()
    if heighestWord < 0 { return Data() }
    let lastWord = Int64(bitPattern: data[heighestWord])
    let lastBit = Int(flsll(lastWord))
    let lastBytes = lastBit == 0 ? 0 : (lastBit - 1) / 8 + 1
    let size = heighestWord * Bitfield.wordSize + lastBytes
    var output = Data(capacity: size)
    for w in 0...heighestWord {
      var word = CFSwapInt64HostToLittle(data[w])
      let byteCount = w == heighestWord ? lastBytes : Bitfield.wordSize
      let bytes = Data(bytes: &word, count: byteCount) // About 10x faster than memcpy
      output.append(bytes)
    }
    return output
  }
  
  public typealias Element = Int
  
  /// An empty Bitfield
  public static var allZeros: Bitfield { return Bitfield() }
  
  /// Union between two Bitfields, producing a new Bitfield
  public static func | (lhs: Bitfield, rhs: Bitfield) -> Bitfield {
    let mycopy = Bitfield(lhs)
    mycopy.union(rhs)
    return mycopy
  }
  
  /// The union between two Bitfields inplace
  public static func |= (lhs: Bitfield, rhs: Bitfield) {
    lhs.union(rhs)
  }
  
  
  /// Difference between two Bitfields, returns a new Bitfield
  public static func - (lhs: Bitfield, rhs: Bitfield) -> Bitfield {
    let mycopy = Bitfield(lhs)
    mycopy.difference(rhs)
    return mycopy
  }
  
  /// Inplace difference between two Bitfields
  public static func -= (lhs: Bitfield, rhs: Bitfield) {
    lhs.difference(rhs)
  }
  
  /// Symmetric difference between two Bitfields, producing a new Bitfield
  public static func ^ (lhs: Bitfield, rhs: Bitfield) -> Bitfield {
    let mycopy = Bitfield(lhs)
    mycopy.symmetricDifference(rhs)
    return mycopy
  }
  
  /// Inplace symmetric difference between two Bitfields
  public static func ^= (lhs: Bitfield, rhs: Bitfield) {
    lhs.symmetricDifference(rhs)
  }
  
  /// Compute the union between two Bitfields inplace
  public static func &= (lhs: Bitfield, rhs: Bitfield) {
    lhs.intersection(rhs)
  }
  
  /// Computes the intersection between two Bitfields and return a new Bitfield
  public static func & (lhs: Bitfield, rhs: Bitfield) -> Bitfield {
    let mycopy = Bitfield(lhs)
    mycopy.intersection(rhs)
    return mycopy
  }
  
  /// Hashable conformance
  public func hash(into hasher: inout Hasher) {
    for i in 0..<wordcount {
      hasher.combine(data[i])
    }
  }
  
  /// Returns a string representation of the Bitfield
  public var description: String {
    var ret = prefix(100).map { $0.description }.joined(separator: ", ")
    if count() >= 100 {
      ret.append(", ...")
    }
    return "{\(ret)}"
  }
  
  /// Create an iterator over the values contained in the Bitfield
  public func makeIterator() -> BitfieldIterator {
    return BitfieldIterator(self)
  }
  
  /// Count how many values have been stored in the Bitfield
  /// - Complexity: O(n) where n is number of words in Bitfield.
  public func count() -> Int {
    var sum: Int = 0
    for i in 0..<wordcount {
      let w = data[i]
      sum = sum &+ w.nonzeroBitCount
    }
    return sum
  }
  
  /// Proxy for "count"
  public func cardinality() -> Int { return count() }
  
  /// Add a value to the Bitfield, all values must be non-negative
  ///
  /// adding the value i to the Bitfield will cause the use of least (i+8)/8 bytes
  public func add(_ value: Int) {
    let index = value >> 6
    if index >= self.wordcount { increaseWordCount( index + 1) }
    data[index] |= 1 << (UInt64(value & 63))
  }
  
  /// Add all the values  to the Bitfield
  ///
  /// Adding the value i to the Bitfield will cause the use of least (i+8)/8 bytes
  public func addMany(_ allints: Int...) {
    var mymax = 0
    for i in allints { mymax = mymax < i ? i : mymax }
    let maxindex = mymax >> 6
    if maxindex >= self.wordcount {
      increaseWordCount(maxindex + 1)
    }
    for i in allints { add(i) }
  }
  
  /// Add all the values  to the Bitfield
  ///
  /// Adding the value i to the Bitfield will cause the use of least (i+8)/8 bytes
  public func addMany(_ allints: [Int]) {
    var mymax = 0
    for i in allints { mymax = mymax < i ? i : mymax }
    let maxindex = mymax >> 6
    if maxindex >= self.wordcount {
      increaseWordCount(maxindex + 1)
    }
    for i in allints { add(i) }
  }
  
  /// Check that a value is in the Bitfield, all values must be non-negative
  public func contains(_ value: Int) -> Bool {
    let index = value >> 6
    if index >= self.wordcount { return false }
    return data[index] & (1 << (UInt64(value & 63))) != 0
  }
  
  public subscript(value: Int) -> Bool {
    get {
      return contains(value)
    }
    set(newValue) {
      if newValue { add(value)} else {remove(value)}
    }
  }
  
  /// Compute the intersection (in place) with another Bitfield
  public func intersection(_ other: Bitfield) {
    let mincount = Swift.min(self.wordcount, other.wordcount)
    for i in 0..<mincount { data[i] &= other.data[i] }
    for i in mincount..<self.wordcount { data[i] = 0 }
  }
  
  /// Compute the size of the intersection with another Bitfield
  public func intersectionCount(_ other: Bitfield) -> Int {
    let mincount = Swift.min(self.wordcount, other.wordcount)
    var sum = 0
    for i in 0..<mincount { sum = sum &+ ( data[i] & other.data[i]).nonzeroBitCount }
    return sum
  }
  
  /// Compute the union (in place) with another Bitfield
  public func union(_ other: Bitfield) {
    let mincount = Swift.min(self.wordcount, other.wordcount)
    for  i in 0..<mincount {
      data[i] |= other.data[i]
    }
    if other.wordcount > self.wordcount {
      self.matchWordCapacity(other.wordcount)
      self.wordcount = other.wordcount
      for i in mincount..<other.wordcount {
        data[i] = other.data[i]
      }
    }
  }
  
  /// Compute the size union  with another Bitfield
  public func unionCount(_ other: Bitfield) -> Int {
    let mincount = Swift.min(self.wordcount, other.wordcount)
    var sum = 0
    for  i in 0..<mincount {
      sum = sum &+ (data[i] | other.data[i]).nonzeroBitCount
    }
    if other.wordcount > self.wordcount {
      for i in mincount..<other.wordcount {
        sum = sum &+ (other.data[i]).nonzeroBitCount
      }
    } else {
      for i in mincount..<self.wordcount {
        sum = sum &+ (data[i]).nonzeroBitCount
      }
    }
    return sum
  }
  
  /// Compute the symmetric difference (in place) with another Bitfield
  public func symmetricDifference(_ other: Bitfield) {
    let mincount = Swift.min(self.wordcount, other.wordcount)
    for  i in 0..<mincount {
      data[i] ^= other.data[i]
    }
    if other.wordcount > self.wordcount {
      self.matchWordCapacity(other.wordcount)
      self.wordcount = other.wordcount
      for i in mincount..<other.wordcount {
        data[i] = other.data[i]
      }
    }
  }
  
  /// Compute the size union  with another Bitfield
  public func symmetricDifferenceCount(_ other: Bitfield) -> Int {
    let mincount = Swift.min(self.wordcount, other.wordcount)
    var sum = 0
    for  i in 0..<mincount {
      sum = sum &+ (data[i] ^ other.data[i]).nonzeroBitCount
    }
    if other.wordcount > self.wordcount {
      for i in mincount..<other.wordcount {
        sum = sum &+ other.data[i].nonzeroBitCount
      }
    } else {
      for i in mincount..<self.wordcount {
        sum = sum &+ (data[i]).nonzeroBitCount
      }
    }
    return sum
  }
  
  /// Compute the difference (in place) with another Bitfield
  public func difference(_ other: Bitfield) {
    let mincount = Swift.min(self.wordcount, other.wordcount)
    for  i in 0..<mincount {
      data[i] &= ~other.data[i]
    }
  }
  
  /// Compute the size of the difference with another Bitfield
  public func differenceCount(_ other: Bitfield) -> Int {
    let mincount = Swift.min(self.wordcount, other.wordcount)
    var sum = 0
    for  i in 0..<mincount {
      sum = sum &+ ( data[i] & ~other.data[i]).nonzeroBitCount
    }
    for i in mincount..<self.wordcount {
      sum = sum &+ (data[i]).nonzeroBitCount
    }
    return sum
  }
  
  /// Remove a value, must be non-negative
  public func remove(_ value: Int) {
    let index = value >> 6
    if index < self.wordcount {
      data[index] &= ~(1 << UInt64(value & 63))
    }
  }
  
  /// Remove a value, if it is present it is removed, otherwise it is added,
  /// must be non-negative
  public func flip(_ value: Int) {
    let index = value >> 6
    if index < self.wordcount {
      data[index] ^= 1 << UInt64(value & 63)
    } else {
      increaseWordCount(index + 1)
      data[index] |= 1 << UInt64(value & 63)
    }
  }
  
  /// Remove many values, all must be non-negative
  public func removeMany(_ allints: Int...) {
    for i in allints { remove(i) }
  }
  
  /// Return the memory usage of the backing array in bytes
  public func memoryUsage() -> Int {
    return self.capacity * 8
  }
  
  /// Check whether the value is empty
  public func isEmpty() -> Bool {
    for i in 0..<wordcount {
      let w = data[i]
      if w != 0 { return false; }
    }
    return true
  }
  
  /// Remove all elements, optionally keeping the capacity intact
  public func removeAll(keepingCapacity keepCapacity: Bool = false) {
    wordcount = 0
    if !keepCapacity {
      data.deallocate()
      capacity = 8 // reset to some default
      data = UnsafeMutablePointer<UInt64>.allocate(capacity:capacity)
    }
  }
  
  private static func nextCapacity(mincap: Int) -> Int {
    return 2 * mincap
  }
  
  /// Caller is responsible to ensure that index < wordcount otherwise this function fails!
  func increaseWordCount(_ newWordCount: Int) {
    if(newWordCount <= wordcount) {
      print(newWordCount, wordcount)
    }
    if newWordCount > capacity {
      growWordCapacity(Bitfield.nextCapacity(mincap : newWordCount))
    }
    for i in wordcount..<newWordCount {
      data[i] = 0
    }
    wordcount = newWordCount
  }
  
  func growWordCapacity(_ newcapacity: Int) {
    let newdata = UnsafeMutablePointer<UInt64>.allocate(capacity:newcapacity)
    for i in 0..<self.wordcount {
      newdata[i] = self.data[i]
    }
    data.deallocate()
    data = newdata
    self.capacity = newcapacity
  }
  
  func matchWordCapacity(_ newcapacity: Int) {
    if newcapacity > self.capacity {
      growWordCapacity(newcapacity)
    }
  }
  
  func heighestWord() -> Int {
    for i in (0..<wordcount).reversed() {
      let w = data[i]
      if w.nonzeroBitCount > 0 { return i }
    }
    return -1
  }
  
  /// Checks whether the two Bitfields have the same contents
  public static func == (lhs: Bitfield, rhs: Bitfield) -> Bool {
    if lhs.wordcount > rhs.wordcount {
      for  i in rhs.wordcount..<lhs.wordcount  where lhs.data[i] != 0 {
        return false
      }
    } else if lhs.wordcount < rhs.wordcount {
      for i in lhs.wordcount..<rhs.wordcount where  rhs.data[i] != 0 {
        return false
      }
    }
    let mincount = Swift.min(rhs.wordcount, lhs.wordcount)
    for  i in 0..<mincount where rhs.data[i] != lhs.data[i] {
      return false
    }
    return true
  }
}

public struct BitfieldIterator: IteratorProtocol {
  let Bitfield: Bitfield
  var value: Int = -1
  
  init(_ Bitfield: Bitfield) {
    self.Bitfield = Bitfield
  }
  
  public mutating func next() -> Int? {
    value = value &+ 1
    var x = value >> 6
    if x >= Bitfield.wordcount {
      return nil
    }
    var w = Bitfield.data[x]
    w >>= UInt64(value & 63)
    if w != 0 {
      value = value &+ w.trailingZeroBitCount
      return value
    }
    x = x &+ 1
    while x < Bitfield.wordcount {
      let w = Bitfield.data[x]
      if w != 0 {
        value = x &* 64 &+ w.trailingZeroBitCount
        return value
      }
      x = x &+ 1
    }
    return nil
  }
}
