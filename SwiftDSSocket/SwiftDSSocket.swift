//
//  SwiftAsyncSocket.swift
//  SwiftAsyncSocket
//
//  Created by Yi Huang on 7/7/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

// Important Note: DispatchSource for unix sockets are level triggered
// 1. delegateQueue must be set or no delagated functions will be called
// 2. this library automatically creates a queue for socket handlers

import Foundation

#if os(Linux)
  import Glibc
#else // os(Darwin)
  import Darwin
#endif

@objc public protocol SwiftDSSocketDelegate {
  @objc optional func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int)
  @objc optional func socket(sock: SwiftDSSocket, didWrite tag: Int)
  @objc optional func socket(sock: SwiftDSSocket, didCloseConnection error: SwiftDSSocket.SocketError?)
  @objc optional func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16)
  @objc optional func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket)
}

struct Queue<T> {
  fileprivate var array = [T?]()
  fileprivate var head = 0
  
  public var isEmpty: Bool {
    return count == 0
  }
  
  public var count: Int {
    return array.count - head
  }
  
  public mutating func removeAll() {
    array.removeAll()
  }
  
  public mutating func enqueue(_ element: T) {
    array.append(element)
  }
  
  public mutating func removeTop() {
    guard head < array.count else { return }
    
    array[head] = nil
    head += 1
    
    let percentage = Double(head) / Double(array.count)
    if array.count > 50 && percentage > 0.25 {
      array.removeFirst(head)
      head = 0
    }
  }
  
  public var front: T? {
    if isEmpty {
      return nil
    } else {
      return array[head]
    }
  }
}

class SwiftDSSocketReadPacket: NSObject {
  var buffer: UnsafeMutablePointer<UInt8>?
  var bufferCapacity = 0
  var bufferOffset = 0
  var readTag = 0
  
  init(capacity: Int, tag: Int = -1) {
    if capacity > 0 {
      self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }
    self.bufferCapacity = capacity
    self.readTag = tag
  }
  
  func isSpecifiedLength() -> Bool {
    return bufferCapacity != 0
  }
  
  func spaceFull() -> Bool {
    return availabeSpace() == 0
  }
  
  func availabeSpace() -> Int {
    assert(bufferCapacity - bufferOffset >= 0)
    return bufferCapacity - bufferOffset
  }
  
}


class SwiftDSSocketWritePacket: NSObject {
  var buffer: Data?
  var bufferCapacity = 0
  var bufferOffset = 0
  var writeTag = 0
  
  init(data: Data, tag: Int = -1) {
    self.buffer = data
    self.bufferCapacity = data.count
    self.writeTag = tag
  }
  
  func isDone() -> Bool {
    SwiftDSSocket.log("bufferOffset = \(bufferOffset) bufferCapcity = \(bufferCapacity)")
    return bufferOffset == bufferCapacity
  }
  
  func availableBytes() -> Int {
    return bufferCapacity - bufferOffset
  }
  
}


public class SwiftDSSocket: NSObject {
  fileprivate static let NullSocket: Int32 = -1
  fileprivate var socketFD: Int32 = NullSocket
  fileprivate let CTLIOCGINFO: CUnsignedLong = 0xc0644e03
  fileprivate weak var delegate: SwiftDSSocketDelegate?
  fileprivate weak var delegateQueue: DispatchQueue?
  fileprivate var shouldRead = false
  fileprivate var socketType: SocketType = .tcp
  fileprivate var acceptDispatchSource: DispatchSourceRead?
  fileprivate var readDispatchSource: DispatchSourceRead?
  fileprivate var writeDispatchSource: DispatchSourceWrite?
  fileprivate var isReadDispatchSourceSuspended = true
  fileprivate var isWriteDispatchSourceSuspended = true
  fileprivate var isAcceptDispatchSourceSuspended = true
  fileprivate var socketQueue = DispatchQueue(label: "io.proximac.socket.queue")
  fileprivate var socketReady = false
  fileprivate var closeCondition: CloseCondition = .none
  fileprivate var status: SocketStatus = .initial
  fileprivate var readQueue = Queue<SwiftDSSocketReadPacket>()
  fileprivate var writeQueue = Queue<SwiftDSSocketWritePacket>()
  fileprivate var currentRead: SwiftDSSocketReadPacket?
  fileprivate var currentWrite: SwiftDSSocketWritePacket?
  
