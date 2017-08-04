//
//  LargeDataTransferUnspecifiedData.swift
//  SwiftDSSocket
//
//  Created by Yi Huang on 7/27/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

import XCTest
@testable import SwiftDSSocket

class TransferUnspecifiedData: XCTestCase {
  var client: SwiftDSSocket?
  var server: SwiftDSSocket?
  var accepted: SwiftDSSocket?
  weak var finishWrite: XCTestExpectation?
  weak var finishRead: XCTestExpectation?
  let serverAdress = "127.0.0.1"
  let serverPort: UInt16 = 9999
  var dataSent = 0
  var dataRecv = 0
  let ServerTag = 0
  let ClientTag = 1
  var buffer: Data = Data()
  let testDataLength = 1024 * 1024
  
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
    finishWrite = expectation(description: "Finshed Write Correctlly")
    finishRead = expectation(description: "Finshed Read Correctlly")

    waitForExpectations(timeout: 30) { (error: Error?) in
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

extension TransferUnspecifiedData: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket) {
    accepted = newSocket
    newSocket.readData(tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int) {
    dataRecv += data.count
    buffer.append(data)
    SwiftDSSocket.log("read Data length = \(data.count) dataRecv = \(dataRecv) should recve = \(testDataLength)")
    if dataRecv == testDataLength {
      finishRead?.fulfill()
    }
    sock.readData(tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16) {
    let dataToSend = Data(count: testDataLength)
    sock.write(data: dataToSend, tag: ClientTag)
  }
  
  func socket(sock: SwiftDSSocket, didWrite tag: Int) {
    SwiftDSSocket.log("@didWrite")
    if tag == ClientTag {
      finishWrite?.fulfill()
    } else {
      XCTFail("Write failed due to incorrect tag")
    }
  }
}
