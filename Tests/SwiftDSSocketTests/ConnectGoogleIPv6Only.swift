//
//  IPv4and6Connect.swift
//  SwiftDSSocket
//
//  Created by Yi Huang on 8/6/17.
//
//

import XCTest
@testable import SwiftDSSocket

class ConnectGoogleIPv6Only: XCTestCase {
  var client: SwiftDSSocket?
  var accepted: SwiftDSSocket?
  
  weak var didConnect: XCTestExpectation?
  
  let serverAdress = "ipv6.google.com"
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

// Uncomment the code below if you have a IPv6 test environment
//  func testExample() {
//    try? client?.connect(toHost: serverAdress, port: serverPort)
//    didConnect = expectation(description: "IPv4/6 Connect -> Good")
//    
//    waitForExpectations(timeout: 5) { (error: Error?) in
//      if let error = error {
//        XCTFail("failed for error: \(error.localizedDescription)")
//      } else {
//        SwiftDSSocket.log("Success")
//      }
//    }
//  }
}

extension ConnectGoogleIPv6Only: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16) {
    SwiftDSSocket.log("@didConnectToHost")
    didConnect?.fulfill()
  }
  
  func socket(sock: SwiftDSSocket, didCloseConnection error: SwiftDSSocket.SocketError?) {
    SwiftDSSocket.log("@didCloseConnection")
  }
}
