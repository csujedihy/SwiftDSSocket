//
//  KernelCommunication.swift
//  SwiftDSSocket
//
//  Created by Yi Huang on 7/31/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

import XCTest
@testable import SwiftDSSocket

class KernelCommunication: XCTestCase {
  var client: SwiftDSSocket?
  weak var echoExpectation: XCTestExpectation?
  let serverAddress = "com.proximac.kext"
  let ClientTag = 1
  let packet = "helloworld"

  
  override func setUp() {
    super.setUp()
    client = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .kernel)
  }
  
  override func tearDown() {
    super.tearDown()
    client?.disconnect()
  }
  
  /*: 
  **Note:**
  Unable to run kernel communication test in CI due to some system restrictions.
   
  To test this functionality in real system, you need to write a kernel extension.
  However, you can try this one written by myself for testing.
   
  ```
  static errno_t proximac_ctl_send_func(kern_ctl_ref kctlref, u_int32_t unit, void *unitinfo, mbuf_t m, int flags) {
    size_t buf_len = mbuf_len(m);
    char *data = mbuf_data(m);
    ctl_enqueuedata(kctlref, unit, data, buf_len, 0);
    mbuf_free(m);
    return 0;
  }
  ```
  Uncomment code below to enable testing in real system
  */
//  func testExample() {
//    try? client?.tryConnect(tobundleName: serverAddress)
//    echoExpectation = expectation(description: "Finished Communication with Kernel")
//    waitForExpectations(timeout: 10) { (error) in
//      if let error = error {
//        XCTFail("Failed Kernel Communication error: \(error.localizedDescription)")
//      }
//    }
//  }
  
}


extension KernelCommunication: SwiftDSSocketDelegate {

  func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int) {
    if data.count == packet.characters.count {
      if let content = String(bytes: data, encoding: .utf8) {
        if content == packet {
          SwiftDSSocket.log("Found data from kernel: \(content)")
          echoExpectation?.fulfill()
        }
      }
    }
  }
  
  func socket(sock: SwiftDSSocket, didConnectToHost host: String, port: UInt16) {
    SwiftDSSocket.log("@didConnectToHost (kernel)")
    let dataToSend = packet.data(using: .utf8)
    sock.readData(toLength: UInt(packet.characters.count), tag: ClientTag)
    if let dataToSend = dataToSend {
      sock.write(data: dataToSend, tag: ClientTag)
    }
    
  }
}
