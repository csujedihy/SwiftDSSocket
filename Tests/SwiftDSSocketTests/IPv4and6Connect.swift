//
//  IPv4and6Connect.swift
//  SwiftDSSocket
//
//  Created by Yi Huang on 8/6/17.
//
//

import XCTest
@testable import SwiftDSSocket

class IPv4and6Connect: XCTestCase {
  var client: SwiftDSSocket?
  var accepted: SwiftDSSocket?
  
  weak var didConnect: XCTestExpectation?
  
  let serverAdress = "www.google.com"
  let serverPort: UInt16 = 80
  
  override func setUp() {
    super.setUp()
    SwiftDSSocket.debugMode = true
    client = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .tcp)
  }
  
  override func tearDown() {
    super.tearDown()
    client?.disconnect()
  }
  
  func testExample() {
    try? client?.connect(toHost: serverAdress, port: serverPort)
    didConnect = expectation(description: "IPv4/6 Connect -> Good")
    
    waitForExpectations(timeout: 5) { (error: Error?) in
      if let error = error {
        XCTFail("failed for error: \(error.localizedDescription)")
      } else {
        SwiftDSSocket.log("Success")
      }
    }
  }
}

extension IPv4and6Connect: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16) {
    SwiftDSSocket.log("@didConnectToHost")
    didConnect?.fulfill()
  }
  
  func socket(sock: SwiftDSSocket, didCloseConnection error: SwiftDSSocket.SocketError?) {
    SwiftDSSocket.log("@didCloseConnection")
  }
}
