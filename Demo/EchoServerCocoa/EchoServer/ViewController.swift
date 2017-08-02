//
//  ViewController.swift
//  EchoServer
//
//  Created by Yi Huang on 7/7/17.
//  Copyright © 2017 Yi Huang. All rights reserved.
//

import Cocoa
import SwiftDSSocket

class ViewController: NSViewController {
  var client: SwiftDSSocket?
  var server: SwiftDSSocket?
  
  let ServerTag = 0
  let ClientTag = 1
  
  
  override func viewDidLoad() {
    super.viewDidLoad()
    server = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .tcp)
    try? server?.accept(onPort: 9999)
  }
  
}


extension ViewController: SwiftDSSocketDelegate {
  func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket) {
    newSocket.readData(tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int) {
    sock.write(data: data, tag: ServerTag)
    sock.readData(tag: ServerTag)
  }
}
