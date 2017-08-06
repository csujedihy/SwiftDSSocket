//
//  SwiftDSSocketTests.swift
//  SwiftDSSocketTests
//
//  Created by Yi Huang on 7/27/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

import XCTest
@testable import SwiftDSSocket

class ConnectToWhenPortOff: XCTestCase {
  var client: SwiftDSSocket?
  var accepted: SwiftDSSocket?

  weak var errorExpectation: XCTestExpectation?

  let serverAdress = "127.0.0.1"
  let serverPort: UInt16 = 9999
  
  override func setUp() {
    super.setUp()
    SwiftDSSocket.debugMode = true
    client = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .tcp)
  }
  
  override func tearDown() {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    super.tearDown()
    client?.disconnect()
  }
  
  func testExample() {
    try? client?.connect(toHost: serverAdress, port: serverPort)
    errorExpectation = expectation(description: "Wait for ECONNREFUSED")
    
    waitForExpectations(timeout: 1) { (error: Error?) in
      if let error = error {
        XCTFail("failed for error: \(error.localizedDescription)")
      } else {
        SwiftDSSocket.log("Success")
      }
    }
  }

}


extension ConnectToWhenPortOff: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket) {
    accepted = newSocket
    SwiftDSSocket.log("@didAcceptNewSocket")
    XCTFail("Should never be called during this test")
  }
  
  func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16) {
    SwiftDSSocket.log("@didConnectToHost")
    XCTFail("Should never be called during this test")
  }
  
  func socket(sock: SwiftDSSocket, didCloseConnection error: SwiftDSSocket.SocketError?) {
    SwiftDSSocket.log("@didCloseConnection")
    let errorCode = error?.socketErrorCode
    if errorCode == ECONNREFUSED {
      errorExpectation?.fulfill()
    }
  }
}
