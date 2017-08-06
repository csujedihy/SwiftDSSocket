//
//  SwiftDSSocket.swift
//  SwiftDSSocket.swift
//
//  Created by Yi Huang on 7/7/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

// Important Note: DispatchSource for unix sockets are level triggered
// 1. delegateQueue must be set or no delagated functions will be called
// 2. this library automatically creates a queue for socket handlers

import Foundation
import Darwin

let sysSocket = Darwin.socket
let sysListen = Darwin.listen
let sysConnect = Darwin.connect
let sysAccept = Darwin.accept
let sysBind = Darwin.bind
let sysRead = Darwin.read
let sysWrite = Darwin.write
let sysSetSockOpt = Darwin.setsockopt
let sysGetSockOpt = Darwin.getsockopt
let sysDNS = Darwin.getaddrinfo
let sysClose = { _ = Darwin.close($0) }
let sysMalloc = { return OpaquePointer(malloc($0))}


/// delegate methods for each operation
@objc public protocol SwiftDSSocketDelegate {
  /// delegate method called after reading data from socket
  ///
  /// - Parameters:
  ///   - sock: SwiftDSSocket instance
  ///   - data: data read from stream
  ///   - tag: a tag to mark this read operation
  @objc optional func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int)
  /// delegate method called after reading partial data for specified data length from socket
  /// which allows users to know the progress of transfer
  /// - Parameters:
  ///   - sock: SwiftDSSocket instance
  ///   - totalCount: number of bytes read
  ///   - tag: a tag to mark this read operation
  @objc optional func socket(sock: SwiftDSSocket, didPartialRead totalCount: Int, tag: Int)
  /// delegate method called after reading data from socket
  ///
  /// - Parameters:
  ///   - sock: SwiftDSSocket instance
  ///   - tag: a tag to mark this write operation
  @objc optional func socket(sock: SwiftDSSocket, didWrite tag: Int)
  /// delegate method called after writing partial data for specified data length to socket
  /// which allows users to know the progress of transfer
  ///
  /// - Parameters:
  ///   - sock: SwiftDSSocket instance
  ///   - totalCount: number of bytes read
  ///   - tag: a tag to mark this write operation
  @objc optional func socket(sock: SwiftDSSocket, didPartialWrite totalCount: Int, tag: Int)

  /// delegate method called after closing connection
  ///
  /// - Parameters:
  ///   - sock: SwiftDSSocket instance
  ///   - error: SocketError indicates the reason why it gets closed
  @objc optional func socket(sock: SwiftDSSocket, didCloseConnection error: SwiftDSSocket.SocketError?)
  /// delegate method called after the connection to destination is established
  ///
  /// - Parameters:
  ///   - sock: SwiftDSSocket instance
  ///   - host: host address in `String`
  ///   - port: port number in UInt16
  @objc optional func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16)
  /// delegate method called after an incoming connection is accepted
  ///
  /// - Parameters:
  ///   - sock: SwiftDSSocket instance
  ///   - newSocket: SwiftDSSocket instance for peer socket
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
  var deallocator: Data.Deallocator = .none

  init(capacity: Int, tag: Int = -1) {
    if capacity > 0 {
      self.buffer = UnsafeMutablePointer<UInt8>(sysMalloc(capacity))
    }
    self.bufferCapacity = capacity
    self.readTag = tag
    self.deallocator = .free
  }
  
  init(capacity: Int, buffer: UnsafeMutablePointer<UInt8>, offset: Int, tag: Int = -1) {
    self.buffer = buffer.advanced(by: offset)
    self.bufferCapacity = capacity
    self.readTag = tag
    self.deallocator = .none
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
    return bufferOffset == bufferCapacity
  }

  func availableBytes() -> Int {
    return bufferCapacity - bufferOffset
  }

}


