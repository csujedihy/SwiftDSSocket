//
//  PartialReadAndWrite
//  SwiftDSSocket
//
//  Created by Yi Huang on 7/30/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

import XCTest
@testable import SwiftDSSocket

class PartialReadAndWrite: XCTestCase {
  var client: SwiftDSSocket?
  var server: SwiftDSSocket?
  var accepted: SwiftDSSocket?
  weak var finishWrite: XCTestExpectation?
  weak var finishRead: XCTestExpectation?
  weak var partialWrite: XCTestExpectation?
  weak var partialRead: XCTestExpectation?
  let serverAdress = "127.0.0.1"
  let serverPort: UInt16 = 9999
  var dataSent = 0
  var dataRecv = 0
  let ServerTag = 0
  let ClientTag = 1
  var buffer: Data = Data()
  let testDataLength = 1024 * 1024 * 100

  override func setUp() {
    super.setUp()
    SwiftDSSocket.debugMode = true
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
    partialWrite = expectation(description: "Seen Partial Write")
    partialRead = expectation(description: "Seen Partial Read")

    waitForExpectations(timeout: 2) { (error: Error?) in
      if let error = error {
        XCTFail("Failed Transfer (PartialReadAndWrite) error: \(error.localizedDescription)")
      } else {
        SwiftDSSocket.log("Success")
      }
    }
  }
  

}

extension PartialReadAndWrite: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket) {
    accepted = newSocket
    newSocket.readData(toLength: UInt(testDataLength), tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didPartialRead totalCount: Int, tag: Int) {
//    SwiftDSSocket.log("@didPartialRead totalCount = \(totalCount)")
    if totalCount < testDataLength {
      self.partialRead?.fulfill()
      self.partialRead = nil
    }
  }
  
  func socket(sock: SwiftDSSocket, didPartialWrite totalCount: Int, tag: Int) {
    SwiftDSSocket.log("@didPartialWrite totalCount = \(totalCount)")
    if totalCount < testDataLength {
      partialWrite?.fulfill()
      self.partialWrite = nil
    }
  }
  
  func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int) {
    dataRecv += data.count
    buffer.append(data)
    SwiftDSSocket.log("read Data length = \(data.count) dataRecv = \(dataRecv) should recv = \(testDataLength)")
    finishRead?.fulfill()
    finishRead = nil
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
