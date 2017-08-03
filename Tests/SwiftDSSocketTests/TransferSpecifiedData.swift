//
//  TransferSpecifiedData.swift
//  SwiftDSSocket
//
//  Created by Yi Huang on 7/30/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

import XCTest
@testable import SwiftDSSocket

class TransferSpecifiedData: XCTestCase {
  var client: SwiftDSSocket?
  var server: SwiftDSSocket?
  var accepted:SwiftDSSocket?
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
  let firstPacketSize: UInt = 10
  let secondPacketSize: UInt = 5
  var testTuples = [(UInt, XCTestExpectation)]()
  
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
    try? client?.tryConnect(toHost: serverAdress, port: serverPort)
    finishWrite = expectation(description: "Finshed Write Correctlly")
    let seq: [UInt] = [firstPacketSize, secondPacketSize]
    
    for len in seq {
      testTuples.insert((len, expectation(description: "Finshed Read \(len)")), at: 0)
    }
    
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

extension TransferSpecifiedData: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket) {
    accepted = newSocket
    newSocket.readData(toLength: firstPacketSize, tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int) {
    dataRecv += data.count
    buffer.append(data)
    SwiftDSSocket.log("read Data length = \(data.count) dataRecv = \(dataRecv) should recve = \(testDataLength)")
    if let tuple = testTuples.popLast() {
      if tuple.0 == UInt(data.count) {
        tuple.1.fulfill()
      }
    } else {
      XCTFail("Unknown data found")
    }
    sock.readData(toLength: secondPacketSize, tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16) {
    let rawDataArray: [UInt8] = [0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 2, 4, 6, 8, 10]
    let dataToSend = Data(bytes: rawDataArray)
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