/// SwiftDSSocket class definition
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
  fileprivate var pendingConnectionRequest = 0
  fileprivate var readQueue = Queue<SwiftDSSocketReadPacket>()
  fileprivate var writeQueue = Queue<SwiftDSSocketWritePacket>()
  fileprivate var currentRead: SwiftDSSocketReadPacket?
  fileprivate var currentWrite: SwiftDSSocketWritePacket?

  /// store user data that can be used for context
  public var userData: Any?
  /// debug option (might be deprecated in future)
  public static var debugMode = true

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

  /// this defines all kinds of error in SwiftDSSocket
  public class SocketError: NSObject, Error {
    /// Kinds of Error in SocketError
    ///
    /// - socketErrorFCNTL: failure in BSD fcntl function
    /// - socketErrorDefault: default error
    /// - socketErrorIOCTL: failure in BSD ioctl function
    /// - socketErrorWrongAddress: the given address is not correct
    /// - socketErrorAlreadyConnected: the current socket is already connected
    /// - socketErrorIncorrectSocketStatus: conflicts with current socket status
    /// - socketErrorConnecting: failure in connecting to destination
    /// - socketErrorReadSpecific: found error when reading data from sock (return from `read`)
    /// - socketErrorWriteSpecific: found error when writing data to sock (return from `write`)
    /// - socketErrorSetSockOpt: failure in BSD setsockopt function
    public enum ErrorKind {
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
      case socketErrorMallocFailure
    }

    /// specifies error kind
    public var errorKind: ErrorKind?
    /// specifies error code (only for BSD socket standard error code)
    public var socketErrorCode: Int32
    /// a description string for this error
    public var localizedDescription: String?

    init(_ errorKind: ErrorKind, socketErrorCode: Int = 0, errorDescription: String? = nil) {
      self.errorKind = errorKind
      self.socketErrorCode = Int32(socketErrorCode)
      self.localizedDescription = errorDescription
    }
  }

  /// Socket Type
  ///
  /// - tcp: for TCP stream
  /// - kernel: for kernel TCP stream
  public enum SocketType {
    case tcp
    #if os(macOS)
    case kernel
    #endif
  }

  /// create a new SwiftDSSocket instance by specifying delegate, delegate queue and socket type
  ///
  /// - Parameters:
  ///   - delegate: specify delegate target (normally self)
  ///   - delegateQueue: specify the GCD dispatch queue for delegate methods
  ///   - type: socket type: tcp or kernel
  public init(delegate: SwiftDSSocketDelegate?, delegateQueue: DispatchQueue?, type: SocketType) {
    super.init()
    self.delegate = delegate
    self.delegateQueue = delegateQueue
    self.socketType = type

    #if os(macOS)
    if type == .kernel {
      socketFD = sysSocket(PF_SYSTEM, SOCK_STREAM, SYSPROTO_CONTROL)
      setNonBlocking()
    }
    #endif

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

    writeDispatchSource.setEventHandler { [weak self] in
      guard let strongSelf = self else { return }
      if strongSelf.status == .connecting {
        strongSelf.status = .connected
        strongSelf.delegateQueue?.async {
          strongSelf.delegate?.socket?(sock: strongSelf, didConnectToHost: peerHost, port: peerPort)
        }
      }

      strongSelf.doWriteData()
    }


    readDispatchSource.setEventHandler { [weak self] in
      guard let strongSelf = self else { return }
      let nAvailable: Int = Int(readDispatchSource.data)
      if nAvailable > 0 {
        strongSelf.doReadData(nAvailable: nAvailable)
      } else {
        strongSelf.doReadEOF()
      }
    }

    resumeReadDispatchSource()
    resumeWriteDispatchSource()
  }


  /// listen on a specified port for both IPv4/IPv6
  ///
  /// - Parameter port: port number in UInt16
  /// - Throws: throws a SocketError
  public func accept(onPort port: UInt16) throws {
    try socketQueue.sync {
      guard status == .initial else { throw SocketError(.socketErrorIncorrectSocketStatus) }
      socketFD = sysSocket(AF_INET6, SOCK_STREAM, 0)
      setNonBlocking()
      var sockAddr = sockaddr_in6()
      sockAddr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      sockAddr.sin6_port = port.bigEndian
      sockAddr.sin6_family = sa_family_t(AF_INET6)
      sockAddr.sin6_addr = in6addr_any

      var reuse: Int32 = 1
      if sysSetSockOpt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) != 0 {
        throw SocketError(.socketErrorSetSockOpt, socketErrorCode: Int(errno))
      }

      guard (withUnsafePointer(to: &sockAddr) {
        return $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          var ret:Int32 = 0
          repeat {
            errno = 0
            ret = sysBind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
          } while ret == -1 && errno == EINTR
          return ret != -1
        }
      }) else {
        SwiftDSSocket.log("binding failed")
        sysClose(socketFD)
        socketFD = -1
        throw SocketError(.socketErrorConnecting)
      }

      guard 1 != sysListen(socketFD, 1024) else {
        SwiftDSSocket.log("listen() failed")
        sysClose(socketFD)
        socketFD = -1
        return
      }

      status = .listening

      acceptDispatchSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: socketQueue)
      acceptDispatchSource?.setEventHandler { [weak self] in
        guard let strongSelf = self else { return }
        let numOfConnectionsPending = strongSelf.acceptDispatchSource?.data ?? 0
        for _ in 1...numOfConnectionsPending {
          strongSelf.doAccept(strongSelf.socketFD)
        }
      }

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
          ret = sysAccept(socketFD, UnsafeMutablePointer($0), &sockLen)
        } while ret == -1 && errno == EINTR
        return ret
      }
    })

    if childSocketFD == -1 {
      SwiftDSSocket.log("accept failure")
      return
    }

    var nonsigpipe: Int32 = 1
    if sysSetSockOpt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nonsigpipe, socklen_t(MemoryLayout<Int32>.size)) != 0 {
      SwiftDSSocket.log("setsockopt failure")
      return
    }

    let childSocket = SwiftDSSocket(delegate: delegate, delegateQueue: delegateQueue, type: .tcp)
    childSocket.socketFD = childSocketFD
    childSocket.status = .connected
    childSocket.setNonBlocking()

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
    SwiftDSSocket.log("@doWriteData")
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
        retval = sysWrite(socketFD, ptr.advanced(by: currentWrite.bufferOffset), currentWrite.availableBytes())
      } while retval == -1 && errno == EINTR
      return retval
    }

    if nwritten > 0 {
      currentWrite.bufferOffset += nwritten
      let theTag = currentWrite.writeTag
      if currentWrite.isDone() {
        writeQueue.removeTop()
        self.currentWrite = nil
        delegateQueue?.async {
          self.delegate?.socket?(sock: self, didWrite: theTag)
        }
      } else {
        let totalbytesWritten = currentWrite.bufferOffset
        delegateQueue?.async {
          self.delegate?.socket?(sock: self, didPartialWrite: totalbytesWritten, tag: theTag)
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
        nread = sysRead(socketFD, buffer.advanced(by: currentRead.bufferOffset), currentRead.availabeSpace())
      } while nread == -1 && errno == EINTR

      if nread > 0 {
        currentRead.bufferOffset += nread
      } else if nread == -1 && errno != EWOULDBLOCK {
        afterReadAction = .error
        socketError = SocketError(.socketErrorReadSpecific, socketErrorCode: Int(errno))
      }

      let theTag = currentRead.readTag

      if currentRead.spaceFull() {
        readQueue.removeTop()
        self.currentRead = nil
        let dataForUserRead = Data(bytesNoCopy: buffer, count: currentRead.bufferCapacity, deallocator: currentRead.deallocator)
        delegateQueue?.async {
          self.delegate?.socket?(sock: self, didRead: dataForUserRead, tag: theTag)
        }
      } else if nread > 0 {
        let totalBytesRead = currentRead.bufferOffset
        delegateQueue?.async {
          self.delegate?.socket?(sock: self, didPartialRead: totalBytesRead, tag: theTag)
        }
      }


      if nread == 0 {
        afterReadAction = .eof
      }
    } else {
      assert(currentRead.buffer == nil)
      guard let buffer = UnsafeMutablePointer<UInt8>(sysMalloc(nAvailable)) else {
        socketError = SocketError(.socketErrorMallocFailure)
        closeWithError(error: socketError)
        return
      }
      var nread = 0
      repeat{
        errno = 0
        nread = sysRead(socketFD, buffer, nAvailable)
      } while nread == -1 && errno == EINTR

      if nread > 0 {
        readQueue.removeTop()
        self.currentRead = nil
        let theTag = currentRead.readTag
        let dataForUserRead = Data(bytesNoCopy: buffer, count: nread, deallocator: currentRead.deallocator)
        delegateQueue?.async {
          self.delegate?.socket?(sock: self, didRead: dataForUserRead, tag: theTag)
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
    readQueue.removeAll()
    writeQueue.removeAll()

    var socketFDRefCount = 2

    let closeReadWriteHandler = DispatchWorkItem { [weak self] in
      guard let strongSelf = self else { return }
      socketFDRefCount -= 1
      if socketFDRefCount == 0 && strongSelf.socketFD != -1 {
        sysClose(strongSelf.socketFD)
        strongSelf.socketFD = -1
        strongSelf.status = .closed
      }
    }

    readDispatchSource?.setCancelHandler(handler: closeReadWriteHandler)
    writeDispatchSource?.setCancelHandler(handler: closeReadWriteHandler)
    acceptDispatchSource?.setCancelHandler { [weak self] in
      guard let strongSelf = self else { return }
      if strongSelf.socketFD != -1 {
        sysClose(strongSelf.socketFD)
        strongSelf.status = .closed
        strongSelf.socketFD = -1
      }
    }

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
      if socketFD != -1 {
        sysClose(socketFD)
        socketFD = -1
      }
      status = .closed
    }

    delegateQueue?.async {
      self.delegate?.socket?(sock: self, didCloseConnection: error)
    }
  }

  fileprivate func doReadEOF() {
    if let currentRead = currentRead, currentRead.isSpecifiedLength(), let buffer = currentRead.buffer {
      let theTag = currentRead.readTag
      self.currentRead = nil
      let data = Data(bytesNoCopy: buffer, count: currentRead.bufferOffset, deallocator: currentRead.deallocator)
      delegateQueue?.async {
        self.delegate?.socket?(sock: self, didRead: data, tag: theTag)
      }
    }
    closeWithError(error: nil)
  }

  fileprivate func setNonBlocking() {
    let flags = fcntl(socketFD, F_GETFL)
    if flags == -1 {
      status = .problematic
      assert(1 == 2)
      return
    }

    let retval = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
    if retval == -1 {
      status = .problematic
      assert(1 == 2)
      return
    }
  }


  /// connect to a host using address:port
  ///
  /// - Parameters:
  ///   - host: host address could be IP(v4/v6) or domain name in `String`
  ///   - port: port number in UInt16
  /// - Throws: throws a SocketError
  public func connect(toHost host: String, port: UInt16) throws {

    try socketQueue.sync {
      guard status == .initial || status == .closed else { throw SocketError(.socketErrorIncorrectSocketStatus) }
      readQueue.removeAll()
      writeQueue.removeAll()
      status = .connecting
      DispatchQueue.global(qos: .default).async { [weak self] in
        guard let strongSelf = self else { return }
        var addrInfo = addrinfo()
        var result: UnsafeMutablePointer<addrinfo>? = nil
        defer {
          freeaddrinfo(result)
        }
        addrInfo.ai_family = PF_UNSPEC
        addrInfo.ai_socktype = SOCK_STREAM
        addrInfo.ai_protocol = IPPROTO_TCP
        addrInfo.ai_flags = AI_DEFAULT
        let portString = String(port)
        let gaiError = host.withCString({ (hostPtr) -> Int32 in
          return portString.withCString({ (portPtr) -> Int32 in
            return sysDNS(hostPtr, portPtr, &addrInfo, &result)
          })
        })

        if gaiError != 0 {
          SwiftDSSocket.log("gai occurs error")
          return
        }

        var addressV4: Data? = nil
        var addressV6: Data? = nil
        
        var cursor = result
        var requestCount = 0
        while cursor != nil {
          if let addrInfo = cursor?.pointee {
            if addressV6 == nil || addressV4 == nil {
              var addressData = Data(bytes: cursor!, count: Int(MemoryLayout<addrinfo>.size))
              addressData.withUnsafeMutableBytes({ (ptr: UnsafeMutablePointer<addrinfo>) in
                let copiedPtr = UnsafeMutablePointer<sockaddr>.allocate(capacity: MemoryLayout<sockaddr>.size)
                copiedPtr.initialize(from: ptr.pointee.ai_addr, count: 1)
                ptr.pointee.ai_addr = copiedPtr
              })
              
              if addressV4 == nil && addrInfo.ai_family == AF_INET {
                addressV4 = addressData
                requestCount += 1
              }
              
              if addressV6 == nil && addrInfo.ai_family == AF_INET6 {
                addressV6 = addressData
                requestCount += 1
              }
            } else {
              break
            }

            cursor = addrInfo.ai_next
          }
        }

        SwiftDSSocket.log("requestCount = \(requestCount)")
        cursor = nil
        
        strongSelf.socketQueue.async {
          strongSelf.pendingConnectionRequest = requestCount
        }
        
        if let addressV4 = addressV4 {
          strongSelf.socketQueue.asyncAfter(deadline: .now() + .milliseconds(20), execute: {
            strongSelf.connectToSocketAddress(address: addressV4, host: host, port: port)
          })
        }
        
        
        if let addressV6 = addressV6 {
          strongSelf.connectToSocketAddress(address: addressV6, host: host, port: port)
        }

      }
    }
  }

  
  fileprivate func connectToSocketAddress(address: Data, host: String, port: UInt16) {
    let sockAddr = address.withUnsafeBytes({$0.pointee as addrinfo})
    let fd = sysSocket(sockAddr.ai_family, sockAddr.ai_socktype, sockAddr.ai_protocol)
    let retval = sysConnect(fd, sockAddr.ai_addr, sockAddr.ai_addrlen)
    let socketErrorCode = errno
    defer {
      sockAddr.ai_addr.deallocate(capacity: MemoryLayout<sockaddr>.size)
    }
    if retval != -1 {
      self.socketQueue.async { [weak self] in
        guard let strongSelf = self else { return }
        if strongSelf.status == .connecting {
          strongSelf.socketFD = fd
          strongSelf.status = .connected
          strongSelf.setNonBlocking()
          strongSelf.setupWatchersForNewConnectedSocket(peerHost: host, peerPort: port)
          strongSelf.delegateQueue?.async {
            strongSelf.delegate?.socket?(sock: strongSelf, didConnectToHost: host, port: port)
          }
        } else {
          sysClose(fd)
        }
      }
    } else {
      sysClose(fd)
      self.socketQueue.async { [weak self] in
        guard let strongSelf = self else { return }
        strongSelf.pendingConnectionRequest -= 1
        if strongSelf.pendingConnectionRequest == 0 {
          strongSelf.closeWithError(error: SocketError(.socketErrorConnecting, socketErrorCode: Int(socketErrorCode)))
        }
      }
    }
  }
  

  /// connect to kernel extenstion by using bundleId (String)
  ///
  /// - Parameter bundleName: bundleName in `String`
  /// - Throws: throws a SocketError
  #if os(macOS)
  public func connect(tobundleName bundleName: String) throws {
    try socketQueue.sync {
      readQueue.removeAll()
      writeQueue.removeAll()
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
      var sockaddrPtr = withUnsafePointer(to: &sockAddrControl, {
        return $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          return $0.pointee as sockaddr
        }
      })

      let retval = sysConnect(socketFD, &sockaddrPtr, UInt32(MemoryLayout<sockaddr_ctl>.stride))
      if retval != 0 {
        SwiftDSSocket.log("Cannot connect to kernel extension retval = " + String(retval))
        throw SocketError(.socketErrorDefault)
      }

      status = .connecting

      self.setupWatchersForNewConnectedSocket(peerHost: bundleName, peerPort: 0)

    }

  }
  #endif

  /// write data to socket
  ///
  /// - Parameters:
  ///   - data: data ready to send to socket in `Data` type
  ///   - tag: a tag to mark this write operation
  public func write(data: Data, tag: Int) {
    socketQueue.async { [weak self] in
      guard let strongSelf = self else { return }
      guard strongSelf.status < .closing else { return }
      assert(strongSelf.writeDispatchSource != nil, "writeDispatchSource is nil")
      let packet = SwiftDSSocketWritePacket(data: data, tag: tag)
      strongSelf.writeQueue.enqueue(packet)
      strongSelf.resumeWriteDispatchSource()
    }

  }


  /// read data from socket without given data length
  ///
  /// - Parameter tag: a tag to mark this read operation
  public func readData(tag: Int) {
    readData(toLength: 0, tag: tag)
  }

  /// read specified length of data from socket
  /// the callback will be invoked right after read specified amount of data
  /// - Parameters:
  ///   - toLength: length of data to read
  ///   - tag: a tag to mark this read operation
  public func readData(toLength: UInt, tag: Int) {
    socketQueue.async { [weak self] in
      guard let strongSelf = self else { return }
      guard strongSelf.status < .closing else { return }
      let packet = SwiftDSSocketReadPacket(capacity: Int(toLength), tag: tag)
      strongSelf.readQueue.enqueue(packet)
      strongSelf.resumeReadDispatchSource()
    }
  }

  
  /// read specified length of data into buffer that starts from offset
  ///
  /// users should make sure that buffer will not overflow
  ///
  /// - Parameters:
  ///   - toLength: length of data to read
  ///   - buffer: buffer given by user
  ///   - offset: offset of buffer
  ///   - tag: a tag to mark this read operation
  public func readData(toLength: UInt, buffer: UnsafeMutablePointer<UInt8>, offset: Int, tag: Int) {
    socketQueue.async { [weak self] in
      guard let strongSelf = self else { return }
      guard strongSelf.status < .closing else { return }
      let packet = SwiftDSSocketReadPacket(capacity: Int(toLength), buffer: buffer, offset: offset, tag: tag)
      strongSelf.readQueue.enqueue(packet)
      strongSelf.resumeReadDispatchSource()
    }
  }
  
  /// disconnect socket after all read opreations queued up and prevents new read operations
  public func disconnectAfterReading() {
    disconnect(afterCondition: .afterReads)
  }

  /// disconnect socket after all write opreations queued up and prevents new write operations
  public func disconnectAfterWriting() {
    disconnect(afterCondition: .afterWrites)
  }

  /// disconnect socket after all opreations queued up and prevents new operations
  public func disconnectAfterReadingAndWriting() {
    disconnect(afterCondition: .afterBoth)
  }

  fileprivate func disconnect(afterCondition: CloseCondition) {
    socketQueue.async { [weak self] in
      guard let strongSelf = self else { return }
      if strongSelf.status >= .connected && strongSelf.status < .closing {
        strongSelf.status = .closing
        strongSelf.closeCondition = afterCondition
      }
    }
  }

  /// simply disconnect socket and discards all opreations queued up
  public func disconnect() {
    socketQueue.async { [weak self] in
      guard let strongSelf = self else { return }
      if strongSelf.status >= .connected && strongSelf.status < .closing || strongSelf.status == .listening {
        strongSelf.status = .closing
        strongSelf.closeWithError(error: nil)
      }
    }
  }

  deinit {
    if socketFD != -1 && status != .closed {
      sysClose(socketFD)
    }

  }
}
