//
//  CloseAfterReadWrite.swift
//  SwiftDSSocket
//
//  Created by Yi Huang on 7/31/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

import XCTest
@testable import SwiftDSSocket

class CloseAfterReadWrite: XCTestCase {
  var client: SwiftDSSocket?
  var server: SwiftDSSocket?
  var accepted: SwiftDSSocket?
  weak var closeAfterAll: XCTestExpectation?
  weak var finishWrite: XCTestExpectation?
  let serverAdress = "127.0.0.1"
  let serverPort: UInt16 = 9999
  var dataSent = 0
  var dataRecv = 0
  let ServerTag = 0
  let ClientTag = 1
  var buffer: Data = Data()
  let testDataLength = 1024 * 1024
  let firstPacketSize: UInt = 10
  let secondPacketSize: UInt = 5
  
  override func setUp() {
    super.setUp()
    client = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .tcp)
    server = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .tcp)
  }
  
  override func tearDown() {
    super.tearDown()
    client?.disconnect()
    server?.disconnect()
  }
  
  func testExample() {
    try? server?.accept(onPort: serverPort)
    try? client?.connect(toHost: serverAdress, port: serverPort)
    closeAfterAll = expectation(description: "Closed After Read and Write")
    finishWrite = expectation(description: "Finished Read Correctly")
    
    waitForExpectations(timeout: 10) { (error: Error?) in
      if let error = error {
        XCTFail("Failed Transfer (Unspecified Data Length) error: \(error.localizedDescription)")
      } else {
        SwiftDSSocket.log("Success")
      }
    }
  }
  
  func testPerformanceExample() {
    // This is an example of a performance test case.
    self.measure {
      // Put the code you want to measure the time of here.
    }
  }
  
}

extension CloseAfterReadWrite: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket) {
    accepted = newSocket
    newSocket.readData(toLength: firstPacketSize, tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int) {
    dataRecv += data.count
    buffer.append(data)
    SwiftDSSocket.log("read Data length = \(data.count) dataRecv = \(dataRecv) should recve = \(testDataLength)")
    sock.readData(tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16) {
    SwiftDSSocket.log("@didConnectToHost")
    let dataToSend = Data(count: testDataLength)
    sock.write(data: dataToSend, tag: ClientTag)
    sock.disconnectAfterReadingAndWriting()
  }
  
  func socket(sock: SwiftDSSocket, didWrite tag: Int) {
    SwiftDSSocket.log("@didWrite finsh data transfer")
    if tag == ClientTag {
      finishWrite?.fulfill()
      finishWrite = nil
    }
  }
  
  func socket(sock: SwiftDSSocket, didCloseConnection error: SwiftDSSocket.SocketError?) {
    if finishWrite == nil {
      closeAfterAll?.fulfill()
      closeAfterAll = nil
    }
  }
}