  public var userData: Any?
  public static var debugMode = false
  
  
  fileprivate enum SocketStatus: Int, Comparable {
    case initial = 0
    case listening = 1
    case connecting = 2
    case connected = 3
    case readEOF = 4
    case closing = 5
    case closed = 6
    case problematic = 7
    
    public static func < (a: SocketStatus, b: SocketStatus) -> Bool {
      return a.rawValue < b.rawValue
    }
    
    public static func <= (a: SocketStatus, b: SocketStatus) -> Bool {
      return a.rawValue <= b.rawValue
    }
  }
  
  fileprivate enum SocketIOAfterAction {
    case waiting
    case suspend
    case eof
    case error
  }
  
  fileprivate enum CloseCondition {
    case none
    case afterReads
    case afterWrites
    case afterBoth
  }
  
  public class SocketError: NSObject, Error {
    enum ErrorKind {
      case socketErrorFCNTL
      case socketErrorDefault
      case socketErrorIOCTL
      case socketErrorWrongAddress
      case socketErrorAlreadyConnected
      case socketErrorIncorrectSocketStatus
      case socketErrorConnecting
      case socketErrorReadSpecific
      case socketErrorWriteSpecific
      case socketErrorSetSockOpt
    }
    
    var errorKind: ErrorKind?
    var socketErrorCode: Int?
    var localizedDescription: String?
    
    init(_ errorKind: ErrorKind, socketErrorCode: Int? = nil, errorDescription: String? = nil) {
      self.errorKind = errorKind
      self.socketErrorCode = socketErrorCode
      self.localizedDescription = errorDescription
    }
  }
  
  public enum SocketType {
    case tcp
    case kernel
  }
  
  public init(delegate: SwiftDSSocketDelegate?, delegateQueue: DispatchQueue?, type: SocketType) {
    super.init()
    self.delegate = delegate
    self.delegateQueue = delegateQueue
    self.socketType = type
    
    if type == .kernel {
      socketFD = socket(PF_SYSTEM, SOCK_STREAM, SYSPROTO_CONTROL)
      setNonBlocking()
    }
    
  }
  
  
  @inline(__always)
  static func log(_ message: String) {
    if debugMode {
      NSLog("%@", message)
    }
  }
  
  
  @inline(__always)
  static func assert(_ expr: Bool, _ errorMessage: String, _ block: () -> Void = {}) {
    if !expr {
      NSLog("%@", errorMessage)
      block()
      exit(1)
    }
  }
  
  
  @inline(__always)
  static func fatal(_ message: String, _ block: () -> Void = {}) -> Never {
    NSLog("%@\n", message)
    NSLog(Thread.callStackSymbols.joined(separator: "\n"))
    block()
    exit(1)
  }
  
  fileprivate func deallocateBufferBlock(ptr: UnsafeMutableRawPointer, capacity: Int) {
    ptr.deallocate(bytes: capacity, alignedTo: 1)
  }
  
