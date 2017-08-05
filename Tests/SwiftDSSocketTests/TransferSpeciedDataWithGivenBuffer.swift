//
//  LargeDataTransferUnspecifiedData.swift
//  SwiftDSSocket
//
//  Created by Yi Huang on 7/27/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

import XCTest
@testable import SwiftDSSocket

class TransferSpeciedDataWithGivenBuffer: XCTestCase {
  var client: SwiftDSSocket?
  var server: SwiftDSSocket?
  var accepted: SwiftDSSocket?
  weak var finishWrite: XCTestExpectation?
  weak var finishRead: XCTestExpectation?
  weak var dataCorrect: XCTestExpectation?
  let serverAdress = "127.0.0.1"
  let serverPort: UInt16 = 9999
  var dataSent = 0
  var dataRecv = 0
  let ServerTag = 31
  let ClientTag = 13
  var buffer: Data = Data()
  let testDataLength = 1024 * 1024
  var givenBuffer: UnsafeMutablePointer<UInt8>?
  var dataVerifier: UnsafeMutablePointer<UInt8>?
  var checksum = 0
  
  override func setUp() {
    super.setUp()
    SwiftDSSocket.debugMode = true
    client = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .tcp)
    server = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .tcp)
    givenBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 2 * testDataLength)
    givenBuffer?.initialize(to: UInt8(0), count: testDataLength)
    dataVerifier = UnsafeMutablePointer<UInt8>.allocate(capacity: testDataLength)
    guard let verifier = dataVerifier else {
      XCTFail("Memory is not enough")
      return
    }
    
    var sum = 0
    for i in 0 ..< testDataLength {
      let value = UInt8(arc4random_uniform(255))
      (verifier + i).pointee = value
      sum += Int(value)
    }
    
    checksum = sum
    SwiftDSSocket.log("Checksum = \(checksum)")
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
    dataCorrect = expectation(description: "Data Is Correct")
    waitForExpectations(timeout: 2) { (error: Error?) in
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

extension TransferSpeciedDataWithGivenBuffer: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket) {
    accepted = newSocket
    newSocket.readData(toLength: UInt(testDataLength), buffer: givenBuffer!, offset: testDataLength, tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int) {
    SwiftDSSocket.log("@didRead data.count = \(data.count)")
    var sum = 0
    for i in 0 ..< testDataLength {
      sum += Int(data[i])
    }
    
    SwiftDSSocket.log("Read data checksum = \(sum)")

    
    var sumOfZeroRegion = 0
    
    for i in 0 ..< testDataLength {
      sumOfZeroRegion += Int((givenBuffer! + i).pointee)
    }
    
    if sum == checksum && sumOfZeroRegion == 0 {
      dataCorrect?.fulfill()
    }
    
    SwiftDSSocket.log("Checksum of first 1kb of givenBuffer = \(sumOfZeroRegion)")
    
    if data.count == testDataLength {
      finishRead?.fulfill()
    }
  }
  
  func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16) {
    let dataToSend = Data(bytes: dataVerifier!, count: testDataLength)
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
