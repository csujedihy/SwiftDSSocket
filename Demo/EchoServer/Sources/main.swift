import Foundation
import SwiftDSSocket

class EchoServer: SwiftDSSocketDelegate {
  var server: SwiftDSSocket?
  var newClient: SwiftDSSocket?

  let ServerTag = 0

  func run() {
    server = SwiftDSSocket(delegate: self, delegateQueue: .main, type: .tcp)
    try? server?.accept(onPort: 9999)
    dispatchMain()
  }

  func socket(sock: SwiftDSSocket, didAcceptNewSocket newSocket: SwiftDSSocket) {
    newClient = newSocket
    newSocket.readData(tag: ServerTag)
  }
  
  func socket(sock: SwiftDSSocket, didRead data: Data, tag: Int) {
    sock.write(data: data, tag: ServerTag)
    sock.readData(tag: ServerTag)
  }
}

let server = EchoServer()
server.run()