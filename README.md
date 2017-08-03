![macOS](https://img.shields.io/badge/macOS-10.10%2B-green.svg?style=flat)
![iOS](https://img.shields.io/badge/iOS-9.0%2B-green.svg?style=flat)
![Swift Version](https://img.shields.io/badge/Swift-3.1-orange.svg?style=flat)
[![CocoaPods](https://img.shields.io/cocoapods/v/SwiftDSSocket.svg?style=flat)](http://cocoadocs.org/docsets/SwiftDSSocket)
[![Travis-CI](https://api.travis-ci.org/csujedihy/SwiftDSSocket.svg?branch=master)](https://travis-ci.org/csujedihy/SwiftDSSocket)
[![Carthage compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage)

# SwiftDSSocket

## Overview

SwiftDSSocket is a purely swift based **asynchronous** socket framework built atop DispatchSource. Function signatures are pretty much similar to those in CocoaAsyncSocket because I implemented this framework by learning the source code of CocoaAsyncSocket. The initial idea to build this farmework is driven by the need of network library to communicate with KEXT (NKE) to re-write my [Proximac](https://github.com/csujedihy/proximac) project but none of frameworks I found in github supports that. Thus, I decided to implemented my own framework to do so.

**Note:** This framework is still under active development. It only passes my unit tests and might have various bugs.

## Features
### Full Delegate Support

* every operation invokes a call to your delagate method.

### IPv6 Support

* listens only on IPv6 protocol but **accepts both** IPv4 and IPv6 incoming connections. 
* conforms to Apple's new App Store restriction on IPv6 only environment with NAT64/DNS64.

### DNS Enabled

* takes advantage of sythesized IPv6 address introduced in `iOS 9` and `OS X 10.11` for better IPv6 support.
* uses GCD to do DNS concurrently and connect to the first reachable address.


### KEXT Bi-directional Interaction

* takes a bundle ID to interact with your KEXT like TCP stream.

## Using SwiftDSSocket

### Including in your project

#### Swift Package Manager

To include SwiftDSSocket into a Swift Package Manager package, add it to the `dependencies` attribute defined in your `Package.swift` file. For example:

```
    dependencies: [
        .Package(url: "https://github.com/csujedihy/SwiftDSSocket", "x.x.x")
    ]
```

#### CocoaPods
To include SwiftDSSocket in a project using CocoaPods, you just add `SwiftDSSocket` to your `Podfile`, for example:

```
    target 'MyApp' do
        use_frameworks!
        pod 'SwiftDSSocket'
    end
```

#### Carthage
To include SwiftDSSocket in a project using Carthage, add a line to your `Cartfile` with the GitHub organization and project names and version. For example:

```
    github "csujedihy/SwiftDSSocket"
```

### Documentation
[http://cocoadocs.org/docsets/SwiftDSSocket/](http://cocoadocs.org/docsets/SwiftDSSocket/)

### Example:

The following example creates a default `SwiftDSSocket ` instance and then *immediately* starts listening on port `9999` and echoes back everything sent to this server.

You can simply use `telnet 127.0.0.1 9999` to connect to this server and send whatever you want.

```swift
import Cocoa
import SwiftDSSocket

class ViewController: NSViewController {
  var server: SwiftDSSocket?
  let ServerTag = 0
  
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

```

**Tips:** Check out `Demo` folder to see more examples for different environments.