  fileprivate func suspendReadDispatchSource() {
    if (!isReadDispatchSourceSuspended) {
      readDispatchSource?.suspend()
      isReadDispatchSourceSuspended = true
    }
  }
  
  
  fileprivate func resumeReadDispatchSource() {
    if (isReadDispatchSourceSuspended) {
      readDispatchSource?.resume()
      isReadDispatchSourceSuspended = false
    }
  }
  
  
  fileprivate func suspendWriteDispatchSource() {
    if (!isWriteDispatchSourceSuspended) {
      writeDispatchSource?.suspend()
      isWriteDispatchSourceSuspended = true
    }
  }
  
  
  fileprivate func resumeWriteDispatchSource() {
    if (isWriteDispatchSourceSuspended) {
      writeDispatchSource?.resume()
      isWriteDispatchSourceSuspended = false
    }
  }
  
  
  fileprivate func suspendAcceptDispatchSource() {
    if (!isAcceptDispatchSourceSuspended) {
      acceptDispatchSource?.suspend()
      isAcceptDispatchSourceSuspended = true
    }
  }
  
  
  fileprivate func resumeAcceptDispatchSource() {
    if (isAcceptDispatchSourceSuspended) {
      acceptDispatchSource?.resume()
      isAcceptDispatchSourceSuspended = false
    }
  }
  
  
  fileprivate func setupWatchersForNewConnectedSocket(peerHost: String, peerPort: UInt16) {
    assert(writeDispatchSource == nil && readDispatchSource == nil)
    self.writeDispatchSource = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: socketQueue)
    self.readDispatchSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: socketQueue)
    guard let readDispatchSource = readDispatchSource, let writeDispatchSource = writeDispatchSource else {
      return
    }
    
    writeDispatchSource.setEventHandler {
      if self.status == .connecting {
        self.status = .connected
        self.delegateQueue?.async {
          self.delegate?.socket?(sock: self, didConnectToHost: peerHost, port: peerPort)
        }
      }
      
      self.doWriteData()
    }
    
    
    readDispatchSource.setEventHandler {
      let nAvailable: Int = Int(readDispatchSource.data)
      if nAvailable > 0 {
        self.doReadData(nAvailable: nAvailable)
      } else {
        self.doReadEOF()
      }
    }
    
    resumeReadDispatchSource()
    resumeWriteDispatchSource()
  }
  
  
  public func accept(onPort port: UInt16) throws {
    try socketQueue.sync {
      guard status == .initial else { throw SocketError(.socketErrorIncorrectSocketStatus) }
      socketFD = socket(AF_INET6, SOCK_STREAM, 0)
      setNonBlocking()
      var sockAddr = sockaddr_in6()
      sockAddr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      sockAddr.sin6_port = port.bigEndian
      sockAddr.sin6_family = sa_family_t(AF_INET6)
      sockAddr.sin6_addr = in6addr_any
      
      var reuse: Int32 = 1
      if Darwin.setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) != 0 {
        throw SocketError(.socketErrorSetSockOpt, socketErrorCode: Int(errno))
      }
      
      guard (withUnsafePointer(to: &sockAddr) {
        return $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          var ret:Int32 = 0
          repeat {
            errno = 0
            ret = Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
          } while ret == -1 && errno == EINTR
          return ret != -1
        }
      }) else {
        SwiftDSSocket.log("binding failed")
        close(socketFD)
        throw SocketError(.socketErrorConnecting)
      }
      
      guard 1 != Darwin.listen(socketFD, 1024) else {
        SwiftDSSocket.log("listen() failed")
        close(socketFD)
        return
      }
      
      status = .listening
      
      acceptDispatchSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: socketQueue)
      acceptDispatchSource?.setEventHandler(handler: {
        let numOfConnectionsPending = self.acceptDispatchSource?.data ?? 0
        for _ in 1...numOfConnectionsPending {
          self.doAccept(self.socketFD)
        }
      })
      
      resumeAcceptDispatchSource()
    }
  }
  
  
  fileprivate func doAccept(_ socketFD: Int32) {
    var sockAddr = sockaddr_in6()
    var sockLen: socklen_t = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let childSocketFD = (withUnsafeMutablePointer(to: &sockAddr) { (ptr) -> Int32 in
      return ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        var ret:Int32 = 0
        repeat {
          errno = 0
          ret = Darwin.accept(socketFD, UnsafeMutablePointer($0), &sockLen)
        } while ret == -1 && errno == EINTR
        return ret
      }
    })
    
    if childSocketFD == -1 {
      SwiftDSSocket.log("accept failure")
      return
    }
    
    setNonBlocking(fd: childSocketFD)
    var nonsigpipe: Int32 = 1
    if Darwin.setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nonsigpipe, socklen_t(MemoryLayout<Int32>.size)) != 0 {
      SwiftDSSocket.log("setsockopt failure")
      return
    }
    
    let childSocket = SwiftDSSocket(delegate: delegate, delegateQueue: delegateQueue, type: .tcp)
    childSocket.socketFD = childSocketFD
    childSocket.status = .connected
    
    var hostStringBuf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(INET6_ADDRSTRLEN))
    hostStringBuf.initialize(to: CChar(0))
    defer {
      hostStringBuf.deinitialize()
      hostStringBuf.deallocate(capacity: Int(INET6_ADDRSTRLEN))
    }
    
    inet_ntop(AF_INET6, &sockAddr.sin6_addr, hostStringBuf, socklen_t(INET6_ADDRSTRLEN))
    
    let peerHostName = String(cString: UnsafePointer<CChar>(hostStringBuf))
    let peerPort = in_port_t(bigEndian: sockAddr.sin6_port)
    SwiftDSSocket.log("host: \(peerHostName) port: \(peerPort)")
    childSocket.setupWatchersForNewConnectedSocket(peerHost: peerHostName, peerPort: peerPort)
    delegateQueue?.async {
      self.delegate?.socket?(sock: self, didAcceptNewSocket: childSocket)
    }
  }
  
  
  fileprivate func doWriteData() {
    var afterWriteAction: SocketIOAfterAction = .waiting
    var socketError: SocketError? = nil
    
    guard !writeQueue.isEmpty else {
      suspendWriteDispatchSource()
      return
    }
    
    if currentWrite == nil {
      currentWrite = writeQueue.front
    }
    
    guard let currentWrite = currentWrite, let buffer = currentWrite.buffer else { return }
    assert(!currentWrite.isDone())
    let nwritten = buffer.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) -> Int in
      var retval = 0
      repeat {
        errno = 0
        retval = Darwin.write(socketFD, ptr.advanced(by: currentWrite.bufferOffset), currentWrite.availableBytes())
      } while retval == -1 && errno == EINTR
      return retval
    }
    
    if nwritten > 0 {
      currentWrite.bufferOffset += nwritten
      if currentWrite.isDone() {
        writeQueue.removeTop()
        self.currentWrite = nil
        delegateQueue?.async {
          self.delegate?.socket?(sock: self, didWrite: currentWrite.writeTag)
        }
      }
    } else if errno != EWOULDBLOCK {
      afterWriteAction = .error
      socketError = SocketError(.socketErrorWriteSpecific, socketErrorCode: Int(errno))
    }
    
    if self.currentWrite == nil && self.writeQueue.isEmpty {
      if closeCondition == .afterWrites {
        closeWithError(error: socketError)
      }
      
      if self.currentRead == nil && self.readQueue.isEmpty && closeCondition == .afterBoth {
        closeWithError(error: socketError)
      }
    }
    
    if afterWriteAction == .waiting {
      resumeWriteDispatchSource()
    } else {
      closeWithError(error: socketError)
    }
    
  }
  
  
  fileprivate func doReadData(nAvailable: Int) {
    var afterReadAction: SocketIOAfterAction = .waiting
    var socketError: SocketError? = nil
    guard !readQueue.isEmpty else {
      suspendReadDispatchSource()
      return
    }
    
    if currentRead == nil {
      currentRead = readQueue.front
    }
    
    guard let currentRead = currentRead else {return}
    
    // deal with read packet with specified data length
    if let buffer = currentRead.buffer, currentRead.bufferCapacity > 0 {
      assert(currentRead.buffer != nil)
      var nread = 0
      repeat{
        errno = 0
        nread = Darwin.read(socketFD, buffer.advanced(by: currentRead.bufferOffset), currentRead.availabeSpace())
      } while nread == -1 && errno == EINTR
      
      if nread > 0 {
        currentRead.bufferOffset += nread;
      } else if nread == -1 && errno != EWOULDBLOCK {
        afterReadAction = .error
        socketError = SocketError(.socketErrorReadSpecific, socketErrorCode: Int(errno))
      }
      
      if currentRead.spaceFull() {
        readQueue.removeTop()
        self.currentRead = nil
        let dataForUserRead = Data(bytesNoCopy: buffer, count: currentRead.bufferCapacity, deallocator: .custom(deallocateBufferBlock))
        delegateQueue?.async {
          self.delegate?.socket?(sock: self, didRead: dataForUserRead, tag: currentRead.readTag)
        }
      }
      
      
      if nread == 0 {
        afterReadAction = .eof
      }
    } else {
      assert(currentRead.buffer == nil)
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: nAvailable)
      var nread = 0
      repeat{
        errno = 0
        nread = Darwin.read(socketFD, buffer, nAvailable)
      } while nread == -1 && errno == EINTR
      
      if nread > 0 {
        readQueue.removeTop()
        self.currentRead = nil
        let dataForUserRead = Data(bytesNoCopy: buffer, count: nread, deallocator: Data.Deallocator.custom(deallocateBufferBlock))
        delegateQueue?.async {
          self.delegate?.socket?(sock: self, didRead: dataForUserRead, tag: currentRead.readTag)
        }
      } else if nread == -1 && errno != EWOULDBLOCK {
        afterReadAction = .error
        socketError = SocketError(.socketErrorReadSpecific, socketErrorCode: Int(errno))
      }
      
      if nread == 0 {
        afterReadAction = .eof
      }
      
    }
    
    if self.currentRead == nil && self.readQueue.isEmpty {
      if closeCondition == .afterReads {
        closeWithError(error: socketError)
      }
      
      if self.currentWrite == nil && self.writeQueue.isEmpty && closeCondition == .afterBoth {
        closeWithError(error: socketError)
      }
    }
    
    
    switch afterReadAction {
    case .eof:
      doReadEOF()
    case .suspend:
      self.suspendReadDispatchSource()
    case .waiting:
      self.resumeReadDispatchSource()
    case .error:
      closeWithError(error: socketError)
    }
    
  }
  
  fileprivate func closeWithError(error: SocketError?) {
    guard socketFD != SwiftDSSocket.NullSocket else { return }
    readQueue.removeAll()
    writeQueue.removeAll()
    
    var socketFDRefCount = 2
    
    let closeReadWriteHandler = DispatchWorkItem(block: {
      socketFDRefCount -= 1
      if socketFDRefCount == 0 && self.socketFD != -1 {
        close(self.socketFD)
        self.socketFD = -1
        self.status = .closed
      }
    })
    
    readDispatchSource?.setCancelHandler(handler: closeReadWriteHandler)
    writeDispatchSource?.setCancelHandler(handler: closeReadWriteHandler)
    acceptDispatchSource?.setCancelHandler(handler: {
      if self.socketFD != -1 {
        close(self.socketFD)
        self.status = .closed
        self.socketFD = -1
      }
    })
    
    let sourcesToCancel: [Any?] = [readDispatchSource, writeDispatchSource, acceptDispatchSource].filter { $0 != nil }
    for source in sourcesToCancel {
      if let readSource = source as? DispatchSourceRead {
        readSource.cancel()
        self.resumeReadDispatchSource()
      }
      
      if let writeSouce = source as? DispatchSourceWrite {
        writeSouce.cancel()
        self.resumeWriteDispatchSource()
      }
      
      if let acceptSource = source as? DispatchSourceRead {
        acceptSource.cancel()
        self.resumeAcceptDispatchSource()
      }
      
    }
    
    if sourcesToCancel.isEmpty {
      close(socketFD)
      status = .closed
    }
    
    delegateQueue?.async {
      self.delegate?.socket?(sock: self, didCloseConnection: error)
    }
  }
  
  fileprivate func doReadEOF() {
    if let currentRead = currentRead, currentRead.isSpecifiedLength(), let buffer = currentRead.buffer {
      let data = Data(bytesNoCopy: buffer, count: currentRead.bufferOffset, deallocator: .free)
      delegateQueue?.async {
        self.delegate?.socket?(sock: self, didRead: data, tag: currentRead.readTag)
      }
    }
    closeWithError(error: nil)
  }
  
  fileprivate func setNonBlocking(fd: Int32? = nil) {
    if let socket = fd {
      let flags = fcntl(socket, F_GETFL)
      guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        status = .problematic
        return
      }
    } else {
      let flags = fcntl(socketFD, F_GETFL)
      guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        status = .problematic
        return
      }
    }
    
  }
  
  public func tryConnect(toHost host: String, port: UInt16) throws {
    
    try socketQueue.sync {
      guard status == .initial else { throw SocketError(.socketErrorIncorrectSocketStatus) }
      status = .connecting
      DispatchQueue.global(qos: .default).async {
        var addrInfo = addrinfo()
        var result: UnsafeMutablePointer<addrinfo>? = nil
        addrInfo.ai_family = PF_UNSPEC
        addrInfo.ai_socktype = SOCK_STREAM
        addrInfo.ai_protocol = IPPROTO_TCP
        addrInfo.ai_flags = AI_DEFAULT
        let portString = String(port)
        let gaiError = host.withCString({ (hostPtr) -> Int32 in
          return portString.withCString({ (portPtr) -> Int32 in
            return getaddrinfo(hostPtr, portPtr, &addrInfo, &result)
          })
        })
        
        if gaiError != 0 {
          SwiftDSSocket.log("gai occurs error")
          return
        }
        
        var addresses = [Data?]()
        var cursor = result
        while cursor != nil {
          if let addrInfo = cursor?.pointee {
            if addrInfo.ai_family == AF_INET6 || addrInfo.ai_family == AF_INET {
              let data = Data(bytes: cursor!, count: Int(MemoryLayout<addrinfo>.size))
              addresses.append(data)
            }
            cursor = addrInfo.ai_next
          }
        }
        
        cursor = nil
        
        for address in addresses {
          if let sockAddr = address?.withUnsafeBytes({$0.pointee as addrinfo}) {
            let fd = socket(sockAddr.ai_family, sockAddr.ai_socktype, sockAddr.ai_protocol)
            let retval = connect(fd, sockAddr.ai_addr, sockAddr.ai_addrlen)
            if retval != -1 {
              self.socketQueue.async {
                self.socketFD = fd
                self.status = .connected
                self.setNonBlocking()
                self.setupWatchersForNewConnectedSocket(peerHost: host, peerPort: port)
                self.delegateQueue?.async {
                  self.delegate?.socket?(sock: self, didConnectToHost: host, port: port)
                }
              }
              break
            } else {
              SwiftDSSocket.log("connect error code = \(retval)")
            }
            
          }
          
        }
        
        freeaddrinfo(result)
        
      }
    }
  }
  
  
  public func tryConnect(tobundleName bundleName: String) throws {
    try socketQueue.sync {
      var sockAddrControl = sockaddr_ctl()
      let ctlInfoSize = MemoryLayout<ctl_info>.stride
      let ctlInfoPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: ctlInfoSize)
      defer {
        ctlInfoPtr.deinitialize()
        ctlInfoPtr.deallocate(capacity: ctlInfoSize)
      }
      ctlInfoPtr.initialize(to: 0, count: ctlInfoSize)
      let bundleNamePtr = ctlInfoPtr.advanced(by: 4)
      _ = bundleName.withCString { memcpy(bundleNamePtr, $0, bundleName.characters.count) }
      if ioctl(socketFD, CTLIOCGINFO, ctlInfoPtr) == CInt(-1) {
        SwiftDSSocket.log("Cannot talk to kernel extension")
        throw SocketError(.socketErrorIOCTL)
      }
      let ctlInfo = ctlInfoPtr.withMemoryRebound(to: ctl_info.self, capacity: 1) { return $0.pointee as ctl_info }
      sockAddrControl.sc_family = CUnsignedChar(AF_SYSTEM)
      sockAddrControl.ss_sysaddr = UInt16(SYSPROTO_CONTROL)
      sockAddrControl.sc_unit = 0
      sockAddrControl.sc_id = ctlInfo.ctl_id
      SwiftDSSocket.log("Got ctl_id = " + String(ctlInfo.ctl_id))
      var sockaddrPtr = withUnsafePointer(to: &sockAddrControl, {
        return $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          return $0.pointee as sockaddr
        }
      })
      
      let retval = Darwin.connect(socketFD, &sockaddrPtr, UInt32(MemoryLayout<sockaddr_ctl>.stride))
      if retval != 0 {
        SwiftDSSocket.log("Cannot connect to kernel extension retval = " + String(retval))
        throw SocketError(.socketErrorDefault)
      }
      
      status = .connecting
      
      self.setupWatchersForNewConnectedSocket(peerHost: bundleName, peerPort: 0)
      
    }
    
  }
  
  public func write(data: Data, tag: Int) {
    socketQueue.async {
      guard self.status < .closing else { return }
      assert(self.writeDispatchSource != nil, "writeDispatchSource is nil")
      let packet = SwiftDSSocketWritePacket(data: data, tag: tag)
      self.writeQueue.enqueue(packet)
      self.resumeWriteDispatchSource()
    }
    
  }
  
  
  public func readData(tag: Int) {
    readData(toLength: 0, tag: tag)
  }
  
  public func readData(toLength: UInt, tag: Int) {
    socketQueue.async {
      guard self.status < .closing else { return }
      assert(self.readDispatchSource != nil, "readDispatchSource is nil")
      let packet = SwiftDSSocketReadPacket(capacity: Int(toLength), tag: tag)
      self.readQueue.enqueue(packet)
      self.resumeReadDispatchSource()
    }
  }
  
  public func disconnectAfterReading() {
    socketQueue.async {
      if self.status >= .connected && self.status < .closing {
        self.status = .closing
        self.closeCondition = .afterReads
      }
    }
  }
  
  public func disconnectAfterWriting() {
    socketQueue.async {
      if self.status >= .connected && self.status < .closing {
        self.status = .closing
        self.closeCondition = .afterWrites
      }
    }
  }
  
  public func disconnectAfterReadingAndWriting() {
    socketQueue.async {
      if self.status >= .connected && self.status < .closing {
        self.status = .closing
        self.closeCondition = .afterBoth
      }
    }
  }
  
  
  public func disconnect() {
    socketQueue.async {
      if self.status >= .connected && self.status < .closing || self.status == .listening {
        self.status = .closing
        self.closeWithError(error: nil)
      }
    }
  }
  
  deinit {
    if socketFD != -1 && status != .closed {
      close(socketFD)
    }
    
  }
}
